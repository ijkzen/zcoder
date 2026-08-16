/// Layer 5 — the `zcode-agent` channel's V4 conversation API: hello +
/// clientHello initialization, topic subscriptions (conversation /
/// sessions-index / workspace-config), resync, unsubscribe, history reads and
/// conversation commands. Topic events are reassembled from wire frames by
/// [WireFrameAssembler]. See docs/protocol/05-v4-conversation-data-plane.md.
library;

import '../zlog.dart';

import 'dart:async';


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

  TopicSession(this._channel, {required this.clientId, required this.workspaceKey});

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

  Map<String, Object?> _listenArgs() => {
        'workspacePath': workspaceKey,
        if (_connectionId != null) 'connectionId': _connectionId,
      };

  StreamSubscription<Object?>? _conversationEventSub;
  StreamSubscription<Object?>? _sessionsIndexEventSub;
  StreamSubscription<Object?>? _workspaceConfigEventSub;

  /// `helloConversationV4()` then `initializeConversationV4(clientHello)`,
  /// then subscribes to the three frame-push events. Returns the hello map.
  Future<Map<String, Object?>> initialize({String appVersion = '3.4.0'}) async {
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
      // clientKind is optional in the clientHello schema; 'mobileRemote'
      // tells the host this is a phone remote-control client.
      'clientKind': 'mobileRemote',
      'appVersion': appVersion,
    });
    _conversationEventSub = _channel
        .listen('onDynamicConversationFrame', _listenArgs())
        .listen(_dispatch(_conversationFrames));
    _sessionsIndexEventSub = _channel
        .listen('onDynamicSessionsIndexFrame', _listenArgs())
        .listen(_dispatch(_sessionsIndexFrames));
    _workspaceConfigEventSub = _channel
        .listen('onDynamicWorkspaceConfigFrame', _listenArgs())
        .listen(_dispatch(_workspaceConfigFrames));
    return helloRaw is Map<String, Object?> ? helloRaw : const {};
  }

  void Function(Object?) _dispatch(StreamController<TopicFrame> target) {
    return (raw) {
      if (raw is! Map<String, Object?>) return;
      final result = _assembler.accept(raw);
      if (result == null) return;
      final frame =
          TopicFrame.fromMap(result.frame, deliveryKind: result.deliveryKind);
      if (frame == null) return;
      if (!target.isClosed) target.add(frame);
    };
  }

  // Subscribe shape: workspace target + runtime policy + the hello
  // connectionId (the host forwards it as the trusted connection for the
  // runtime-side subscription — without it the runtime never pushes).
  Map<String, Object?> _subscribeFields(String visibility) => {
        'workspacePath': workspaceKey,
        'runtimePolicy': 'existing-only',
        if (_connectionId != null) 'connectionId': _connectionId,
        if (visibility != 'foreground') 'visibility': visibility,
      };

  /// Subscribes to a conversation topic; resolves with the ack.
  Future<SubscribeAck> subscribe(String sessionId, {String visibility = 'foreground'}) async {
    final raw = await _channel.call('subscribeConversationV4', {
      ..._subscribeFields(visibility),
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
      ..._subscribeFields('foreground'),
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
  Future<void> unsubscribeConversation(String sessionId, String subscriptionId) async {
    await _channel.call('unsubscribeConversationV4', {
      'workspacePath': workspaceKey,
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
      if (beforeRowId != null) 'beforeRowId': beforeRowId,
      'limit': limit.clamp(1, ProtocolLimits.rowsRangeMaxLimit),
    });
    return raw is Map<String, Object?> ? raw : const {};
  }

  /// Sends one conversation command and returns the command result. The host
  /// reads `params.envelope.clientId`, so the command must travel inside an
  /// `envelope` key with the workspace target alongside.
  Future<Map<String, Object?>> sendCommand(Map<String, Object?> command) async {
    final raw = await _channel.call('sendConversationCommandV4', {
      'workspacePath': workspaceKey,
      'workspace': {'workspacePath': workspaceKey},
      'envelope': command,
    });
    return raw is Map<String, Object?> ? raw : const {};
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
}) =>
    {
      'commandId': commandId,
      'clientId': clientId,
      // The envelope schema is `sessionId: string().nullable()` — required but
      // nullable. Omitting the key fails validation (proto.invalidPayload) for
      // sessionless commands like createSession.
      'sessionId': sessionId,
      if (baseRevision != null) 'baseRevision': baseRevision,
      if (baseLogEpoch != null) 'baseLogEpoch': baseLogEpoch,
      'type': type,
      'payload': payload,
      'issuedAt': DateTime.now().millisecondsSinceEpoch,
    };

String newCommandId() => ids.newCommandId();
