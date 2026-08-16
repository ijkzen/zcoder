/// Layer 3 — the acknowledged rpc-frame transport: application byte messages
/// travel as fragmented, CRC32-checked `rpc-frame` payloads, acknowledged with
/// `rpc-frame-ack`. Mirrors the desktop's `AcknowledgedRelayProtocol`:
/// duplicates are re-acked, outbound messages are replayed after a relay
/// reconnect, unacked outbound beyond the replay grace (45 s) degrades the
/// bridge, and frames from a foreign bridge identity are dropped.
/// See docs/protocol/03-acknowledged-rpc-frame.md.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/crc32.dart';
import '../core/fragment_assembler.dart';
import '../limits.dart';
import '../payload/app_payload.dart';
import '../zlog.dart';

class RpcTransportException implements Exception {
  final String reasonCode;
  RpcTransportException(this.reasonCode);
  @override
  String toString() => 'RpcTransportException: $reasonCode';
}

/// Fault reason codes, matching the desktop's `remote.rpcFrame.*` family.
class RpcFrameFault {
  static const envelopeTooLarge = 'remote.rpcFrame.envelopeTooLarge';
  static const encodingFailed = 'remote.rpcFrame.encodingFailed';
  static const replayBufferExceeded = 'remote.rpcFrame.replayBufferExceeded';
  static const replayGraceExceeded = 'remote.rpcFrame.replayGraceExceeded';
  static const invalidPayload = 'remote.rpcFrame.invalidPayload';
  static const assemblyTimeout = 'remote.rpcFrame.assemblyTimeout';
  static const frameGap = 'remote.rpcFrame.frameGap';
  static const checksumMismatch = 'remote.rpcFrame.checksumMismatch';
  static const futureAck = 'remote.rpcFrame.futureAck';
  static const deliveryFailed = 'remote.rpcFrame.deliveryFailed';
}

class _OutboundMessage {
  final int messageSeq;
  final List<Map<String, Object?>> frames;
  final int outerBytes;
  final DateTime queuedAt;
  int nextFrameIndex = 0;

  _OutboundMessage(this.messageSeq, this.frames, this.queuedAt)
    : outerBytes = frames.fold(0, (sum, f) => sum + jsonEncode(f).length);
}

/// One side of an acknowledged bridge.
class RpcFrameTransport {
  /// Sink for app payloads (layer 2 frames) — normally the relay client's
  /// `sendPayload`.
  final void Function(Map<String, Object?> payload) sendPayload;
  final BridgeIdentity identity;

  RpcFrameTransport({
    required this.sendPayload,
    required this.identity,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _assembler = FragmentAssembler<int>(
      timeout: Duration(milliseconds: ProtocolLimits.assemblyTimeoutMs),
      onExpired: (_) => _degrade(RpcFrameFault.assemblyTimeout),
      now: _now,
    );
  }

  final DateTime Function() _now;
  late final FragmentAssembler<int> _assembler;

  final _messageController = StreamController<Uint8List>.broadcast();
  final _degradedController = StreamController<String>.broadcast();

  /// Logical messages assembled from inbound frames.
  Stream<Uint8List> get messageStream => _messageController.stream;

  /// Emitted on fatal transport faults (CRC mismatch, geometry violation,
  /// protocol violation, replay grace, assembly timeout). After a
  /// degradation the transport must be replaced by opening a new bridge.
  Stream<String> get degradedStream => _degradedController.stream;

  /// Unacked outbound bytes — the desktop's saturation signal
  /// (high/low watermark per docs/protocol/03).
  int get unacknowledgedBytes => _unackedBytes;
  bool get isDegraded => _degraded;

  int _physicalSeq = 0;
  int _messageSeq = 0;
  int _highestFullySentMessageSeq = 0;
  int _lastAckedMessageSeq = 0;
  int _unackedBytes = 0;
  bool _degraded = false;

  final List<_OutboundMessage> _outbound = [];
  int _nextUnsentIndex = 0; // index into _outbound of the first unsent message
  final Set<int> _ackedInboundMessageSeqs = {};
  Timer? _graceTimer;

  /// Sends a complete message, fragmenting if needed. The message is kept
  /// for replay until the desktop acks it.
  ///
  /// Throws [RpcTransportException] for messages the transport cannot carry
  /// (empty or larger than [ProtocolLimits.maxMessageBytes]) — a local
  /// programming error must not poison the whole bridge, unlike genuine
  /// protocol faults which degrade it.
  void sendMessage(Uint8List message) {
    if (_degraded) return;
    if (message.isEmpty || message.length > ProtocolLimits.maxMessageBytes) {
      throw RpcTransportException(
        message.isEmpty
            ? RpcFrameFault.encodingFailed
            : RpcFrameFault.envelopeTooLarge,
      );
    }
    final messageSeq = ++_messageSeq;
    final fragmentCount =
        (message.length + ProtocolLimits.fragmentPayloadBytes - 1) ~/
        ProtocolLimits.fragmentPayloadBytes;
    final checksum = crc32Hex(message);
    final frames = <Map<String, Object?>>[];
    for (var i = 0; i < fragmentCount; i++) {
      final start = i * ProtocolLimits.fragmentPayloadBytes;
      final end = (start + ProtocolLimits.fragmentPayloadBytes).clamp(
        0,
        message.length,
      );
      final chunk = Uint8List.sublistView(message, start, end);
      frames.add({
        'zcode_type': 'rpc-frame',
        ...identity.toJson(),
        'seq': ++_physicalSeq,
        'messageSeq': messageSeq,
        'fragmentIndex': i,
        'fragmentCount': fragmentCount,
        'messageBytes': message.length,
        'checksum': {'algorithm': 'crc32', 'value': checksum},
        'dataBase64': base64Encode(chunk),
      });
    }
    final entry = _OutboundMessage(messageSeq, frames, _now());
    if (_unackedBytes + entry.outerBytes >
        ProtocolLimits.replayBufferMaxBytes) {
      _degrade(RpcFrameFault.replayBufferExceeded);
      return;
    }
    _outbound.add(entry);
    _unackedBytes += entry.outerBytes;
    _startGraceTimer();
    zlog(
      'sending rpc message seq=$messageSeq '
      'bytes=${message.length} frags=$fragmentCount',
    );
    _flushOutbound();
  }

  void _flushOutbound() {
    while (!_degraded && _nextUnsentIndex < _outbound.length) {
      final entry = _outbound[_nextUnsentIndex];
      while (entry.nextFrameIndex < entry.frames.length && !_degraded) {
        sendPayload(entry.frames[entry.nextFrameIndex]);
        entry.nextFrameIndex++;
      }
      if (_degraded) return;
      if (entry.messageSeq > _highestFullySentMessageSeq) {
        _highestFullySentMessageSeq = entry.messageSeq;
      }
      _nextUnsentIndex++;
    }
  }

  /// Re-sends every unacked outbound message from fragment 0. Call when the
  /// relay link becomes `matched` again — the desktop replays its own side
  /// the same way.
  void replayUnacked() {
    if (_degraded) return;
    for (final entry in _outbound) {
      entry.nextFrameIndex = 0;
    }
    _nextUnsentIndex = 0;
    _flushOutbound();
    zlog('replayed ${_outbound.length} unacked outbound messages');
  }

  /// Feeds an inbound `rpc-frame` / `rpc-frame-ack` payload (raw map).
  /// Returns false if the payload belongs to a foreign bridge identity.
  bool acceptPayload(Map<String, Object?> payload) {
    if (_degraded) return true;
    if (!identity.matches(payload)) {
      zlog('dropping rpc frame from foreign bridge identity');
      return false;
    }
    if (payload['zcode_type'] == 'rpc-frame-ack') {
      _processAck(payload);
      return true;
    }
    _acceptFrame(payload);
    return true;
  }

  void _processAck(Map<String, Object?> payload) {
    final ackMessageSeq = payload['ackMessageSeq'];
    if (ackMessageSeq is! int) return;
    if (ackMessageSeq > _highestFullySentMessageSeq) {
      // Acking something we never fully sent is a protocol violation.
      _degrade(RpcFrameFault.futureAck);
      return;
    }
    if (ackMessageSeq <= _lastAckedMessageSeq) return;
    _lastAckedMessageSeq = ackMessageSeq;
    var released = 0;
    while (_outbound.isNotEmpty &&
        _outbound.first.messageSeq <= ackMessageSeq) {
      released += _outbound.first.outerBytes;
      _outbound.removeAt(0);
      if (_nextUnsentIndex > 0) _nextUnsentIndex--;
    }
    _unackedBytes = (_unackedBytes - released).clamp(0, 1 << 62);
    if (_outbound.isEmpty) _stopGraceTimer();
    zlog(
      'desktop acked through msg=$ackMessageSeq, '
      'unacked=$_unackedBytes bytes, ${_outbound.length} messages',
    );
  }

  void _acceptFrame(Map<String, Object?> frame) {
    final messageSeq = frame['messageSeq'];
    if (messageSeq is! int) return;
    final fragmentIndex = frame['fragmentIndex'];
    final fragmentCount = frame['fragmentCount'];
    final dataBase64 = frame['dataBase64'];
    if (fragmentIndex is! int ||
        fragmentCount is! int ||
        dataBase64 is! String) {
      _degrade(RpcFrameFault.invalidPayload);
      return;
    }
    // Geometry limits: ≤ 64 fragments per message, index within range.
    if (fragmentCount < 1 ||
        fragmentCount > ProtocolLimits.maxFragments ||
        fragmentIndex < 0 ||
        fragmentIndex >= fragmentCount) {
      _degrade(RpcFrameFault.invalidPayload);
      return;
    }

    if (_ackedInboundMessageSeqs.contains(messageSeq)) {
      // Already delivered — the desktop missed our ack and replayed.
      // Re-ack, then drop (desktop degrades after 45 s without it).
      zlog('duplicate rpc message seq=$messageSeq, re-acking');
      _sendAck(messageSeq);
      return;
    }

    final result = _assembler.accept(
      key: messageSeq,
      fragmentIndex: fragmentIndex,
      fragmentCount: fragmentCount,
      dataBase64: dataBase64,
    );
    if (result is! FragmentCompleted) {
      // Rejected (malformed fragment) degrades; pending just waits.
      if (result is FragmentRejected) {
        _degrade(RpcFrameFault.invalidPayload);
      }
      return;
    }
    final message = result.bytes;
    final messageBytes = frame['messageBytes'];
    if (messageBytes is int && message.length != messageBytes) {
      _degrade(RpcFrameFault.frameGap);
      return;
    }
    if (!crc32Matches(frame['checksum'], message)) {
      _degrade(RpcFrameFault.checksumMismatch);
      return;
    }
    _ackedInboundMessageSeqs.add(messageSeq);
    _sendAck(messageSeq);
    zlog('rpc message complete seq=$messageSeq bytes=${message.length}');
    if (!_messageController.isClosed) _messageController.add(message);
  }

  void _sendAck(int messageSeq) {
    sendPayload({
      'zcode_type': 'rpc-frame-ack',
      ...identity.toJson(),
      'ackMessageSeq': messageSeq,
    });
  }

  void _startGraceTimer() {
    _graceTimer ??= Timer.periodic(const Duration(seconds: 10), (_) {
      checkReplayGrace();
    });
  }

  void _stopGraceTimer() {
    _graceTimer?.cancel();
    _graceTimer = null;
  }

  /// Replay-grace enforcement: if the oldest unacked outbound message has
  /// been waiting longer than [ProtocolLimits.replayGraceMs] (45 s), the
  /// bridge is dead — degrade instead of buffering forever. Exposed for
  /// tests; normally driven by a periodic timer.
  @visibleForTesting
  void checkReplayGrace() {
    if (_degraded || _outbound.isEmpty) return;
    final oldest = _outbound.first;
    if (_now().difference(oldest.queuedAt).inMilliseconds >
        ProtocolLimits.replayGraceMs) {
      _degrade(RpcFrameFault.replayGraceExceeded);
    }
  }

  /// Drops stale inbound assemblies, degrading when one expires (mirrors
  /// the desktop's assembly-timeout fault). Exposed for tests; normally
  /// driven by the assembler's sweep timer.
  @visibleForTesting
  void expireStaleAssemblies() {
    _assembler.expireStale();
  }

  void _degrade(String reasonCode) {
    if (_degraded) return;
    _degraded = true;
    zlog('rpc transport degraded: $reasonCode');
    _outbound.clear();
    _unackedBytes = 0;
    _stopGraceTimer();
    if (!_degradedController.isClosed) _degradedController.add(reasonCode);
  }

  Future<void> dispose() async {
    _stopGraceTimer();
    _outbound.clear();
    _assembler.dispose();
    await _messageController.close();
    await _degradedController.close();
  }
}
