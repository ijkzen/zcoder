/// Layer 5 — the `zcode-agent` channel's V4 conversation API: hello +
/// clientHello initialization, topic subscriptions (conversation /
/// sessions-index / workspace-config), resync, unsubscribe, history reads and
/// conversation commands. Topic events are reassembled from wire frames by
/// [WireFrameAssembler]. See docs/protocol/05-v4-conversation-data-plane.md.
library;

import '../zlog.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../core/random_ids.dart' as ids;
import '../limits.dart';
import '../rpc/channel_client.dart';
import 'wire_frame.dart';

const String agentChannelName = 'zcode-agent';

class SubscribeAck {
  final String subscriptionId;
  final String mode; // snapshot | resume
  final String logEpoch;
  const SubscribeAck(this.subscriptionId, this.mode, this.logEpoch);
}

/// Extracts an ack from an RPC response (`{ack: {subscriptionId, mode,
/// logEpoch}}` — the 201 result).
SubscribeAck? tryParseAck(Object? raw) {
  if (raw is! Map<String, Object?>) return null;
  final ack = raw['ack'];
  if (ack is! Map<String, Object?>) return null;
  return SubscribeAck(
    ack['subscriptionId']?.toString() ?? '',
    ack['mode']?.toString() ?? 'snapshot',
    ack['logEpoch']?.toString() ?? '',
  );
}

/// Client for the topic protocol over the zcode-agent channel.
class TopicSession {
  final RpcChannel _channel;
  final String clientId;
  final String workspaceKey;
  final String? workspaceIdentity;

  TopicSession(
    this._channel, {
    required this.clientId,
    required this.workspaceKey,
    this.workspaceIdentity,
  });

  final _conversationFrames = StreamController<TopicFrame>.broadcast();
  final _sessionsIndexFrames = StreamController<TopicFrame>.broadcast();
  final _workspaceConfigFrames = StreamController<TopicFrame>.broadcast();
  final _assembler = WireFrameAssembler();

  /// Fully reassembled conversation topic frames.
  Stream<TopicFrame> get conversationFrames => _conversationFrames.stream;

  /// Fully reassembled sessions-index topic frames.
  Stream<TopicFrame> get sessionsIndexFrames => _sessionsIndexFrames.stream;

  /// Fully reassembled workspace-config topic frames.
  Stream<TopicFrame> get workspaceConfigFrames => _workspaceConfigFrames.stream;

  String? _connectionId;
  String? get connectionId => _connectionId;

  /// Minimal workspace scope for the **conversation** subscription path.
  /// Matches the reference client (zemote) exactly — the desktop derives the
  /// connection identity itself from the relay connection, so sending
  /// `connectionId`/`runtimePolicy` here breaks frame delivery (E2E-verified
  /// 2026-08-17: zemote receives conversation frames with this shape, zcoder
  /// did not while sending the extra fields; doc 08 §3.2).
  Map<String, Object?> get _conversationScope => {
    'workspacePath': workspaceKey,
    if (workspaceIdentity != null && workspaceIdentity!.isNotEmpty)
      'workspaceIdentity': workspaceIdentity,
  };

  StreamSubscription<Object?>? _conversationEventSub;
  StreamSubscription<Object?>? _sessionsIndexEventSub;
  StreamSubscription<Object?>? _workspaceConfigEventSub;

  /// `helloConversationV4()` then `initializeConversationV4(clientHello)`,
  /// then subscribes to the three frame-push events. Returns the hello map.
  Future<Map<String, Object?>> initialize({String appVersion = '3.6.5'}) async {
    final helloRaw = await _channel.call('helloConversationV4');
    zlog('[zremote] hello response: $helloRaw');
    if (helloRaw is Map<String, Object?>) {
      final conn = helloRaw['connectionId'];
      if (conn is String) _connectionId = conn;
    }
    await _channel.call('initializeConversationV4', {
      'kind': 'clientHello',
      'protocolVersion': ProtocolLimits.conversationProtocolVersion,
      'clientId': clientId,
      // 'mobileApp' (with a current desktop appVersion) is what the host's
      // runtime push path expects from a phone client — the earlier
      // 'mobileRemote' + 3.4.0 combo never received 204/wire-frame events
      // (E2E-verified 2026-08-16; re-verified after the change in stage 2).
      'clientKind': 'mobileApp',
      'appVersion': appVersion,
    });
    _conversationEventSub = _channel
        .listen('onDynamicConversationFrame', _conversationScope)
        .listen(_dispatch(_conversationFrames));
    _sessionsIndexEventSub = _channel
        .listen('onDynamicSessionsIndexFrame', _conversationScope)
        .listen(_dispatch(_sessionsIndexFrames));
    _workspaceConfigEventSub = _channel
        .listen('onDynamicWorkspaceConfigFrame', _conversationScope)
        .listen(_dispatch(_workspaceConfigFrames));
    return helloRaw is Map<String, Object?> ? helloRaw : const {};
  }

  void Function(Object?) _dispatch(StreamController<TopicFrame> target) {
    return (raw) {
      if (raw is! Map<String, Object?>) return;
      final result = _assembler.accept(raw);
      if (result == null) return;
      final frame = TopicFrame.fromMap(
        result.frame,
        deliveryKind: result.deliveryKind,
      );
      if (frame == null) return;
      zlog(
        '[zremote] wire frame delivered: topic=${frame.topic} '
        'kind=${frame.snapshot != null ? 'snapshot' : 'deltas'} '
        'toSeq=${frame.toSeq}',
      );
      if (!target.isClosed) target.add(frame);
    };
  }

  // Subscribe shape for sessions-index / workspace-config: workspace target +
  // runtime policy (the reference client sends `existing-only` here too).
  Map<String, Object?> _subscribeFields(String visibility) => {
    'workspacePath': workspaceKey,
    if (workspaceIdentity != null && workspaceIdentity!.isNotEmpty)
      'workspaceIdentity': workspaceIdentity,
    'runtimePolicy': 'existing-only',
    if (visibility != 'foreground') 'visibility': visibility,
  };

  /// Subscribes to a conversation topic; resolves with the ack.
  Future<SubscribeAck> subscribe(
    String sessionId, {
    String visibility = 'foreground',
  }) async {
    final raw = await _channel.call('subscribeConversationV4', {
      ..._conversationScope,
      'sessionId': sessionId,
    });
    final ack = tryParseAck(raw);
    if (ack == null) throw StateError('unexpected subscribe response: $raw');
    return ack;
  }

  Future<SubscribeAck> subscribeSessionsIndex() async {
    final raw = await _channel.call('subscribeSessionsIndexV4', {
      ..._subscribeFields('foreground'),
    });
    final ack = tryParseAck(raw);
    if (ack == null) throw StateError('unexpected subscribe response: $raw');
    return ack;
  }

  Future<SubscribeAck> subscribeWorkspaceConfig() async {
    final raw = await _channel.call('subscribeWorkspaceConfigV4', {
      ..._subscribeFields('foreground'),
    });
    final ack = tryParseAck(raw);
    if (ack == null) throw StateError('unexpected subscribe response: $raw');
    return ack;
  }

  /// Pulls the current state for a subscription (forceSnapshot) or resumes
  /// from a base (`{logEpoch, seq}`).
  Future<void> resyncConversation(
    String subscriptionId,
    String sessionId, {
    String? logEpoch,
    int? seq,
  }) async {
    await _channel.call('resyncConversationV4', {
      ..._conversationScope,
      'sessionId': sessionId,
      'subscriptionId': subscriptionId,
      'base': logEpoch == null ? null : {'logEpoch': logEpoch, 'seq': seq ?? 0},
      'forceSnapshot': logEpoch == null,
    });
  }

  Future<void> resyncSessionsIndex(
    String subscriptionId, {
    String? logEpoch,
    int? seq,
  }) async {
    await _channel.call('resyncSessionsIndexV4', {
      ..._subscribeFields('foreground'),
      'subscriptionId': subscriptionId,
      'base': logEpoch == null ? null : {'logEpoch': logEpoch, 'seq': seq ?? 0},
      'forceSnapshot': logEpoch == null,
    });
  }

  Future<void> resyncWorkspaceConfig(
    String subscriptionId, {
    String? logEpoch,
    int? seq,
  }) async {
    await _channel.call('resyncWorkspaceConfigV4', {
      ..._subscribeFields('foreground'),
      'subscriptionId': subscriptionId,
      'base': logEpoch == null ? null : {'logEpoch': logEpoch, 'seq': seq ?? 0},
      'forceSnapshot': logEpoch == null,
    });
  }

  /// Unsubscribes a conversation topic. Routed by workspace target alongside
  /// the topic/subscriptionId (the host resolves the runtime through
  /// `workspacePath`).
  Future<void> unsubscribeConversation(
    String sessionId,
    String subscriptionId,
  ) async {
    await _channel.call('unsubscribeConversationV4', {
      ..._conversationScope,
      'sessionId': sessionId,
      'subscriptionId': subscriptionId,
    });
  }

  Future<void> unsubscribeSessionsIndex(String subscriptionId) async {
    await _channel.call('unsubscribeSessionsIndexV4', {
      'workspacePath': workspaceKey,
      'subscriptionId': subscriptionId,
    });
  }

  Future<void> unsubscribeWorkspaceConfig(String subscriptionId) async {
    await _channel.call('unsubscribeWorkspaceConfigV4', {
      'workspacePath': workspaceKey,
      'subscriptionId': subscriptionId,
    });
  }

  /// Fetches rows for a session. `beforeRowId` exclusive; limit ≤ 200.
  /// The host validates BOTH a top-level workspacePath (routing) and a nested
  /// workspace object (params schema) — omitting either fails validation.
  Future<Map<String, Object?>> rowsRange(
    String sessionId, {
    int? beforeRowId,
    int limit = 200,
  }) async {
    final raw = await _channel.call('conversationRowsRangeV4', {
      'workspacePath': workspaceKey,
      'workspace': {'workspacePath': workspaceKey},
      'sessionId': sessionId,
      'beforeRowId': ?beforeRowId,
      'limit': limit.clamp(1, ProtocolLimits.rowsRangeMaxLimit),
    });
    return raw is Map<String, Object?> ? raw : const {};
  }

  /// Fetches the session's plan history — the TodoWrite tool-call rows
  /// (`{plans: [...], atSeq, atLogEpoch}`), same call the reference client's
  /// 「计划」 view uses.
  Future<Map<String, Object?>> conversationPlans(String sessionId) async {
    final raw = await _channel.call('conversationPlansV4', {
      ..._conversationScope,
      'sessionId': sessionId,
    });
    return raw is Map<String, Object?> ? raw : const {};
  }

  /// Sends one conversation command and returns the command result. The host
  /// reads `params.envelope.clientId`, so the command must travel inside an
  /// `envelope` key with the workspace target alongside.
  Future<Map<String, Object?>> sendCommand(Map<String, Object?> command) async {
    final raw = await _channel.call('sendConversationCommandV4', {
      ..._conversationScope,
      'envelope': command,
    });
    return raw is Map<String, Object?> ? raw : const {};
  }

  // ------------------------------------------------------------ attachments

  /// Raw bytes per attachment chunk: keeps the base64 body well under the
  /// 1 MiB physical frame limit once the rpc-frame transport re-fragments.
  static const int attachmentChunkBytes = 384 * 1024;

  Map<String, Object?> _attachmentBase(String uploadId, String sessionId) {
    final connId = _connectionId;
    if (connId == null) throw StateError('attachment: no connectionId');
    return {
      'workspacePath': workspaceKey,
      'workspace': {'workspacePath': workspaceKey},
      'connectionId': connId,
      'uploadId': uploadId,
      'sessionId': sessionId,
    };
  }

  Future<Map<String, Object?>> _attachmentCall(
    String method,
    Map<String, Object?> args,
  ) async {
    final raw = await _channel.call(method, args);
    return raw is Map<String, Object?> ? raw : const {};
  }

  /// Uploads an attachment (begin/chunk/commit, mirrors the web client's
  /// `rNe()`), resuming from the server's `nextChunkIndex`. Returns the
  /// attachment descriptor `{ref, fileName, mime, bytes}` to pass to
  /// sendText / createSession.
  Future<Map<String, Object?>> attachmentPut({
    required String sessionId,
    required String fileName,
    required String mime,
    required Uint8List bytes,
    void Function(double progress)? onProgress,
  }) async {
    if (bytes.length > ProtocolLimits.attachmentMaxBytes) {
      throw StateError(
        'attachment too large (max '
        '${ProtocolLimits.attachmentMaxBytes ~/ (1024 * 1024)} MiB)',
      );
    }
    final uploadId = 'upload-${ids.newCommandId()}';
    final base = _attachmentBase(uploadId, sessionId);
    final totalChunks =
        (bytes.length + attachmentChunkBytes - 1) ~/ attachmentChunkBytes;
    if (totalChunks > ProtocolLimits.attachmentUploadMaxChunks) {
      throw StateError(
        'attachment chunk count exceeds '
        '${ProtocolLimits.attachmentUploadMaxChunks}',
      );
    }
    final checksum = 'sha256:${sha256.convert(bytes).toString()}';

    final beginRes = await _attachmentCall('attachmentBeginV4', {
      ...base,
      'fileName': fileName,
      'mime': mime,
      'totalBytes': bytes.length,
      'totalChunks': totalChunks,
      'checksum': checksum,
    });
    if (beginRes['state'] == 'committed') {
      // The server already holds an identical upload.
      onProgress?.call(1);
      return {
        'ref': beginRes['ref'],
        'fileName': fileName,
        'mime': mime,
        'bytes': bytes.length,
      };
    }
    var nextChunk = (beginRes['nextChunkIndex'] as num?)?.toInt() ?? 0;
    for (var n = nextChunk; n < totalChunks; n++) {
      final start = n * attachmentChunkBytes;
      final end = math.min(start + attachmentChunkBytes, bytes.length);
      final chunkRes = await _attachmentCall('attachmentChunkV4', {
        ...base,
        'chunkIndex': n,
        'dataBase64': base64Encode(Uint8List.sublistView(bytes, start, end)),
      });
      final serverNext = (chunkRes['nextChunkIndex'] as num?)?.toInt() ?? n + 1;
      if (serverNext != n + 1) {
        throw StateError('fault.attachment.invalidServerProgress');
      }
      onProgress?.call((n + 1) / totalChunks);
    }
    onProgress?.call(1);
    final commitRes = await _attachmentCall('attachmentCommitV4', base);
    return {
      'ref': commitRes['ref'],
      'fileName': fileName,
      'mime': mime,
      'bytes': bytes.length,
    };
  }

  /// Reads an attachment back (e.g. image previews). Returns `{bytes,
  /// mediaType}`.
  Future<({Uint8List bytes, String? mediaType})> attachmentRead(
    String sessionId, {
    required String ref,
  }) async {
    final chunks = <int>[];
    var offset = 0;
    String? mediaType;
    for (var round = 0; round < 1024; round++) {
      final res = await _attachmentCall('attachmentReadV4', {
        'workspacePath': workspaceKey,
        'sessionId': sessionId,
        'ref': ref,
        'offset': offset,
        'limit': attachmentChunkBytes,
      });
      mediaType ??= res['mediaType']?.toString();
      final data = res['dataBase64']?.toString();
      if (data != null && data.isNotEmpty) {
        chunks.addAll(base64Decode(data));
      }
      final next = (res['nextOffset'] as num?)?.toInt();
      final total = (res['totalBytes'] as num?)?.toInt();
      if (next == null || next <= offset) break;
      offset = next;
      if (total != null && offset >= total) break;
    }
    return (bytes: Uint8List.fromList(chunks), mediaType: mediaType);
  }

  /// The raw channel, for service RPCs (zcode-task / zcode-session).
  RpcChannel get channel => _channel;

  Future<void> dispose() async {
    await _conversationEventSub?.cancel();
    await _sessionsIndexEventSub?.cancel();
    await _workspaceConfigEventSub?.cancel();
    _assembler.dispose();
    await _conversationFrames.close();
    await _sessionsIndexFrames.close();
    await _workspaceConfigFrames.close();
  }
}

/// Builds a command envelope: `{commandId, clientId, sessionId, baseRevision?,
/// baseLogEpoch?, type, payload, issuedAt}`.
Map<String, Object?> buildCommand({
  required String commandId,
  required String clientId,
  String? sessionId,
  int? baseRevision,
  String? baseLogEpoch,
  required String type,
  required Map<String, Object?> payload,
}) => {
  'commandId': commandId,
  'clientId': clientId,
  // The envelope schema is `sessionId: string().nullable()` — required but
  // nullable. Omitting the key fails validation (proto.invalidPayload) for
  // sessionless commands like createSession.
  'sessionId': sessionId,
  'baseRevision': ?baseRevision,
  'baseLogEpoch': ?baseLogEpoch,
  'type': type,
  'payload': payload,
  'issuedAt': DateTime.now().millisecondsSinceEpoch,
};

String newCommandId() => ids.newCommandId();
