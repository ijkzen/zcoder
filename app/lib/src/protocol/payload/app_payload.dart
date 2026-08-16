/// Layer 2 — application payloads: typed `zcode_type` messages carried in
/// relay `data` frames. See docs/protocol/02-app-payloads.md.
///
/// Device→terminal messages are parsed into typed classes; terminal→device
/// requests are built by the request functions. RPC frames (layer 3) stay as
/// raw maps — they are the transport's own domain.
library;

/// Bridge identity shared by `workspace-bridge-*`, `rpc-frame*` and
/// `bridge-degraded` messages.
class BridgeIdentity {
  final String bridgeSessionId;
  final int? bridgeGeneration;
  final String? recoveryId;

  const BridgeIdentity({
    required this.bridgeSessionId,
    this.bridgeGeneration,
    this.recoveryId,
  });

  Map<String, Object?> toJson() => {
        'bridgeSessionId': bridgeSessionId,
        if (bridgeGeneration != null) 'bridgeGeneration': bridgeGeneration,
        if (recoveryId != null) 'recoveryId': recoveryId,
      };

  /// Frames match only when every present identity field is equal (missing
  /// optional fields match anything, mirroring the desktop's
  /// `rawIdentityMatches`).
  bool matches(Map<String, Object?> frame) {
    final sid = frame['bridgeSessionId'];
    if (sid is! String || sid != bridgeSessionId) return false;
    final gen = frame['bridgeGeneration'];
    if (bridgeGeneration != null && gen is! int) return false;
    if (bridgeGeneration != null && gen != bridgeGeneration) return false;
    final rid = frame['recoveryId'];
    if (recoveryId != null && rid is! String) return false;
    if (recoveryId != null && rid != recoveryId) return false;
    return true;
  }
}

/// `reason` enum shared by `app-error` and `workspace-bridge-error`.
class AppErrorReason {
  static const sessionNotFound = 'session-not-found';
  static const sessionExpired = 'session-expired';
  static const sessionConflict = 'session-conflict';
  static const workspaceClosed = 'workspace-closed';
  static const desktopDisconnected = 'desktop-disconnected';
  static const invalidMobileConnection = 'invalid-mobile-connection';
  static const desktopBootstrapTimeout = 'desktop-bootstrap-timeout';
  static const connectionRecoveryTimeout = 'connection-recovery-timeout';
  static const relayUnavailable = 'relay-unavailable';
  static const unsupportedAction = 'unsupported-action';
  static const unexpectedError = 'unexpected-error';
}

/// Parsed device→terminal payload.
sealed class AppPayload {
  const AppPayload();
  String get zcodeType;
}

class WorkspaceListData {
  final List<Map<String, Object?>> workspaces;
  final List<Map<String, Object?>>? tasks;
  final String? activeWorkspaceKey;
  final String? activeTaskId;

  const WorkspaceListData({
    required this.workspaces,
    this.tasks,
    this.activeWorkspaceKey,
    this.activeTaskId,
  });

  /// Canonical merge of the two lists: every task entry is kept (each task is
  /// one session — several sessions of the same workspace share its path, so
  /// dedup by key would collapse them); workspace entries only fill keys no
  /// task covers (tasks carry display status and win over the bare workspace
  /// entry).
  List<Map<String, Object?>> get mergedEntries {
    String keyOf(Map<String, Object?> e) {
      final id = e['workspaceIdentity'];
      if (id is String && id.trim().isNotEmpty) return id;
      final path = e['workspacePath'];
      return path is String ? path : '';
    }

    final out = <Map<String, Object?>>[];
    final taskKeys = <String>{};
    for (final t in tasks ?? const <Map<String, Object?>>[]) {
      out.add(t);
      taskKeys.add(keyOf(t));
    }
    for (final w in workspaces) {
      if (taskKeys.contains(keyOf(w))) continue;
      out.add(w);
    }
    return out;
  }

  /// Parses the `result` object of workspace-list response/updated payloads.
  static WorkspaceListData? fromResult(Object? result) {
    if (result is! Map<String, Object?>) return null;
    // The list of open workspaces rides in `workspaces`; the task list rides
    // in `tasks` (each task names its workspace). Tolerate shapes that only
    // carry one of them.
    final workspaces = (result['workspaces'] is List)
        ? (result['workspaces'] as List).whereType<Map<String, Object?>>().toList()
        : <Map<String, Object?>>[];
    final tasks = (result['tasks'] is List)
        ? (result['tasks'] as List).whereType<Map<String, Object?>>().toList()
        : null;
    final activeKey = result['activeWorkspaceKey'];
    final activeTask = result['activeTaskId'];
    return WorkspaceListData(
      workspaces: workspaces,
      tasks: tasks,
      activeWorkspaceKey: activeKey is String ? activeKey : null,
      activeTaskId: activeTask is String ? activeTask : null,
    );
  }
}

class WorkspaceListResponse extends AppPayload {
  final String requestId;
  final WorkspaceListData data;
  const WorkspaceListResponse(this.requestId, this.data);
  @override
  String get zcodeType => 'workspace-list-response';
}

class WorkspaceListUpdated extends AppPayload {
  final WorkspaceListData data;
  const WorkspaceListUpdated(this.data);
  @override
  String get zcodeType => 'workspace-list-updated';
}

class WorkspaceBridgeReady extends AppPayload {
  final String requestId;
  final BridgeIdentity identity;
  final Map<String, Object?> bridge;

  const WorkspaceBridgeReady(this.requestId, this.identity, this.bridge);
  @override
  String get zcodeType => 'workspace-bridge-ready';
}

class WorkspaceBridgeError extends AppPayload {
  final String? requestId;
  final String reason;
  final String error;
  final BridgeIdentity? identity;

  const WorkspaceBridgeError({
    this.requestId,
    required this.reason,
    required this.error,
    this.identity,
  });
  @override
  String get zcodeType => 'workspace-bridge-error';
}

class WorkspaceReconnectResponse extends AppPayload {
  final String requestId;
  final String workspaceKey;
  final bool success;
  final String? error;
  const WorkspaceReconnectResponse(
      this.requestId, this.workspaceKey, this.success, this.error);
  @override
  String get zcodeType => 'workspace-reconnect-response';
}

class PlatformResponse extends AppPayload {
  final String requestId;
  final String method;
  final bool success;
  final Object? result;
  final String? error;
  const PlatformResponse(this.requestId, this.method, this.success, this.result, this.error);
  @override
  String get zcodeType => 'platform-response';
}

class BridgeDegraded extends AppPayload {
  final BridgeIdentity identity;
  final String reason; // rpc-transport-fault | rpc-frame-gap | buffer-overflow | buffer-timeout
  const BridgeDegraded(this.identity, this.reason);
  @override
  String get zcodeType => 'bridge-degraded';
}

class AppError extends AppPayload {
  final String? requestId;
  final String reason;
  final String error;
  const AppError(this.requestId, this.reason, this.error);
  @override
  String get zcodeType => 'app-error';
}

/// rpc-frame / rpc-frame-ack pass through to layer 3 as raw maps.
class RpcTransportPayload extends AppPayload {
  final Map<String, Object?> frame;
  final bool isAck;
  const RpcTransportPayload(this.frame, {required this.isAck});
  @override
  String get zcodeType => isAck ? 'rpc-frame-ack' : 'rpc-frame';
}

BridgeIdentity? _identity(Map<String, Object?> json) {
  final sid = json['bridgeSessionId'];
  if (sid is! String) return null;
  final gen = json['bridgeGeneration'];
  final rid = json['recoveryId'];
  return BridgeIdentity(
    bridgeSessionId: sid,
    bridgeGeneration: gen is int ? gen : null,
    recoveryId: rid is String ? rid : null,
  );
}

String _str(Object? v) => v is String ? v : '';

/// Parses a device→terminal payload. Unknown types return null (forward
/// compatibility: the desktop's router ignores unknown types too).
AppPayload? parseAppPayload(Map<String, Object?> json) {
  switch (json['zcode_type']) {
    case 'workspace-list-response':
      final data = WorkspaceListData.fromResult(json['result']);
      if (data == null) return null;
      return WorkspaceListResponse(_str(json['requestId']), data);
    case 'workspace-list-updated':
      final data = WorkspaceListData.fromResult(json['result']);
      if (data == null) return null;
      return WorkspaceListUpdated(data);
    case 'workspace-bridge-ready':
      final identity = _identity(json);
      if (identity == null) return null;
      final bridge = json['bridge'];
      return WorkspaceBridgeReady(
        _str(json['requestId']),
        identity,
        bridge is Map<String, Object?> ? bridge : const {},
      );
    case 'workspace-bridge-error':
      return WorkspaceBridgeError(
        requestId: json['requestId'] is String ? json['requestId'] as String : null,
        reason: _str(json['reason']),
        error: _str(json['error']),
        identity: _identity(json),
      );
    case 'workspace-reconnect-response':
      return WorkspaceReconnectResponse(
        _str(json['requestId']),
        _str(json['workspaceKey']),
        json['success'] == true,
        json['error'] is String ? json['error'] as String : null,
      );
    case 'platform-response':
      return PlatformResponse(
        _str(json['requestId']),
        _str(json['method']),
        json['success'] == true,
        json['result'],
        json['error'] is String ? json['error'] as String : null,
      );
    case 'bridge-degraded':
      final identity = _identity(json);
      if (identity == null) return null;
      return BridgeDegraded(identity, _str(json['reason']));
    case 'app-error':
      return AppError(
        json['requestId'] is String ? json['requestId'] as String : null,
        _str(json['reason']),
        _str(json['error']),
      );
    case 'rpc-frame':
      return RpcTransportPayload(json, isAck: false);
    case 'rpc-frame-ack':
      return RpcTransportPayload(json, isAck: true);
    default:
      return null;
  }
}

// ---------- Terminal→device request builders ----------

Map<String, Object?> bootstrapRequest(String requestId) =>
    {'zcode_type': 'bootstrap-request', 'requestId': requestId};

Map<String, Object?> workspaceListRequest(String requestId) =>
    {'zcode_type': 'workspace-list-request', 'requestId': requestId};

Map<String, Object?> workspaceBridgeOpen({
  required String requestId,
  required BridgeIdentity identity,
  required String workspaceKey,
  String? taskId,
}) =>
    {
      'zcode_type': 'workspace-bridge-open',
      'requestId': requestId,
      ...identity.toJson(),
      'workspaceKey': workspaceKey,
      if (taskId != null) 'taskId': taskId,
    };

Map<String, Object?> workspaceReconnectRequest({
  required String requestId,
  required String workspaceKey,
}) =>
    {
      'zcode_type': 'workspace-reconnect-request',
      'requestId': requestId,
      'workspaceKey': workspaceKey,
    };

Map<String, Object?> mobileViewStateUpdate({
  String? activeWorkspaceKey,
  String? activeTaskId,
  required Map<String, Object?> deviceInfo,
}) =>
    {
      'zcode_type': 'mobile-view-state-update',
      'viewState': {
        if (activeWorkspaceKey != null) 'activeWorkspaceKey': activeWorkspaceKey,
        if (activeTaskId != null) 'activeTaskId': activeTaskId,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      },
      'deviceInfo': deviceInfo,
    };

/// `deviceInfo` shape per the desktop's schema: platform/version/name plus
/// optional browser-ish fields and a REQUIRED `updatedAt`.
Map<String, Object?> mobileDeviceInfo({
  required String platform,
  required String version,
  required String name,
  String? language,
  bool? online,
}) =>
    {
      'platform': platform,
      'version': version,
      'name': name,
      if (language != null) 'language': language,
      if (online != null) 'online': online,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    };

/// Terminal-side diagnostic report the device logs for support
/// (`event` ∈ state-transition | socket-close | socket-error |
/// recover-start | recover-scheduled | pair-status | failure).
Map<String, Object?> mobileDiagnostic({
  required String event,
  String? state,
  String? previousState,
  String? pairStatus,
  int? closeCode,
  String? closeReason,
  bool? wasClean,
  bool? wasPaired,
  String? failureReason,
  String? failureMessage,
  bool? online,
}) =>
    {
      'zcode_type': 'mobile-diagnostic',
      'event': event,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      if (state != null) 'state': state,
      if (previousState != null) 'previousState': previousState,
      if (pairStatus != null) 'pairStatus': pairStatus,
      if (closeCode != null) 'closeCode': closeCode,
      if (closeReason != null) 'closeReason': closeReason,
      if (wasClean != null) 'wasClean': wasClean,
      if (wasPaired != null) 'wasPaired': wasPaired,
      if (failureReason != null) 'failureReason': failureReason,
      if (failureMessage != null) 'failureMessage': failureMessage,
      if (online != null) 'online': online,
    };

Map<String, Object?> platformRequest({
  required String requestId,
  required String method,
  Object? args,
}) =>
    {
      'zcode_type': 'platform-request',
      'requestId': requestId,
      'method': method,
      if (args != null) 'args': args,
    };
