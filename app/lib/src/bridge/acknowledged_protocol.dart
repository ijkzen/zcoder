/// The acknowledged relay protocol: application messages travel as
/// `rpc-frame` payloads (fragmented, CRC32-checked, acked with
/// `rpc-frame-ack`). This mirrors `AcknowledgedRelayProtocol` in the desktop.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../core/crc32.dart';
import '../relay/relay_client.dart';

const int maxFrameBytes = 1024 * 1024; // physical frame limit (1MB)
const int maxMessageBytes = 16 * 1024 * 1024;
const int maxFragments = 64;
const int assemblyTimeoutMs = 30000;

class RelayProtocolException implements Exception {
  final String message;
  RelayProtocolException(this.message);
  @override
  String toString() => 'RelayProtocolException: $message';
}

/// One side of an acknowledged bridge. Sends messages as fragmented
/// rpc-frames, reassembles incoming frames, verifies CRCs, and acks.
class AcknowledgedRelayProtocol {
  final RelayClient relay;
  final String bridgeSessionId;
  final int bridgeGeneration;
  final String? recoveryId;

  AcknowledgedRelayProtocol({
    required this.relay,
    required this.bridgeSessionId,
    this.bridgeGeneration = 1,
    this.recoveryId,
  });

  final _messageController = StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get messageStream => _messageController.stream;

  int _physicalSeq = 0; // increments per physical frame sent
  int _messageSeq = 0; // logical message counter

  // Incoming assembly state keyed by messageSeq.
  final Map<int, _Assembly> _assemblies = {};
  final Set<int> _ackedMessageSeqs = {};
  Timer? _assemblySweepTimer;

  /// Sends a complete message, fragmenting if needed.
  void sendMessage(Uint8List message) {
    if (message.length > maxMessageBytes) {
      throw RelayProtocolException('message too large: ${message.length}');
    }
    final messageSeq = ++_messageSeq;
    final fragmentCount =
        (message.length == 0) ? 1 : (message.length + maxFrameBytes - 1) ~/ maxFrameBytes;
    final checksum = crc32Hex(message);
    debugPrint('[zremote] sending rpc message seq=$messageSeq bytes=${message.length} frags=$fragmentCount hex=${message.take(80).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
    for (var i = 0; i < fragmentCount; i++) {
      final start = i * maxFrameBytes;
      final end = (start + maxFrameBytes).clamp(0, message.length);
      final chunk = Uint8List.sublistView(message, start, end);
      final frame = <String, Object?>{
        'zcode_type': 'rpc-frame',
        'bridgeSessionId': bridgeSessionId,
        'bridgeGeneration': bridgeGeneration,
        if (recoveryId != null) 'recoveryId': recoveryId,
        'seq': ++_physicalSeq,
        'messageSeq': messageSeq,
        'fragmentIndex': i,
        'fragmentCount': fragmentCount,
        'messageBytes': message.length,
        'checksum': {'algorithm': 'crc32', 'value': checksum},
        'dataBase64': base64Encode(chunk),
      };
      relay.sendPayload(frame);
    }
  }

  /// Feeds an incoming `rpc-frame` payload.
  void acceptFrame(Map<String, Object?> frame) {
    final messageSeq = frame['messageSeq'];
    if (messageSeq is! int) return;
    final fragmentIndex = frame['fragmentIndex'];
    final fragmentCount = frame['fragmentCount'];
    final dataBase64 = frame['dataBase64'];
    if (fragmentIndex is! int || fragmentCount is! int || dataBase64 is! String) return;

    debugPrint('[zremote] rpc-frame msg=$messageSeq frag=$fragmentIndex/$fragmentCount '
        'mb=${frame['messageBytes']} crc=${(frame['checksum'] as Map?)?['value']} '
        'b64len=${dataBase64.length}');
    // Already acked → drop (duplicate/replayed).
    if (_ackedMessageSeqs.contains(messageSeq)) {
      debugPrint('[zremote]   -> already acked, drop');
      return;
    }

    final assembly = _assemblies.putIfAbsent(
      messageSeq,
      () => _Assembly(fragmentCount, DateTime.now()),
    );
    if (fragmentIndex >= fragmentCount || assembly.fragments[fragmentIndex] != null) {
      debugPrint('[zremote]   -> duplicate fragment or bad index '
          '(fragIdx=$fragmentIndex count=$fragmentCount has=${assembly.fragments[fragmentIndex] != null})');
      return;
    }
    try {
      assembly.fragments[fragmentIndex] = base64Decode(dataBase64);
    } catch (e) {
      debugPrint('[zremote] base64 decode failed: $e');
      return;
    }
    assembly.receivedCount++;

    _startSweep();
    if (assembly.receivedCount < fragmentCount) {
      debugPrint('[zremote]   -> waiting for fragments ${assembly.receivedCount}/$fragmentCount');
      return;
    }

    // Complete message.
    _assemblies.remove(messageSeq);
    final message = _concat(assembly.fragments);
    final messageBytes = frame['messageBytes'];
    if (messageBytes is int && message.length != messageBytes) {
      debugPrint('[zremote] rpc-frame length mismatch: got=${message.length} expect=$messageBytes, dropping');
      return;
    }
    final checksum = frame['checksum'];
    if (checksum is Map && checksum['value'] is String) {
      final actual = crc32Hex(message);
      if (actual != checksum['value']) {
        debugPrint('[zremote] rpc-frame crc mismatch: got=$actual expect=${checksum['value']}, dropping');
        return;
      }
    }
    debugPrint('[zremote] rpc message complete seq=$messageSeq bytes=${message.length}, acking');
    debugPrint('[zremote] msg hex: ${message.take(32).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
    _sendAck(messageSeq);
    if (!_messageController.isClosed) _messageController.add(message);
  }

  /// Feeds an incoming `rpc-frame-ack` — the desktop confirming a message
  /// *we* sent. Outbound and inbound messages use independent seq spaces, so
  /// these must NOT be recorded in [_ackedMessageSeqs] (that set guards
  /// inbound dedup). There is no outbound resend logic yet, so this is a
  /// no-op beyond logging.
  void acceptAck(Map<String, Object?> ack) {
    final messageSeq = ack['ackMessageSeq'];
    debugPrint('[zremote] desktop acked our msg=$messageSeq');
  }

  void _sendAck(int messageSeq) {
    relay.sendPayload({
      'zcode_type': 'rpc-frame-ack',
      'bridgeSessionId': bridgeSessionId,
      'bridgeGeneration': bridgeGeneration,
      if (recoveryId != null) 'recoveryId': recoveryId,
      'ackMessageSeq': messageSeq,
    });
  }

  Uint8List _concat(List<Uint8List?> fragments) {
    var total = 0;
    for (final f in fragments) {
      total += f!.length;
    }
    final out = Uint8List(total);
    var offset = 0;
    for (final f in fragments) {
      out.setRange(offset, offset + f!.length, f);
      offset += f.length;
    }
    return out;
  }

  void _startSweep() {
    _assemblySweepTimer ??= Timer.periodic(const Duration(seconds: 15), (_) {
      final now = DateTime.now();
      _assemblies.removeWhere(
        (_, a) => now.difference(a.createdAt).inMilliseconds > assemblyTimeoutMs,
      );
    });
  }

  Future<void> dispose() async {
    _assemblySweepTimer?.cancel();
    await _messageController.close();
  }
}

class _Assembly {
  final List<Uint8List?> fragments;
  final DateTime createdAt;
  int receivedCount = 0;

  _Assembly(int count, this.createdAt) : fragments = List.filled(count, null);
}
