/// Layer 5 — topic wire frames: the envelope that `onDynamicConversationFrame`
/// / `onDynamicSessionsIndexFrame` / `onDynamicWorkspaceConfigFrame` events
/// actually deliver. A wire frame is either `complete` (carrying the inner
/// topic frame directly) or `fragment` (one base64 chunk of a larger inner
/// frame, reassembled by `logicalFrameId` with a CRC32 check).
/// See docs/protocol/05-v4-conversation-data-plane.md.
library;

import 'dart:convert';

import '../core/fragment_assembler.dart';
import '../limits.dart';
import '../zlog.dart';

/// A fully assembled wire frame: the inner topic frame plus the envelope
/// metadata the inner frame does not carry ([deliveryKind], wire version,
/// logical ordinal) — the host fires these on the envelope, and consumers
/// need them (e.g. the `online` replay guard).
class WireFrameResult {
  final Map<String, Object?> frame;
  final String? deliveryKind; // initial | online | recovery
  final int? logicalFrameOrdinal;
  final int? wireVersion;

  const WireFrameResult({
    required this.frame,
    this.deliveryKind,
    this.logicalFrameOrdinal,
    this.wireVersion,
  });
}

/// Reassembles topic wire frames into inner topic frames. Mechanical
/// assembly is shared with the rpc-frame transport via [FragmentAssembler];
/// failures here drop silently (unlike rpc-frames, which degrade the
/// bridge — the host already validated these frames before firing them).
class WireFrameAssembler {
  static const int _maxFragments = 64;

  late final FragmentAssembler<String> _assembler = FragmentAssembler<String>(
    timeout: const Duration(milliseconds: ProtocolLimits.assemblyTimeoutMs),
    onExpired: (key) => zlog('dropped stale topic wire frame $key'),
  );

  /// Feeds one event payload (the object fired by a dynamic `*Frame` event).
  /// Returns the assembled result when this input completes one, or null
  /// (fragment accepted / not a wire frame / malformed / unknown version).
  WireFrameResult? accept(Map<String, Object?> event) {
    final kind = event['kind'];
    final wireVersion = event['wireVersion'];
    if (wireVersion is int && wireVersion != ProtocolLimits.topicWireVersion) {
      zlog('dropping topic wire frame with unknown wireVersion=$wireVersion');
      return null;
    }
    if (kind == 'complete') {
      final frame = event['frame'];
      if (frame is Map<String, Object?>) {
        final payload = frame['payload'];
        zlog('topic wire frame complete: topic=${frame['topic']} '
            'kind=${payload is Map ? payload['kind'] : '?'} '
            'toSeq=${frame['toSeq']} delivery=${event['deliveryKind']}');
        return WireFrameResult(
          frame: frame,
          deliveryKind: event['deliveryKind'] is String
              ? event['deliveryKind'] as String
              : null,
          logicalFrameOrdinal: event['logicalFrameOrdinal'] is int
              ? event['logicalFrameOrdinal'] as int
              : null,
          wireVersion: wireVersion is int ? wireVersion : null,
        );
      }
      // A complete frame without the nested `frame` object is malformed.
      zlog('complete wire frame without inner frame: ${event.keys.toList()}');
      return null;
    }
    if (kind == 'fragment') {
      return _acceptFragment(event);
    }
    // Unknown shape — log once per unknown kind to aid future schema bumps.
    zlog('unknown topic event kind: $kind (${event.keys.toList()})');
    return null;
  }

  WireFrameResult? _acceptFragment(Map<String, Object?> event) {
    final logicalFrameId = event['logicalFrameId'];
    final fragmentIndex = event['fragmentIndex'];
    final fragmentCount = event['fragmentCount'];
    final dataBase64 = event['dataBase64'];
    if (logicalFrameId is! String ||
        fragmentIndex is! int ||
        fragmentCount is! int ||
        dataBase64 is! String) {
      return null;
    }
    if (fragmentCount < 1 ||
        fragmentCount > _maxFragments ||
        fragmentIndex < 0 ||
        fragmentIndex >= fragmentCount) {
      zlog('bad wire frame geometry: $fragmentIndex/$fragmentCount');
      return null;
    }

    final result = _assembler.accept(
      key: logicalFrameId,
      fragmentIndex: fragmentIndex,
      fragmentCount: fragmentCount,
      dataBase64: dataBase64,
    );
    if (result is! FragmentCompleted) return null;

    final bytes = result.bytes;
    if (!crc32Matches(event['checksum'], bytes)) {
      zlog('wire frame crc mismatch for $logicalFrameId');
      return null;
    }
    final logicalBytes = event['logicalBytes'];
    if (logicalBytes is int && bytes.length != logicalBytes) {
      zlog('wire frame length mismatch for $logicalFrameId');
      return null;
    }
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map<String, Object?>) {
        return WireFrameResult(
          frame: decoded,
          deliveryKind: event['deliveryKind'] is String
              ? event['deliveryKind'] as String
              : null,
          logicalFrameOrdinal: event['logicalFrameOrdinal'] is int
              ? event['logicalFrameOrdinal'] as int
              : null,
          wireVersion: event['wireVersion'] is int
              ? event['wireVersion'] as int
              : null,
        );
      }
    } catch (e) {
      zlog('wire frame json decode failed for $logicalFrameId: $e');
    }
    return null;
  }

  void dispose() {
    _assembler.dispose();
  }
}

/// Parsed inner topic frame: `{topic, subscriptionId, fromSeq, toSeq,
/// sentAt?, payload}` with `payload = {kind: snapshot|deltas, …}`. The
/// envelope's [deliveryKind] is threaded through from the wire frame.
class TopicFrame {
  final String topic;
  final String subscriptionId;
  final int fromSeq;
  final int toSeq;
  final Map<String, Object?> payload;
  final String? deliveryKind; // initial | online | recovery

  const TopicFrame({
    required this.topic,
    required this.subscriptionId,
    required this.fromSeq,
    required this.toSeq,
    required this.payload,
    this.deliveryKind,
  });

  bool get isSnapshot => payload['kind'] == 'snapshot';
  Map<String, Object?>? get snapshot =>
      isSnapshot && payload['snapshot'] is Map<String, Object?>
          ? payload['snapshot'] as Map<String, Object?>
          : null;
  List<Object?>? get deltas =>
      !isSnapshot && payload['deltas'] is List ? payload['deltas'] as List : null;

  /// [deliveryKind] comes from the wire-frame envelope, not the inner frame.
  static TopicFrame? fromMap(Map<String, Object?> map, {String? deliveryKind}) {
    final topic = map['topic'];
    final subscriptionId = map['subscriptionId'];
    final payload = map['payload'];
    if (topic is! String || subscriptionId is! String) return null;
    if (payload is! Map<String, Object?>) return null;
    return TopicFrame(
      topic: topic,
      subscriptionId: subscriptionId,
      fromSeq: map['fromSeq'] is int ? map['fromSeq'] as int : 0,
      toSeq: map['toSeq'] is int ? map['toSeq'] as int : 0,
      payload: payload,
      deliveryKind: deliveryKind,
    );
  }
}
