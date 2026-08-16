/// The `zcode-session` RPC channel: topic subscriptions (conversation,
/// sessions index), logical frames, and conversation commands.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../bridge/binary_rpc.dart';
import '../core/random_ids.dart' as ids;

const String sessionChannelName = 'zcode-agent';

sealed class TopicFrame {
  const TopicFrame();
}

class HelloFrame extends TopicFrame {
  final Map<String, Object?> data;
  const HelloFrame(this.data);

  String? get connectionId => data['connectionId'] as String?;
  Map<String, Object?> get capabilities => data['capabilities'] is Map<String, Object?>
      ? data['capabilities'] as Map<String, Object?>
      : const {};
}

class SubscribeAckFrame extends TopicFrame {
  final String subscriptionId;
  final String mode; // snapshot | resume
  final String logEpoch;
  const SubscribeAckFrame(this.subscriptionId, this.mode, this.logEpoch);
}

class TopicDataFrame extends TopicFrame {
  final String topic;
  final String subscriptionId;
  final int fromSeq;
  final int toSeq;
  final Map<String, Object?> payload;
  final String? deliveryKind; // initial | online | recovery

  const TopicDataFrame({
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
  List<Object?>? get deltas => !isSnapshot && payload['deltas'] is List
      ? payload['deltas'] as List
      : null;
}

class SubscriptionStateFrame extends TopicFrame {
  final String connectionId;
  final String state; // saturated | drained | closed
  const SubscriptionStateFrame(this.connectionId, this.state);
}

TopicFrame parseTopicFrame(Map<String, Object?> json) {
  switch (json['kind']) {
    case 'hello':
      return HelloFrame(json);
    case 'ack':
      return tryParseAck(json) ?? SubscribeAckFrame('', 'snapshot', '');
    case 'topic-frame':
      final payload = json['payload'];
      return TopicDataFrame(
        topic: json['topic']?.toString() ?? '',
        subscriptionId: json['subscriptionId']?.toString() ?? '',
        fromSeq: json['fromSeq'] as int? ?? 0,
        toSeq: json['toSeq'] as int? ?? 0,
        payload: payload is Map<String, Object?> ? payload : const {},
        deliveryKind: json['deliveryKind'] as String?,
      );
    case 'subscriptionState':
      return SubscriptionStateFrame(
        json['connectionId']?.toString() ?? '',
        json['state']?.toString() ?? '',
      );
    default:
      // Unknown logical frame — ignore.
      return _UnknownFrame();
  }
}

/// Extracts an ack from either a topic event (`{kind:"ack", ack:{...}}`) or
/// an RPC response (`{ack:{subscriptionId, mode, logEpoch}}` — the 201 args).
/// Returns null if not an ack.
SubscribeAckFrame? tryParseAck(Object? raw) {
  if (raw is! Map<String, Object?>) return null;
  final ack = raw['ack'];
  if (ack is! Map<String, Object?>) return null;
  return SubscribeAckFrame(
    ack['subscriptionId']?.toString() ?? '',
    ack['mode']?.toString() ?? 'snapshot',
    ack['logEpoch']?.toString() ?? '',
  );
}

class _UnknownFrame extends TopicFrame {}

/// Client for the topic protocol over the zcode-session channel.
class SessionChannel {
  final BinaryRpcChannel _channel;
  final String clientId;
  final String workspaceKey;

  final _conversationFrames = StreamController<TopicFrame>.broadcast();
  final _sessionsIndexFrames = StreamController<TopicFrame>.broadcast();

  Stream<TopicFrame> get conversationFrames => _conversationFrames.stream;
  Stream<TopicFrame> get sessionsIndexFrames => _sessionsIndexFrames.stream;

  String? _connectionId;

  Map<String, Object?> _eventListenArgs() => {
        'workspacePath': workspaceKey,
        if (_connectionId != null) 'connectionId': _connectionId,
      };

  StreamSubscription<Object?>? _conversationEventSub;
  StreamSubscription<Object?>? _sessionsIndexEventSub;

  SessionChannel(this._channel, {required this.clientId, required this.workspaceKey});

  /// Call `helloConversationV4()` then `initializeConversationV4()`.
  /// Returns the hello frame.
  Future<HelloFrame> initialize() async {
    final helloRaw = await _channel.call('helloConversationV4');
    debugPrint('[zremote] hello response: $helloRaw');
    final hello = helloRaw is Map<String, Object?>
        ? HelloFrame(helloRaw)
        : HelloFrame(const {});
    _connectionId = hello.connectionId;
    await _channel.call('initializeConversationV4', {
      'kind': 'clientHello',
      'protocolVersion': 3,
      'clientId': clientId,
      // clientKind is optional in the clientHello schema; 'mobileRemote' tells
      // the host this is a phone remote-control client (the desktop's own UI
      // sends 'desktop', the web page omits it).
      'clientKind': 'mobileRemote',
      'appVersion': '3.4.0',
    });
    // Subscribe to event pushes for conversation + sessions index frames.
    // The event methods take the workspace target as their argument.
    _conversationEventSub = _channel
        .listen('onDynamicConversationFrame', _eventListenArgs())
        .listen(_dispatchConversationFrame);
    _sessionsIndexEventSub = _channel
        .listen('onDynamicSessionsIndexFrame', _eventListenArgs())
        .listen(_dispatchSessionsIndexFrame);
    return hello;
  }

  void _dispatchConversationFrame(Object? raw) =>
      _dispatch(_conversationFrames, raw);

  void _dispatchSessionsIndexFrame(Object? raw) =>
      _dispatch(_sessionsIndexFrames, raw);

  void _dispatch(StreamController<TopicFrame> target, Object? raw) {
    if (raw is! Map<String, Object?>) return;
    if (!target.isClosed) target.add(parseTopicFrame(raw));
  }

  // Subscribe shape: workspace target + runtime policy + the hello
  // connectionId (the host forwards it as the trusted connection for the
  // runtime-side subscription — without it the runtime never pushes).
  Map<String, Object?> _subscribeFields(String topic, String visibility) => {
        'workspacePath': workspaceKey,
        'runtimePolicy': 'existing-only',
        if (_connectionId != null) 'connectionId': _connectionId,
        if (visibility != 'foreground') 'visibility': visibility,
      };

  /// Subscribes to a conversation topic; resolves with the ack frame.
  Future<SubscribeAckFrame> subscribe(String sessionId, {String visibility = 'foreground'}) async {
    final raw = await _channel.call('subscribeConversationV4', {
      ..._subscribeFields('conversation/$sessionId', visibility),
      'sessionId': sessionId,
    });
    final ack = tryParseAck(raw);
    if (ack == null) throw StateError('unexpected subscribe response: $raw');
    return ack;
  }

  Future<SubscribeAckFrame> subscribeSessionsIndex(String workspaceKey) async {
    final raw = await _channel.call('subscribeSessionsIndexV4', {
      ..._subscribeFields('sessions-index/$workspaceKey', 'foreground'),
      'workspacePath': workspaceKey,
    });
    debugPrint('[zremote] sessions-index subscribe response: $raw');
    final ack = tryParseAck(raw);
    if (ack == null) throw StateError('unexpected subscribe response: $raw');
    return ack;
  }

  /// Pulls the current snapshot for a sessions-index subscription.
  Future<void> resyncSessionsIndex(String subscriptionId, {String? logEpoch}) async {
    await _channel.call('resyncSessionsIndexV4', {
      ..._subscribeFields('sessions-index/$workspaceKey', 'foreground'),
      'workspacePath': workspaceKey,
      'subscriptionId': subscriptionId,
      'base': logEpoch == null ? null : {'logEpoch': logEpoch, 'seq': 0},
      'forceSnapshot': true,
    });
  }

  /// Pulls the current snapshot for a conversation subscription.
  Future<void> resyncConversation(String subscriptionId, String sessionId, {String? logEpoch}) async {
    await _channel.call('resyncConversationV4', {
      ..._subscribeFields('conversation/$sessionId', 'foreground'),
      'sessionId': sessionId,
      'subscriptionId': subscriptionId,
      'base': logEpoch == null ? null : {'logEpoch': logEpoch, 'seq': 0},
      'forceSnapshot': true,
    });
  }

  Future<void> unsubscribe(String topic, String subscriptionId) async {
    await _channel.call('unsubscribeConversationV4', {
      'kind': 'unsubscribe',
      'topic': topic,
      'subscriptionId': subscriptionId,
    });
  }

  /// Fetches the newest rows. `beforeRowId` exclusive; limit ≤ 200.
  Future<Map<String, Object?>> requestRowsRange(
    String sessionId, {
    int? beforeRowId,
    int limit = 200,
  }) async {
    // Host validates BOTH a top-level workspacePath (routing) and a nested
    // workspace object (params schema) — probe-verified against the live
    // desktop: omitting either fails with "workspace.workspacePath/workspaceKey:
    // expected string, received undefined".
    final raw = await _channel.call('conversationRowsRangeV4', {
      'workspacePath': workspaceKey,
      'workspace': {'workspacePath': workspaceKey},
      'sessionId': sessionId,
      if (beforeRowId != null) 'beforeRowId': beforeRowId,
      'limit': limit,
    });
    return raw is Map<String, Object?> ? raw : const {};
  }

  // ---------- zcode-session / zcode-task service RPCs ----------
  //
  // Event push (204 frames) never reaches terminal connections, so the
  // snapshot-only data (pending requests, context usage, model config) is
  // pulled via these polling RPCs instead (probe-verified 2026-08-16).

  /// Snapshot of one session: settings (model/thoughtLevel), runtime
  /// contextUsage (used/size/breakdown/cache) and projection.pendingPermissions
  /// (approvals + AskUserQuestion requests, each with a `requestId`).
  Future<Map<String, Object?>> readSession(String sessionId) async {
    final raw = await _channel.client
        .channel('zcode-session')
        .call('readSession', {
      'workspacePath': workspaceKey,
      'sessionId': sessionId,
      'messageLimit': 1,
    });
    return raw is Map<String, Object?> ? raw : const {};
  }

  /// Cumulative token counters for a session.
  Future<Map<String, Object?>> getTaskTokenUsage(String sessionId) async {
    final raw = await _channel.client
        .channel('zcode-task')
        .call('getTaskTokenUsage', {
      'workspacePath': workspaceKey,
      'taskId': sessionId,
    });
    return raw is Map<String, Object?> ? raw : const {};
  }

  /// Switches the session's model (and optionally its thought level) directly
  /// on the runtime — no baseRevision needed, unlike the switchModelConfig
  /// conversation command.
  Future<Map<String, Object?>> setSessionModel(
    String sessionId, {
    required String provider,
    required String model,
    String? thoughtLevel,
  }) async {
    final raw = await _channel.client.channel('zcode-session').call('setModel', {
      'workspacePath': workspaceKey,
      'sessionId': sessionId,
      'model': '$provider/$model',
      if (thoughtLevel != null) 'thoughtLevel': thoughtLevel,
    });
    return raw is Map<String, Object?> ? raw : const {};
  }

  /// Switches the session's thought level (reasoning effort).
  Future<Map<String, Object?>> setSessionThoughtLevel(
    String sessionId,
    String thoughtLevel,
  ) async {
    final raw = await _channel.client.channel('zcode-session').call(
          'setThoughtLevel',
          {
            'workspacePath': workspaceKey,
            'sessionId': sessionId,
            'thoughtLevel': thoughtLevel,
          },
        );
    return raw is Map<String, Object?> ? raw : const {};
  }

  /// The workspace's model registry and default thought level — used by the
  /// "new session" picker to let the user choose the model/thought level
  /// before creating a session.
  Future<Map<String, Object?>> readWorkspaceState() async {
    final raw = await _channel.client
        .channel('zcode-session')
        .call('readWorkspaceState', {
      'workspacePath': workspaceKey,
    });
    return raw is Map<String, Object?> ? raw : const {};
  }

  /// Sends one conversation command and returns the result. The host reads
  /// `params.envelope.clientId`, so the command must travel inside an
  /// `envelope` key with the workspace target alongside.
  Future<Map<String, Object?>> sendCommand(Map<String, Object?> command) async {
    final raw = await _channel.call('sendConversationCommandV4', {
      'workspacePath': workspaceKey,
      'workspace': {'workspacePath': workspaceKey},
      'envelope': command,
    });
    return raw is Map<String, Object?> ? raw : const {};
  }

  Future<void> dispose() async {
    await _conversationEventSub?.cancel();
    await _sessionsIndexEventSub?.cancel();
    await _conversationFrames.close();
    await _sessionsIndexFrames.close();
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
