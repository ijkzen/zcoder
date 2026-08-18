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

  // sync: true — callers (e.g. workspaces_page._open) read `app.phase` right
  // after `selectWorkspace` returns; an async broadcast would deliver the
  // ready event only in a later microtask, making a *successful* open look
  // like a failure ("打开项目失败：未知错误", first tap always failed).
  final _phaseController = StreamController<BridgePhase>.broadcast(sync: true);
  final _workspacesController = StreamController<List<Workspace>>.broadcast();
  final _activeWorkspaceController = StreamController<Workspace?>.broadcast();
  final _errorsController = StreamController<BridgeException>.broadcast();

  Stream<BridgePhase> get phaseStream => _phaseController.stream;
  Stream<List<Workspace>> get workspacesStream => _workspacesController.stream;
  Stream<Workspace?> get activeWorkspaceStream =>
      _activeWorkspaceController.stream;
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
  final _pendingReconnect = <String, Completer<WorkspaceReconnectResponse>>{};
  int _requestCounter = 0;

  bool _disposed = false;

  // Bridge recovery state: when the transport faults (rpc-transport-fault,
  // bridge-degraded) or the relay drops, commands gate on recovery instead
  // of failing into a dead bridge. See docs/protocol/03.
  bool _degraded = false;
  bool _recoveryInFlight = false;
  int _recoveryCount = 0;
  final _healthyWaiters = <Completer<void>>{};
  final _recoveredController = StreamController<int>.broadcast();

  /// Bumped on every successful bridge recovery. Conversation controllers
  /// resubscribe when it fires — server-side subscription state died with
  /// the old bridge.
  Stream<int> get recoveredStream => _recoveredController.stream;

  bool get isDegraded => _degraded;

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
        _setPhase(BridgePhase.connecting);
      case RelayState.reconnecting:
        // Distinguish a relay drop (we were connected and are reconnecting)
        // from the initial connect; the UI shows a reconnect banner on this
        // phase and clears it once the relay pairs again.
        _setPhase(BridgePhase.reconnecting);
        // A relay drop makes the bridge untrustworthy: gate commands and
        // run recovery once we are paired again.
        if (_transport != null && !_degraded) {
          zlog('[zremote] relay dropped while bridge open — degrading');
          _degraded = true;
        }
      case RelayState.paired:
        // The device keeps its bridge across our reconnects and replays its
        // unacked frames; we mirror that for our own outbound side.
        _transport?.replayUnacked();
        _setPhase(
          _topicSession == null ? BridgePhase.pairing : BridgePhase.ready,
        );
        _requestWorkspaceList();
        if (_degraded && _transport != null) {
          unawaited(_recoverBridge());
        }
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
        _onDegraded(reason);
      case RpcTransportPayload():
        _transport?.acceptPayload(payload.frame);
      case WorkspaceReconnectResponse():
        _pendingReconnect.remove(payload.requestId)?.complete(payload);
      case PlatformResponse():
        break;
    }
  }

  /// Opens a bridge to [workspace] and initializes the topic session.
  Future<void> selectWorkspace(Workspace workspace) async {
    zlog(
      '[bridge.selectWorkspace] enter phase=$_phase '
      'recoveryInFlight=$_recoveryInFlight',
    );
    if (_phase != BridgePhase.pairing && _phase != BridgePhase.ready) {
      // The relay is mid-reconnect (or still authenticating): wait for it to
      // settle instead of failing — tapping a project during a reconnect
      // window must not show an error.
      zlog(
        '[bridge.selectWorkspace] waiting for relay ready '
        '(phase=$_phase)',
      );
      await _waitForRelayReady();
      zlog('[bridge.selectWorkspace] relay ready, phase=$_phase');
    }
    // A recovery loop from a previous degradation may still be running (it
    // would open its own bridge and swap the stack under us); let it finish
    // so the two bridge-opens don't race.
    while (_recoveryInFlight) {
      zlog('[bridge.selectWorkspace] waiting for recovery loop to finish');
      await Future.delayed(const Duration(milliseconds: 200));
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

    zlog(
      '[zremote] sending workspace-bridge-open '
      'key=${workspace.workspaceKey} task=${workspace.taskId}',
    );
    relay.sendPayload(
      workspaceBridgeOpen(
        requestId: requestId,
        identity: identity,
        workspaceKey: workspace.workspaceKey,
        taskId: workspace.taskId,
      ),
    );

    final readyIdentity = await completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () => throw BridgeException(
        'desktop-bootstrap-timeout',
        'bridge open timed out',
      ),
    );

    _activeWorkspace = workspace;
    await _installStack(readyIdentity, workspace.workspaceKey);
    if (!_disposed) _activeWorkspaceController.add(workspace);
  }

  /// Builds the rpc-frame transport + RPC channel + topic session for a
  /// bridge identity and awaits channel initialization, replacing any
  /// previous stack. Conversation controllers resubscribe via
  /// [recoveredStream].
  Future<void> _installStack(
    BridgeIdentity readyIdentity,
    String workspaceKey,
  ) async {
    _degradedSub?.cancel();
    final transport = RpcFrameTransport(
      sendPayload: relay.sendPayload,
      identity: readyIdentity,
    );
    _degradedSub = transport.degradedStream.listen(_onDegraded);
    _transport = transport;

    final rpc = ChannelClient(transport.messageStream, transport.sendMessage);
    final channel = TopicSession(
      rpc.channel(agentChannelName),
      clientId: clientId,
      workspaceKey: workspaceKey,
      workspaceIdentity: _activeWorkspace?.workspaceIdentity,
    );
    _rpc?.dispose();
    _topicSession?.dispose();
    _rpc = rpc;
    _topicSession = channel;
    rpc.start();
    try {
      await rpc.whenInitialized.timeout(const Duration(seconds: 30));
      zlog(
        '[zremote] rpc initialized (bridge ${readyIdentity.bridgeSessionId})',
      );
      await channel.initialize().timeout(const Duration(seconds: 30));
      _setPhase(BridgePhase.ready);
      _sendViewState();
    } catch (e) {
      zlog('[zremote] channel initialize failed: $e');
      _emitError(BridgeException('initialize-failed', e.toString()));
      rethrow;
    }
  }

  // ---------- Bridge recovery ----------

  /// Waits until the relay is paired again (phase pairing/ready); throws
  /// [BridgeException] after [timeout] so the caller can surface a real error.
  Future<void> _waitForRelayReady({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (_phase == BridgePhase.pairing || _phase == BridgePhase.ready) return;
    final completer = Completer<void>();
    late StreamSubscription<RelayState> sub;
    sub = relay.stateStream.listen((state) {
      if (state == RelayState.paired && !completer.isCompleted) {
        completer.complete();
      }
    });
    try {
      await completer.future.timeout(
        timeout,
        onTimeout: () {
          throw BridgeException(
            'relay-not-ready',
            'relay 未就绪（${_phase.name}），请稍后重试',
          );
        },
      );
    } finally {
      await sub.cancel();
    }
  }

  /// Entry point for transport faults (`rpc-transport-fault` etc.) and the
  /// desktop's `bridge-degraded` push: gates commands and runs the retrying
  /// recovery loop (reconnect-request first, full reopen as fallback).
  void _onDegraded(String reason) {
    if (_degraded) return;
    _degraded = true;
    zlog('[zremote] bridge degraded: $reason');
    _emitError(BridgeException('bridge-degraded', reason));
    unawaited(_recoverBridge());
  }

  Future<void> _recoverBridge() async {
    if (_recoveryInFlight) return;
    _recoveryInFlight = true;
    try {
      for (var attempt = 1; attempt <= 15 && !_disposed; attempt++) {
        if (await _recoverOnce()) return;
        zlog('[zremote] bridge recovery attempt $attempt failed, retrying');
        await Future.delayed(const Duration(seconds: 3));
      }
    } finally {
      _recoveryInFlight = false;
    }
  }

  /// One recovery attempt: cheap `workspace-reconnect-request` first, full
  /// bridge reopen (new identity, bumped generation, recoveryId) as fallback.
  /// Returns true when the bridge is healthy again.
  Future<bool> _recoverOnce() async {
    final workspace = _activeWorkspace;
    final transport = _transport;
    if (workspace == null || transport == null) {
      _finishRecovery();
      return true;
    }
    try {
      final res = await _requestReconnect(
        workspace.workspaceKey,
      ).timeout(const Duration(seconds: 15));
      if (res.success) {
        zlog('[zremote] workspace reconnected: ${workspace.workspaceKey}');
        transport.replayUnacked();
        _finishRecovery();
        return true;
      }
      zlog('[zremote] reconnect-request rejected: ${res.error}');
    } catch (e) {
      zlog('[zremote] reconnect-request failed: $e');
    }
    try {
      await _reopenBridge(workspace);
      _finishRecovery();
      return true;
    } catch (e) {
      zlog('[zremote] bridge reopen failed: $e');
      return false;
    }
  }

  void _finishRecovery() {
    _clearDegraded();
    _recoveryCount += 1;
    if (!_recoveredController.isClosed) {
      _recoveredController.add(_recoveryCount);
    }
  }

  void _clearDegraded() {
    _degraded = false;
    final waiters = List<Completer<void>>.from(_healthyWaiters);
    _healthyWaiters.clear();
    for (final w in waiters) {
      if (!w.isCompleted) w.complete();
    }
  }

  /// Resolves once the bridge is healthy again; throws [TimeoutException]
  /// otherwise. Commands gate on this so a send during a recovery window
  /// doesn't hang on a dead bridge.
  Future<void> _waitHealthy({Duration timeout = const Duration(seconds: 45)}) {
    if (!_degraded || _disposed) return Future.value();
    final completer = Completer<void>();
    _healthyWaiters.add(completer);
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _healthyWaiters.remove(completer);
        throw TimeoutException('bridge recovery timeout');
      },
    );
  }

  Future<WorkspaceReconnectResponse> _requestReconnect(
    String workspaceKey,
  ) async {
    final requestId = _nextRequestId('workspace-reconnect');
    final completer = Completer<WorkspaceReconnectResponse>();
    _pendingReconnect[requestId] = completer;
    relay.sendPayload(
      workspaceReconnectRequest(
        requestId: requestId,
        workspaceKey: workspaceKey,
      ),
    );
    return completer.future;
  }

  /// Reopens the bridge after a failed reconnect-request: fresh
  /// `workspace-bridge-open` (new bridgeSessionId, bumped generation,
  /// previous recoveryId), then swaps the stack in place. Subscriptions
  /// resubscribe via [recoveredStream].
  Future<void> _reopenBridge(Workspace workspace) async {
    final oldIdentity = _transport?.identity;
    final identity = BridgeIdentity(
      bridgeSessionId: ids.newBridgeSessionId(),
      bridgeGeneration: (oldIdentity?.bridgeGeneration ?? 1) + 1,
      recoveryId: oldIdentity?.recoveryId ?? oldIdentity?.bridgeSessionId,
    );
    final requestId = _nextRequestId('bridge-reopen');
    final completer = Completer<BridgeIdentity>();
    _pendingBridgeOpen[requestId] = completer;
    zlog(
      '[zremote] reopening bridge for ${workspace.workspaceKey} '
      '(gen ${identity.bridgeGeneration})',
    );
    relay.sendPayload(
      workspaceBridgeOpen(
        requestId: requestId,
        identity: identity,
        workspaceKey: workspace.workspaceKey,
        taskId: workspace.taskId,
      ),
    );
    final readyIdentity = await completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () => throw BridgeException(
        'bridge-reopen-timeout',
        'bridge reopen timed out',
      ),
    );
    await _installStack(readyIdentity, workspace.workspaceKey);
    zlog('[zremote] bridge reopened');
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
    relay.sendPayload(
      mobileViewStateUpdate(
        activeWorkspaceKey: workspace.workspaceKey,
        activeTaskId: workspace.taskId,
        deviceInfo: mobileDeviceInfo(
          platform: 'android',
          version: '1.0.0',
          name: 'zcode-remote',
          language: 'zh-CN',
        ),
      ),
    );
  }

  /// Sends a conversation command, gating on bridge health: while degraded
  /// (transport fault or relay drop) the command waits for recovery instead
  /// of failing into a dead bridge. A timeout is retried once — with a fresh
  /// commandId — only when the bridge is degraded (the command may then never
  /// have reached the desktop); a healthy-bridge timeout is a double-delivery
  /// risk and is rethrown.
  Future<Map<String, Object?>> sendCommand({
    String? sessionId,
    int? baseRevision,
    String? baseLogEpoch,
    required String type,
    required Map<String, Object?> payload,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    await _waitHealthy();
    final channel = _topicSession;
    if (channel == null) {
      throw BridgeException('no-bridge', 'session channel not ready');
    }
    Future<Map<String, Object?>> send() => channel.sendCommand(
      buildCommand(
        commandId: newCommandId(),
        clientId: clientId,
        sessionId: sessionId,
        baseRevision: baseRevision,
        baseLogEpoch: baseLogEpoch,
        type: type,
        payload: payload,
      ),
    );
    try {
      return await send().timeout(timeout);
    } on TimeoutException {
      if (!_degraded) rethrow;
      zlog(
        '[zremote] command $type timed out during degradation — '
        'waiting for recovery and retrying',
      );
      await _waitHealthy();
      return send().timeout(timeout);
    }
  }

  TopicSession? get topicSession => _topicSession;

  /// Raw RPC channel by name (e.g. 'skills', 'model-provider').
  RpcChannel? channel(String name) => _rpc?.channel(name);

  /// The active workspace as a service call target.
  WorkspaceTarget? get workspaceTarget {
    final workspace = _activeWorkspace;
    if (workspace == null) return null;
    return WorkspaceTarget(
      workspacePath: workspace.workspaceKey,
      workspaceIdentity: workspace.workspaceIdentity,
    );
  }

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
    for (final w in _healthyWaiters) {
      if (!w.isCompleted) {
        w.completeError(BridgeException('disposed', 'bridge disposed'));
      }
    }
    _healthyWaiters.clear();
    _pendingReconnect.clear();
    await _phaseController.close();
    await _workspacesController.close();
    await _activeWorkspaceController.close();
    await _errorsController.close();
    await _recoveredController.close();
  }
}
