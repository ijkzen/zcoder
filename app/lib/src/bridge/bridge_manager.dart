/// Orchestrates the connection lifecycle over the protocol module: relay
/// pairing → app payloads (workspace list, bridge open) → acknowledged
/// transport → binary RPC → topic session. This is the single object the UI
/// talks to; everything wire-format lives in `lib/src/protocol/`.
library;

import '../protocol/zlog.dart';

import 'dart:async';


import '../protocol/protocol.dart';
import '../protocol/core/random_ids.dart' as ids;

enum BridgePhase {
  idle,
  connecting, // relay connecting / authenticating
  pairing, // relay paired, waiting for workspace list
  ready, // bridge open, session channel initialized
  reconnecting,
  failed,
}

class BridgeException implements Exception {
  final String reason;
  final String message;
  BridgeException(this.reason, this.message);
  @override
  String toString() => 'BridgeException($reason): $message';
}

class BridgeManager {
  final RelayClient relay;
  final String clientId;

  BridgeManager({required this.relay, required this.clientId});

  final _phaseController = StreamController<BridgePhase>.broadcast();
  final _workspacesController = StreamController<List<Workspace>>.broadcast();
  final _activeWorkspaceController = StreamController<Workspace?>.broadcast();
  final _errorsController = StreamController<BridgeException>.broadcast();

  Stream<BridgePhase> get phaseStream => _phaseController.stream;
  Stream<List<Workspace>> get workspacesStream => _workspacesController.stream;
  Stream<Workspace?> get activeWorkspaceStream => _activeWorkspaceController.stream;
  Stream<BridgeException> get errorsStream => _errorsController.stream;

  BridgePhase _phase = BridgePhase.idle;
  BridgePhase get phase => _phase;

  List<Workspace> _workspaces = [];
  List<Workspace> get workspaces => _workspaces;

  Workspace? _activeWorkspace;
  Workspace? get activeWorkspace => _activeWorkspace;

  RpcFrameTransport? _transport;
  ChannelClient? _rpc;
  TopicSession? _topicSession;

  /// Task/session service RPCs for the active workspace.
  ZcodeTaskService? get taskService {
    final workspace = _activeWorkspace;
    final rpc = _rpc;
    if (workspace == null || rpc == null) return null;
    return ZcodeTaskService(
      rpc.channel('zcode-task'),
      WorkspaceTarget(
        workspacePath: workspace.workspaceKey,
        workspaceIdentity: workspace.workspaceIdentity,
      ),
    );
  }

  ZcodeSessionService? get sessionService {
    final workspace = _activeWorkspace;
    final rpc = _rpc;
    if (workspace == null || rpc == null) return null;
    return ZcodeSessionService(
      rpc.channel('zcode-session'),
      WorkspaceTarget(
        workspacePath: workspace.workspaceKey,
        workspaceIdentity: workspace.workspaceIdentity,
      ),
    );
  }

  final _pendingWorkspaceList = <String, Completer<List<Workspace>>>{};
  final _pendingBridgeOpen = <String, Completer<BridgeIdentity>>{};
  int _requestCounter = 0;

  bool _disposed = false;

  StreamSubscription? _relayStateSub;
  StreamSubscription? _relayPayloadSub;
  StreamSubscription? _degradedSub;

  /// Starts the manager: connects the relay and processes its stream.
  Future<void> start() async {
    _relayStateSub = relay.stateStream.listen(_onRelayState);
    _relayPayloadSub = relay.payloadStream.listen(_onRelayPayload);
    await relay.connect();
  }

  void _onRelayState(RelayState state) {
    switch (state) {
      case RelayState.connecting:
      case RelayState.authenticating:
      case RelayState.reconnecting:
        _setPhase(BridgePhase.connecting);
      case RelayState.paired:
        // The device keeps its bridge across our reconnects and replays its
        // unacked frames; we mirror that for our own outbound side.
        _transport?.replayUnacked();
        _setPhase(_topicSession == null ? BridgePhase.pairing : BridgePhase.ready);
        _requestWorkspaceList();
      case RelayState.closed:
        _setPhase(BridgePhase.failed);
    }
  }

  void _setPhase(BridgePhase p) {
    _phase = p;
    if (!_disposed) _phaseController.add(p);
  }

  // ---------- Layer 2: app payloads ----------

  Future<List<Workspace>> _requestWorkspaceList() async {
    final requestId = _nextRequestId('workspace-list');
    zlog('[zremote] sending workspace-list-request');
    final completer = Completer<List<Workspace>>();
    _pendingWorkspaceList[requestId] = completer;
    relay.sendPayload(workspaceListRequest(requestId));
    return completer.future;
  }

  /// Parses workspace-list data into the Workspace list the UI renders,
  /// using the payload type's canonical merge (tasks first, workspaces fill
  /// gaps, dedup by workspace key).
  List<Workspace> _parseWorkspaces(WorkspaceListData data) =>
      data.mergedEntries.map(Workspace.fromJson).toList();

  void _applyWorkspaceList(WorkspaceListData data) {
    _workspaces = _parseWorkspaces(data);
    if (!_disposed) _workspacesController.add(_workspaces);
  }

  void _onRelayPayload(Map<String, Object?> raw) {
    final payload = parseAppPayload(raw);
    if (payload == null) {
      zlog('[zremote] unknown app payload: ${raw['zcode_type']}');
      return;
    }
    switch (payload) {
      case WorkspaceListResponse(:final requestId, :final data):
        _applyWorkspaceList(data);
        _pendingWorkspaceList.remove(requestId)?.complete(_workspaces);
      case WorkspaceListUpdated(:final data):
        _applyWorkspaceList(data);
      case WorkspaceBridgeReady(:final requestId, :final identity):
        _pendingBridgeOpen.remove(requestId)?.complete(identity);
      case WorkspaceBridgeError(:final requestId, :final reason, :final error):
        final exception = BridgeException(reason, error);
        if (requestId != null) {
          _pendingBridgeOpen.remove(requestId)?.completeError(exception);
        }
        _emitError(exception);
      case AppError(:final requestId, :final reason, :final error):
        final exception = BridgeException(reason, error);
        if (requestId != null) {
          _pendingBridgeOpen.remove(requestId)?.completeError(exception);
        }
        _emitError(exception);
      case BridgeDegraded(:final reason):
        _emitError(BridgeException('bridge-degraded', reason));
      case RpcTransportPayload():
        _transport?.acceptPayload(payload.frame);
      case WorkspaceReconnectResponse():
      case PlatformResponse():
        break;
    }
  }

  /// Opens a bridge to [workspace] and initializes the topic session.
  Future<void> selectWorkspace(Workspace workspace) async {
    if (_phase != BridgePhase.pairing && _phase != BridgePhase.ready) {
      throw BridgeException('invalid-state', 'relay not ready (phase=$_phase)');
    }
    _teardownBridge();
    _setPhase(BridgePhase.connecting);

    final identity = BridgeIdentity(
      bridgeSessionId: ids.newBridgeSessionId(),
      bridgeGeneration: 1,
    );
    final requestId = _nextRequestId('bridge-open');
    final completer = Completer<BridgeIdentity>();
    _pendingBridgeOpen[requestId] = completer;

    zlog('[zremote] sending workspace-bridge-open '
        'key=${workspace.workspaceKey} task=${workspace.taskId}');
    relay.sendPayload(workspaceBridgeOpen(
      requestId: requestId,
      identity: identity,
      workspaceKey: workspace.workspaceKey,
      taskId: workspace.taskId,
    ));

    final readyIdentity = await completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () => throw BridgeException(
          'desktop-bootstrap-timeout', 'bridge open timed out'),
    );

    final transport = RpcFrameTransport(sendPayload: relay.sendPayload, identity: readyIdentity);
    _degradedSub = transport.degradedStream.listen((reason) {
      _emitError(BridgeException('bridge-degraded', reason));
    });
    _transport = transport;

    final rpc = ChannelClient(transport.messageStream, transport.sendMessage);
    final channel = TopicSession(
      rpc.channel(agentChannelName),
      clientId: clientId,
      workspaceKey: workspace.workspaceKey,
    );
    final bridgeReady = Completer<void>();
    unawaited(rpc.whenInitialized.then((_) async {
      zlog('[zremote] rpc initialized');
      try {
        await channel.initialize();
        _rpc = rpc;
        _topicSession = channel;
        _activeWorkspace = workspace;
        if (!_disposed) _activeWorkspaceController.add(workspace);
        _setPhase(BridgePhase.ready);
        _sendViewState();
        if (!bridgeReady.isCompleted) bridgeReady.complete();
      } catch (e) {
        zlog('[zremote] channel initialize failed: $e');
        if (!bridgeReady.isCompleted) bridgeReady.completeError(e);
        _emitError(BridgeException('initialize-failed', e.toString()));
      }
    }));

    rpc.start();

    // selectWorkspace only returns once the session channel is live, so
    // callers can rely on phase == ready afterwards.
    await bridgeReady.future.timeout(const Duration(seconds: 30), onTimeout: () {
      throw BridgeException('initialize-timeout', '会话通道初始化超时');
    });
  }

  /// Sends a raw application payload over the relay (ad-hoc requests).
  void sendPayload(Map<String, Object?> payload) {
    relay.sendPayload(payload);
  }

  /// Re-requests the workspace/task list. Concurrent calls share one
  /// in-flight request per requestId; this returns the newest pending one.
  Future<List<Workspace>> refreshWorkspaceList() {
    if (_pendingWorkspaceList.isNotEmpty) {
      return _pendingWorkspaceList.values.last.future;
    }
    return _requestWorkspaceList();
  }

  void _sendViewState() {
    final workspace = _activeWorkspace;
    if (workspace == null) return;
    relay.sendPayload(mobileViewStateUpdate(
      activeWorkspaceKey: workspace.workspaceKey,
      activeTaskId: workspace.taskId,
      deviceInfo: mobileDeviceInfo(
        platform: 'android',
        version: '1.0.0',
        name: 'zcode-remote',
        language: 'zh-CN',
      ),
    ));
  }

  /// Sends a conversation command through the topic session.
  Future<Map<String, Object?>> sendCommand({
    String? sessionId,
    int? baseRevision,
    String? baseLogEpoch,
    required String type,
    required Map<String, Object?> payload,
  }) {
    final channel = _topicSession;
    if (channel == null) {
      throw BridgeException('no-bridge', 'session channel not ready');
    }
    return channel.sendCommand(buildCommand(
      commandId: newCommandId(),
      clientId: clientId,
      sessionId: sessionId,
      baseRevision: baseRevision,
      baseLogEpoch: baseLogEpoch,
      type: type,
      payload: payload,
    ));
  }

  TopicSession? get topicSession => _topicSession;

  void _teardownBridge() {
    _degradedSub?.cancel();
    _degradedSub = null;
    _topicSession?.dispose();
    _topicSession = null;
    _rpc?.dispose();
    _rpc = null;
    _transport?.dispose();
    _transport = null;
    _activeWorkspace = null;
  }

  void _emitError(BridgeException e) {
    if (!_disposed && !_errorsController.isClosed) _errorsController.add(e);
  }

  String _nextRequestId(String prefix) {
    _requestCounter++;
    final random = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    return '$prefix-$random-$_requestCounter';
  }

  Future<void> dispose() async {
    _disposed = true;
    await _relayStateSub?.cancel();
    await _relayPayloadSub?.cancel();
    _teardownBridge();
    await _phaseController.close();
    await _workspacesController.close();
    await _activeWorkspaceController.close();
    await _errorsController.close();
  }
}
