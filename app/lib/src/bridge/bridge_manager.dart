/// Orchestrates the connection lifecycle: relay pairing → workspace bridge →
/// binary RPC → session channel. This is the single object the UI talks to.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'acknowledged_protocol.dart';
import 'binary_rpc.dart';
import '../core/random_ids.dart' as ids;
import '../relay/relay_client.dart';
import '../session/session_channel.dart';
import '../session/models.dart';

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

  AcknowledgedRelayProtocol? _protocol;
  SessionChannel? _sessionChannel;

  final _pendingBridgeOpen = <String, Completer<void>>{};
  int _requestCounter = 0;

  bool _disposed = false;

  StreamSubscription? _relayStateSub;
  StreamSubscription? _relayPayloadSub;

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
        _setPhase(BridgePhase.pairing);
        _requestWorkspaceList();
      case RelayState.closed:
        _setPhase(BridgePhase.failed);
    }
  }

  void _setPhase(BridgePhase p) {
    _phase = p;
    if (!_disposed) _phaseController.add(p);
  }

  // ---------- Application payloads over the relay ----------

  Future<List<Workspace>> _requestWorkspaceList() async {
    final requestId = _nextRequestId('workspace-list');
    debugPrint('[zremote] sending workspace-list-request');
    final completer = Completer<List<Workspace>>();
    _pendingWorkspaceList = completer;
    relay.sendPayload({'zcode_type': 'workspace-list-request', 'requestId': requestId});
    return completer.future;
  }

  Completer<List<Workspace>>? _pendingWorkspaceList;

  /// Opens a bridge to [workspace] and initializes the session channel.
  Future<void> selectWorkspace(Workspace workspace) async {
    if (_phase != BridgePhase.pairing && _phase != BridgePhase.ready) {
      throw BridgeException('invalid-state', 'relay not ready (phase=$_phase)');
    }
    _teardownBridge();
    _setPhase(BridgePhase.connecting);

    final bridgeSessionId = _newBridgeSessionId();
    final requestId = _nextRequestId('bridge-open');
    final completer = Completer<void>();
    _pendingBridgeOpen[requestId] = completer;

    debugPrint('[zremote] sending workspace-bridge-open key=${workspace.workspaceKey} task=${workspace.taskId}');
    relay.sendPayload({
      'zcode_type': 'workspace-bridge-open',
      'requestId': requestId,
      'bridgeSessionId': bridgeSessionId,
      'bridgeGeneration': 1,
      'workspaceKey': workspace.workspaceKey,
    });

    await completer.future.timeout(const Duration(seconds: 30), onTimeout: () {
      throw BridgeException('desktop-bootstrap-timeout', 'bridge open timed out');
    });

    final protocol = AcknowledgedRelayProtocol(
      relay: relay,
      bridgeSessionId: bridgeSessionId,
    );
    _protocol = protocol;

    final rpc = BinaryRpcClient(protocol.messageStream, protocol.sendMessage);
    final bridgeReady = Completer<void>();
    rpc.whenInitialized.then((_) async {
      debugPrint('[zremote] rpc initialized');
      try {
        final channel = SessionChannel(
          rpc.channel(sessionChannelName),
          clientId: clientId,
          workspaceKey: workspace.workspaceKey,
        );
        _sessionChannel = channel;
        await channel.initialize();
        _activeWorkspace = workspace;
        if (!_disposed) _activeWorkspaceController.add(workspace);
        _setPhase(BridgePhase.ready);
        _sendViewState();
        if (!bridgeReady.isCompleted) bridgeReady.complete();
      } catch (e) {
        debugPrint('[zremote] channel initialize failed: $e');
        if (!bridgeReady.isCompleted) bridgeReady.completeError(e);
        _emitError(BridgeException('initialize-failed', e.toString()));
      }
    });

    rpc.start();

    // selectWorkspace only returns once the session channel is live, so
    // callers can rely on phase == ready afterwards.
    await bridgeReady.future.timeout(const Duration(seconds: 30), onTimeout: () {
      throw BridgeException('initialize-timeout', '会话通道初始化超时');
    });
  }

  void _onRelayPayload(Map<String, Object?> payload) {
    final type = payload['zcode_type'];
    debugPrint('[zremote] app payload: $type');
    switch (type) {
      case 'workspace-list-response':
        debugPrint('[zremote] workspace-list-response payload=${jsonEncode(payload)}');
        final result = payload['result'];
        if (result is Map<String, Object?>) {
          // The desktop returns a `tasks` array (each task naming its
          // workspace); some shapes may carry a `workspaces` array instead.
          final raw = (result['tasks'] is List)
              ? result['tasks'] as List
              : (result['workspaces'] is List ? result['workspaces'] as List : null);
          if (raw != null) {
            _workspaces = raw
                .whereType<Map<String, Object?>>()
                .map(Workspace.fromJson)
                .toList();
            if (!_disposed) _workspacesController.add(_workspaces);
            _pendingWorkspaceList?.complete(_workspaces);
            _pendingWorkspaceList = null;
          }
        }
      case 'workspace-bridge-ready':
        final requestId = payload['requestId'];
        if (requestId is String) {
          _pendingBridgeOpen.remove(requestId)?.complete();
        }
      case 'workspace-bridge-error':
      case 'app-error':
        final requestId = payload['requestId'];
        final reason = payload['reason']?.toString() ?? 'unknown';
        final error = payload['error']?.toString() ?? '';
        if (requestId is String) {
          _pendingBridgeOpen.remove(requestId)?.completeError(
                BridgeException(reason, error),
              );
        }
        _emitError(BridgeException(reason, error));
      case 'workspace-list-updated':
        final result = payload['result'];
        if (result is Map<String, Object?>) {
          final raw = (result['tasks'] is List)
              ? result['tasks'] as List
              : (result['workspaces'] is List ? result['workspaces'] as List : null);
          if (raw != null) {
            _workspaces = raw
                .whereType<Map<String, Object?>>()
                .map(Workspace.fromJson)
                .toList();
            if (!_disposed) _workspacesController.add(_workspaces);
          }
        }
      case 'rpc-frame':
        debugPrint('[zremote] rpc-frame received (protocol=${_protocol != null})');
        _protocol?.acceptFrame(payload);
      case 'rpc-frame-ack':
        _protocol?.acceptAck(payload);
      case 'bridge-degraded':
        // The bridge lost frames; for v1 we surface it and let the user
        // reconnect the workspace.
        final reason = payload['reason']?.toString() ?? 'unknown';
        _emitError(BridgeException('bridge-degraded', reason));
    }
  }

  /// Sends a raw application payload over the relay (used by the UI for
  /// ad-hoc requests like refreshing the workspace list).
  void sendPayload(Map<String, Object?> payload) {
    relay.sendPayload(payload);
  }

  /// Re-requests the workspace/task list (e.g. after a rename or archive so
  /// the sessions list reflects the change without waiting for a push).
  /// Concurrent calls share the in-flight request.
  Future<List<Workspace>> refreshWorkspaceList() {
    final pending = _pendingWorkspaceList;
    if (pending != null) return pending.future;
    return _requestWorkspaceList();
  }

  void _sendViewState() {    final workspace = _activeWorkspace;
    if (workspace == null) return;
    relay.sendPayload({
      'zcode_type': 'mobile-view-state-update',
      'viewState': {
        'activeWorkspaceKey': workspace.workspaceKey,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      },
      'deviceInfo': {
        'platform': 'android',
        'version': '1.0.0',
        'name': 'zcode-remote',
        'timezone': DateTime.now().timeZoneName,
      },
    });
  }

  /// Sends a conversation command through the session channel.
  Future<Map<String, Object?>> sendCommand({
    String? sessionId,
    int? baseRevision,
    String? baseLogEpoch,
    required String type,
    required Map<String, Object?> payload,
  }) {
    final channel = _sessionChannel;
    if (channel == null) {
      throw BridgeException('no-bridge', 'session channel not ready');
    }
    final command = buildCommand(
      commandId: newCommandId(),
      clientId: clientId,
      sessionId: sessionId,
      baseRevision: baseRevision,
      baseLogEpoch: baseLogEpoch,
      type: type,
      payload: payload,
    );
    return channel.sendCommand(command);
  }

  SessionChannel? get sessionChannel => _sessionChannel;

  void _teardownBridge() {
    _sessionChannel?.dispose();
    _sessionChannel = null;
    _protocol?.dispose();
    _protocol = null;
    _activeWorkspace = null;
  }

  void _emitError(BridgeException e) {
    if (!_disposed && !_errorsController.isClosed) _errorsController.add(e);
  }

  String _nextRequestId(String prefix) {
    _requestCounter++;
    final random = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    return '$prefix-$random-${_requestCounter}';
  }

  String _newBridgeSessionId() => ids.newBridgeSessionId();

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
