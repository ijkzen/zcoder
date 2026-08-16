/// Central app state: pairings, the active relay/bridge connection, the
/// workspace's session list, and the open conversation. UI listens to this
/// ChangeNotifier and calls its methods.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ChangeNotifier, debugPrint;

import 'protocol/core/random_ids.dart' as ids;
import 'bridge/bridge_manager.dart';
import 'protocol/relay/relay_client.dart';
import 'protocol/relay/relay_frame.dart';
import 'protocol/services/services.dart';
import 'protocol/zlog.dart';
import 'session/conversation_controller.dart';
import 'protocol/topics/topic_models.dart';
import 'storage/app_database.dart';

/// Callbacks the notification layer hooks into.
typedef NotificationHook = void Function(Map<String, Object?> event);

class AppController extends ChangeNotifier {
  final AppDatabase db = AppDatabase.instance;

  AppController({String? clientId})
    : clientId = clientId ?? _generateClientId();

  final String clientId;

  // ---------- Pairings ----------

  List<StoredPairing> pairings = [];
  StoredPairing? activePairing;

  Future<void> loadPairings() async {
    pairings = await db.listPairings();
    notifyListeners();
  }

  /// Adds a pairing from a scanned QR URL. Returns the stored pairing and
  /// whether it already existed (re-pairing the same desktop refreshes the
  /// credentials but keeps the user's custom name).
  Future<({StoredPairing pairing, bool alreadyExisted})> addPairingFromUrl(
    String url,
  ) async {
    final credential = PairingCredential.fromUrl(url);
    if (credential == null) {
      throw FormatException('不是有效的 ZCode 远程控制链接');
    }
    final existing = await db.findPairing(credential.deviceSid);
    final now = DateTime.now().millisecondsSinceEpoch;
    final pairing = StoredPairing(
      id: existing?.id ?? 0,
      deviceSid: credential.deviceSid,
      passHash: credential.passHash,
      timestamp: credential.timestamp,
      deviceMid: credential.deviceMid,
      deviceName: credential.deviceName,
      appVersion: credential.appVersion,
      customName: existing?.customName ?? '',
      createdAt: existing?.createdAt ?? now,
    );
    await db.upsertPairing(pairing);
    await loadPairings();
    return (
      pairing: pairings.firstWhere(
        (p) => p.deviceSid == pairing.deviceSid,
        orElse: () => pairing,
      ),
      alreadyExisted: existing != null,
    );
  }

  Future<void> renamePairing(StoredPairing pairing, String name) async {
    await db.renamePairing(pairing.id, name);
    await loadPairings();
  }

  Future<void> removePairing(StoredPairing pairing) async {
    if (activePairing?.id == pairing.id) {
      await disconnect();
    }
    await db.deletePairing(pairing.id);
    await loadPairings();
  }

  // ---------- Connection ----------

  BridgePhase _phase = BridgePhase.idle;
  BridgePhase get phase => _phase;

  RelayClient? _relay;
  BridgeManager? _bridge;
  BridgeManager? get bridge => _bridge;

  List<Workspace> _workspaces = [];
  List<Workspace> get workspaces => _workspaces;

  Workspace? get activeWorkspace => _bridge?.activeWorkspace;

  String? lastError;

  StreamSubscription<BridgePhase>? _phaseSub;
  StreamSubscription<List<Workspace>>? _workspacesSub;
  StreamSubscription<BridgeException>? _errorsSub;
  StreamSubscription<RelayFailure>? _relayFailureSub;

  /// Connects to a saved pairing. Reconnects are handled by RelayClient.
  Future<void> connectTo(StoredPairing pairing) async {
    await disconnect();
    activePairing = pairing;
    notifyListeners();

    final relay = RelayClient(credential: pairing.toCredential());
    final bridge = BridgeManager(relay: relay, clientId: clientId);
    _relay = relay;
    _bridge = bridge;

    _phaseSub = bridge.phaseStream.listen((p) {
      debugPrint('[zremote] bridge phase: $p');
      _phase = p;
      notifyListeners();
    });
    _workspacesSub = bridge.workspacesStream.listen((w) {
      _workspaces = w;
      notifyListeners();
    });
    _errorsSub = bridge.errorsStream.listen((e) {
      lastError = '${e.reason}: ${e.message}';
      bridgeNotificationHook?.call(e);
      notifyListeners();
    });
    // Relay failures (including relay-close codes) reach the notification
    // hook; closedStream only fires on intentional disconnect, so it is not
    // subscribed here.
    _relayFailureSub = relay.failureStream.listen((f) {
      bridgeNotificationHook?.call(BridgeException(f.reason.name, f.message));
    });

    await bridge.start();
  }

  /// Selects a workspace (opens the bridge) and refreshes the session list.
  /// Re-selecting the already-active workspace is a no-op so navigating back
  /// to the project list and into the same project doesn't re-open the bridge.
  Future<void> selectWorkspace(Workspace workspace) async {
    final bridge = _bridge;
    zlog('[_selectWorkspace] enter phase=$_phase bridge=${bridge != null}');
    if (bridge == null) {
      throw StateError('未连接桌面端');
    }
    if (_phase == BridgePhase.ready &&
        bridge.activeWorkspace?.workspaceKey == workspace.workspaceKey) {
      zlog('[_selectWorkspace] early return (already ready)');
      return;
    }
    await bridge.selectWorkspace(workspace);
    zlog('[_selectWorkspace] bridge done, phase=$_phase');
    notifyListeners();
  }

  // ---------- Sessions (tasks of the active workspace) ----------

  /// Sessions of the active workspace, sourced from the workspace-list
  /// `tasks` payload (the desktop's own task list — this is what the web
  /// client renders, not the sessions-index topic). Archived tasks are kept
  /// out of the default list (the Archived tab filters them in).
  List<Workspace> get sessions {
    final workspace = _bridge?.activeWorkspace;
    if (workspace == null) return const [];
    return _workspaces
        .where(
          (w) =>
              w.taskId != null &&
              !w.archived &&
              w.workspaceKey == workspace.workspaceKey,
        )
        .toList()
      ..sort((a, b) {
        if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
        return (b.updatedAt ?? b.createdAt ?? 0).compareTo(
          a.updatedAt ?? a.createdAt ?? 0,
        );
      });
  }

  /// Pinned sessions of the active workspace.
  List<Workspace> get pinnedSessions =>
      sessions.where((w) => w.pinned).toList();

  /// Archived sessions of the active workspace (hidden from the default
  /// list; the Archived tab browses and unarchives them).
  List<Workspace> get archivedSessions {
    final workspace = _bridge?.activeWorkspace;
    if (workspace == null) return const [];
    return _workspaces
        .where(
          (w) =>
              w.taskId != null &&
              w.archived &&
              w.workspaceKey == workspace.workspaceKey,
        )
        .toList()
      ..sort(
        (a, b) => (b.updatedAt ?? b.createdAt ?? 0).compareTo(
          a.updatedAt ?? a.createdAt ?? 0,
        ),
      );
  }

  bool get sessionsIndexConnected => _bridge?.activeWorkspace != null;

  // ---------- Task ops ----------

  /// Pins/unpins a task (`zcode-task.setTaskPinned`), then refreshes the list.
  Future<void> setTaskPinned(String taskId, {required bool pinned}) async {
    final service = _bridge?.taskService;
    if (service == null) throw StateError('未连接');
    await service.setTaskPinned(taskId, pinned: pinned);
    await refreshSessions();
  }

  /// Unarchives a task so it shows up in the session list again.
  Future<void> unarchiveSession(String taskId) async {
    final service = _bridge?.taskService;
    if (service == null) throw StateError('未连接');
    await service.unarchiveTask(taskId);
    await refreshSessions();
  }

  /// Marks a task read (`setTaskUnread(false)`) — called when its session is
  /// opened. Best-effort: failures only log.
  Future<void> markTaskRead(String taskId) async {
    final service = _bridge?.taskService;
    if (service == null) return;
    try {
      await service.setTaskUnread(taskId, unread: false);
    } catch (e) {
      debugPrint('[zremote] markTaskRead failed: $e');
    }
  }

  // ---------- Conversation ----------

  ConversationController? _conversation;
  ConversationController? get conversation => _conversation;

  /// Opens (subscribes to) a session conversation. Seeds the offline cache
  /// first so the history is visible before the first snapshot arrives.
  Future<void> openSession(String sessionId) async {
    await _conversation?.dispose();
    _conversation = null;
    _cachedRowIds.clear();
    _notifiedInteractions.clear();
    _lastNotifiedPhase = null;
    final bridge = _bridge;
    if (bridge == null) return;
    final controller = ConversationController(bridge, sessionId);
    _conversation = controller;
    _startStallMonitor();
    try {
      final cachedRows = await db.cachedRowJson(sessionId);
      final seed = cachedRows
          .map(jsonDecode)
          .whereType<Map<String, Object?>>()
          .map(ConversationRow.fromJson)
          .toList();
      controller.seedRows(seed);
      _cachedRowIds.addAll(seed.map((r) => r.rowId));
    } catch (_) {
      // Cache read failure is non-fatal.
    }
    controller.stateStream.listen((state) {
      _handleConversationState(state);
      notifyListeners();
    });
    try {
      await controller.start();
      // Opening the session clears its unread badge (best-effort).
      unawaited(markTaskRead(sessionId));
    } catch (e) {
      lastError = '会话打开失败: $e';
      notifyListeners();
    }
  }

  Future<void> closeConversation() async {
    _stopStallMonitor();
    await _conversation?.dispose();
    _conversation = null;
    notifyListeners();
  }

  // ---------- Commands ----------

  /// Sends a conversation command against the open conversation, attaching
  /// its revision/logEpoch as the base for optimistic concurrency.
  Future<Map<String, Object?>> _sendCommand(
    String type,
    Map<String, Object?> payload, {
    String? sessionId,
  }) async {
    final bridge = _bridge;
    if (bridge == null) throw StateError('未连接');
    final state = _conversation?.state;
    // Without event push the snapshot's revision/logEpoch never arrive; an
    // empty logEpoch fails host validation (min 1) and a bogus revision would
    // trip optimistic-concurrency checks. Omit the base unless a real
    // snapshot supplied it.
    final hasSnapshotBase =
        (state?.revision ?? 0) > 0 && (state?.logEpoch.isNotEmpty ?? false);
    return bridge.sendCommand(
      sessionId: sessionId ?? state?.sessionId,
      baseRevision: hasSnapshotBase ? state!.revision : null,
      baseLogEpoch: hasSnapshotBase ? state!.logEpoch : null,
      type: type,
      payload: payload,
    );
  }

  Future<Map<String, Object?>> sendText(
    String text, {
    String? sessionId,
    List<Map<String, Object?>>? attachments,
  }) => _sendCommand('sendText', {
    'text': text,
    if (attachments != null && attachments.isNotEmpty)
      'attachments': attachments,
  }, sessionId: sessionId);

  Future<Map<String, Object?>> sendGoalCommand(String text) =>
      _sendCommand('sendGoalCommand', {'text': text});

  Future<void> stop() async {
    await _sendCommand('stop', const {});
  }

  /// Compacts the open conversation (summarizes the history so far).
  Future<Map<String, Object?>> compact() => _sendCommand('compact', const {});

  /// Re-runs one assistant turn (`retryTurn`; target is `{rowId, entityId}`).
  Future<Map<String, Object?>> retryTurn(Map<String, Object?> target) =>
      _sendCommand('retryTurn', {'target': target});

  /// Edits and resends a user message (`editUserQuery`).
  Future<Map<String, Object?>> editUserQuery(
    Map<String, Object?> target,
    String newText,
  ) => _sendCommand('editUserQuery', {'target': target, 'newText': newText});

  /// Collaboration mode (build / edit / plan / yolo).
  Future<Map<String, Object?>> switchCollaborationMode(String mode) =>
      _sendCommand('switchCollaborationMode', {'mode': mode});

  /// Followup mode (queue / guide).
  Future<Map<String, Object?>> setFollowupMode(String mode) =>
      _sendCommand('setFollowupMode', {'mode': mode});

  /// Pauses the session's goal (goal mode; errors if none is running).
  Future<Map<String, Object?>> pauseGoal() =>
      _sendCommand('pauseGoal', const {});

  /// Resumes the session's paused goal.
  Future<Map<String, Object?>> resumeGoal() =>
      _sendCommand('resumeGoal', const {});

  /// Uploads an attachment (begin/chunk/commit) and returns its descriptor
  /// `{ref, fileName, mime, bytes}` for sendText / createSession.
  Future<Map<String, Object?>> uploadAttachment(
    String sessionId, {
    required String fileName,
    required String mime,
    required Uint8List bytes,
    void Function(double progress)? onProgress,
  }) async {
    final topic = _bridge?.topicSession;
    if (topic == null) throw StateError('未连接');
    return topic.attachmentPut(
      sessionId: sessionId,
      fileName: fileName,
      mime: mime,
      bytes: bytes,
      onProgress: onProgress,
    );
  }

  /// Fetches an attachment's bytes back (`attachmentReadV4`) for in-chat
  /// previews; null when the read fails.
  Future<Uint8List?> readAttachment(String ref) async {
    final sessionId = _conversation?.state?.sessionId;
    final topic = _bridge?.topicSession;
    if (sessionId == null || topic == null) return null;
    try {
      final result = await topic.attachmentRead(sessionId, ref: ref);
      final bytes = result.bytes;
      return bytes.isEmpty ? null : bytes;
    } catch (e) {
      zlog('[zremote] attachmentRead failed: $e');
      return null;
    }
  }

  /// Resolves a pending request from readSession (approval or AskUserQuestion).
  /// [requestId] is the pendingPermissions[].requestId — the same id the
  /// desktop's web client passes to resolveInteraction.
  Future<void> resolveRequest(
    String requestId, {
    String? optionId,
    String? action,
    Object? content,
  }) async {
    await _sendCommand('resolveInteraction', {
      'interactionId': requestId,
      'answer': {
        'optionId': ?optionId,
        'action': ?action,
        'content': ?content,
      },
    });
  }

  /// Switches the open session's model (+ optional thought level) directly via
  /// the zcode-session service — no baseRevision needed.
  Future<void> switchModel(
    String provider,
    String model, {
    String? thoughtLevel,
  }) async {
    final service = _bridge?.sessionService;
    if (service == null) throw StateError('未连接');
    final sessionId = _conversation?.state?.sessionId;
    if (sessionId == null) throw StateError('会话未打开');
    await service.setModel(
      sessionId,
      provider: provider,
      model: model,
      thoughtLevel: thoughtLevel,
    );
  }

  /// Switches the open session's thought level (reasoning effort).
  Future<void> switchThoughtLevel(String thoughtLevel) async {
    final service = _bridge?.sessionService;
    if (service == null) throw StateError('未连接');
    final sessionId = _conversation?.state?.sessionId;
    if (sessionId == null) throw StateError('会话未打开');
    await service.setThoughtLevel(sessionId, thoughtLevel);
  }

  Future<void> resolveInteraction(
    String interactionId, {
    String? optionId,
    String? freeText,
    String? action, // accept | decline | cancel
    Object? content, // AskUserQuestion answers map
  }) async {
    await _sendCommand('resolveInteraction', {
      'interactionId': interactionId,
      'answer': {
        'optionId': ?optionId,
        'freeText': ?freeText,
        'action': ?action,
        'content': ?content,
      },
    });
  }

  /// Fetches the workspace's model registry (models + thought levels). The
  /// result is cached for the bridge's lifetime — every model picker (new
  /// session AND open conversation) must show this same full list, while the
  /// session-level readSession settings only expose what the current session
  /// resolves to (often a single provider, or a bare provider UUID for
  /// finished sessions).
  Future<SessionModelConfig> fetchWorkspaceModelConfig() async {
    final cached = _workspaceModelConfigCache;
    if (cached != null) return cached;
    final service = _bridge?.sessionService;
    if (service == null) throw StateError('未连接');
    final result = await service.readWorkspaceState();
    final settings = result['settings'];
    zlog(
      '[zremote] readWorkspaceState settings keys: '
      '${settings is Map ? settings.keys.toList() : null} '
      'mode=${settings is Map ? settings['mode'] : null}',
    );
    final config = SessionModelConfig.fromSettings(
      settings is Map<String, Object?> ? settings : null,
    );
    if (config.availableModels.isNotEmpty) {
      _workspaceModelConfigCache = config;
    }
    return config;
  }

  SessionModelConfig? _workspaceModelConfigCache;

  // ---------- Workspace prep (slash commands) & skills ----------

  WorkspacePrep? _workspacePrep;
  List<SkillEntry>? _skills;

  /// `prepareWorkspace`: config options + slash commands (cached for the
  /// bridge lifetime). Null when no bridge or the call failed.
  Future<WorkspacePrep?> fetchWorkspacePrep({bool refresh = false}) async {
    final cached = _workspacePrep;
    if (cached != null && !refresh) return cached;
    final bridge = _bridge;
    final service = bridge?.taskService;
    if (bridge == null || service == null) return null;
    try {
      final prep = WorkspacePrep.fromJson(await service.prepareWorkspace());
      _workspacePrep = prep;
      final opts = [
        for (final o in prep.configOptions)
          '${o.id}=${o.currentValue}'
              '(${o.options.length} opts)',
      ].join('; ');
      zlog(
        '[zremote] prepareWorkspace: ${prep.configOptions.length} '
        'config options [$opts], '
        '${prep.slashCommands.length} slash commands',
      );
      return prep;
    } catch (e) {
      zlog('[zremote] prepareWorkspace failed: $e');
      return null;
    }
  }

  /// Enabled skills (`skills.list`, cached for the bridge lifetime).
  Future<List<SkillEntry>> fetchSkills({bool refresh = false}) async {
    final cached = _skills;
    if (cached != null && !refresh) return cached;
    final bridge = _bridge;
    final rpc = bridge?.channel('skills');
    final target = bridge?.workspaceTarget;
    if (bridge == null || rpc == null || target == null) return const [];
    try {
      final skills = await SkillsService(rpc, target).list();
      _skills = skills;
      zlog('[zremote] skills.list: ${skills.length} skills');
      return skills;
    } catch (e) {
      zlog('[zremote] skills.list failed: $e');
      return const [];
    }
  }

  /// The model-provider CRUD service (null while not connected).
  ModelProviderService? get modelProviderService {
    final rpc = _bridge?.channel('model-provider');
    return rpc == null ? null : ModelProviderService(rpc);
  }

  /// The current selection of one open session (readSession settings), to be
  /// shown as the highlighted values inside the workspace-wide picker.
  SessionModelConfig get sessionModelConfig =>
      _conversation?.state?.modelConfig ?? const SessionModelConfig();

  /// Builds the picker config for the open conversation: the workspace's full
  /// model list with the session's current provider/model/thought preselected.
  /// Falls back to the session-only config when the workspace registry is
  /// unavailable (offline).
  Future<SessionModelConfig> conversationPickerConfig() async {
    final current = sessionModelConfig;
    try {
      final ws = await fetchWorkspaceModelConfig();
      if (ws.availableModels.isNotEmpty) {
        return SessionModelConfig(
          provider: current.provider,
          model: current.model,
          thoughtLevel: current.thoughtLevel,
          availableModels: ws.availableModels,
          availableThoughtLevels: ws.availableThoughtLevels,
        );
      }
    } catch (_) {
      // Offline — fall through to the session-only config.
    }
    return current;
  }

  /// Creates a session and returns the new sessionId when the command result
  /// carries one (null when the host's acceptance frame omits it — the new
  /// session still shows up in the list on the next workspace-list refresh).
  Future<String?> createSession(
    String firstInput, {
    String? provider,
    String? model,
    String? thoughtLevel,
    String? mode,
    String? followupMode,
  }) async {
    final workspace = _bridge?.activeWorkspace;
    if (workspace == null) return null;
    final result = await _sendCommand('createSession', {
      'workspaceId': workspace.workspaceKey,
      'firstInput': {'text': firstInput},
      // The desktop accepts the session's initial model/thought level as
      // `config: {provider, model, thought}` (probe-verified schema), plus
      // collaboration/followup mode. Each field is optional, so a partial
      // config (e.g. thought level only) is fine.
      if (provider != null ||
          model != null ||
          thoughtLevel != null ||
          mode != null ||
          followupMode != null)
        'config': {
          'provider': ?provider,
          'model': ?model,
          'thought': ?thoughtLevel,
          'mode': ?mode,
          'followupMode': ?followupMode,
        },
    });
    // The RPC returning OK only means the host accepted the frame — the
    // command result carries status/result.type (e.g. accepted+createSession
    // with the new sessionId, or a fault). Log it so silent drops are visible.
    debugPrint('[zremote] createSession result: $result');
    return extractSessionIdFromResult(result);
  }

  Future<void> renameSession(String sessionId, String title) async {
    final service = _bridge?.taskService;
    if (service == null) throw StateError('未连接');
    await service.renameTask(sessionId, title);
    await refreshSessions();
  }

  Future<void> archiveSession(String sessionId) async {
    final service = _bridge?.taskService;
    if (service == null) throw StateError('未连接');
    await service.archiveTask(sessionId);
    // Optimistic removal — the desktop keeps archived tasks in the payload
    // (flagged archived:true); the refresh below reconciles the list.
    _workspaces.removeWhere((w) => w.taskId == sessionId);
    notifyListeners();
    await refreshSessions();
  }

  /// Archives several sessions at once. Returns the number that failed
  /// (0 = all archived). Removes the succeeded ones optimistically.
  Future<int> archiveSessions(List<String> sessionIds) async {
    final service = _bridge?.taskService;
    if (service == null) throw StateError('未连接');
    final failed = <String>[];
    for (final id in sessionIds) {
      try {
        await service.archiveTask(id);
        _workspaces.removeWhere((w) => w.taskId == id);
      } catch (_) {
        failed.add(id);
      }
    }
    notifyListeners();
    await refreshSessions();
    return failed.length;
  }

  /// Deletes a whole project: every task under one workspaceKey, archived
  /// ones included (they still ride the workspace-list payload). The zcode-task
  /// RPCs travel on a workspace bridge, so if the deleted project is not the
  /// active workspace the bridge is switched to it first. Returns the number
  /// of tasks that failed to delete (0 = all deleted).
  Future<int> deleteProject(String workspaceKey) async {
    final bridge = _bridge;
    if (bridge == null) throw StateError('未连接');
    if (_phase != BridgePhase.ready ||
        bridge.activeWorkspace?.workspaceKey != workspaceKey) {
      final representative = _workspaces.firstWhere(
        (w) => w.workspaceKey == workspaceKey,
        orElse: () => throw StateError('项目不存在'),
      );
      await bridge.selectWorkspace(representative);
    }
    final service = bridge.taskService;
    if (service == null) throw StateError('未连接');
    final targets = _workspaces
        .where((w) => w.workspaceKey == workspaceKey && w.taskId != null)
        .map((w) => w.taskId!)
        .toList();
    var failed = 0;
    for (final id in targets) {
      try {
        await service.deleteTask(id);
        _workspaces.removeWhere((w) => w.taskId == id);
      } catch (_) {
        failed++;
      }
    }
    notifyListeners();
    await refreshSessions();
    return failed;
  }

  /// Re-pulls the workspace/task list so the sessions list reflects remote
  /// changes (rename, archive). Timeouts are swallowed — the workspaces stream
  /// still fires when the response eventually lands.
  Future<void> refreshSessions() async {
    try {
      await _bridge?.refreshWorkspaceList().timeout(
        const Duration(seconds: 10),
      );
    } catch (_) {
      notifyListeners();
    }
  }

  // ---------- Per-workspace model preferences ----------

  /// The remembered provider/model/thought selection for new sessions in this
  /// workspace (null or partial values fall back to the workspace defaults).
  Future<WorkspaceModelPrefs?> loadWorkspaceModelPrefs(String workspaceKey) =>
      db.getWorkspaceModelPrefs(workspaceKey);

  Future<void> saveWorkspaceModelPrefs(
    String workspaceKey, {
    String? provider,
    String? model,
    String? thoughtLevel,
  }) => db.saveWorkspaceModelPrefs(
    WorkspaceModelPrefs(
      workspaceKey: workspaceKey,
      provider: provider,
      model: model,
      thoughtLevel: thoughtLevel,
    ),
  );

  Future<void> clearWorkspaceModelPrefs(String workspaceKey) =>
      db.clearWorkspaceModelPrefs(workspaceKey);

  Future<void> deleteSession(String sessionId) async {
    await _sendCommand('deleteSession', const {}, sessionId: sessionId);
  }

  // ---------- Notifications ----------

  NotificationHook? onNotificationEvent;
  void Function(BridgeException e)? bridgeNotificationHook;

  /// Set by the notification tap handler: `workspaceKey|sessionId` to open
  /// once a connection is up. Consumed by [consumePendingDeepLink].
  String? pendingDeepLink;

  /// Notification taps while the app is running (any page): the raw link is
  /// both stored for the next connect and broadcast so the UI layer can
  /// navigate immediately when already connected.
  final _deepLinkController = StreamController<String>.broadcast();
  Stream<String> get deepLinkStream => _deepLinkController.stream;

  void requestDeepLink(String raw) {
    pendingDeepLink = raw;
    if (!_deepLinkController.isClosed) _deepLinkController.add(raw);
  }

  /// Drops a pending deep link without acting on it (e.g. the connection
  /// attempt that was supposed to serve it failed — the link must not fire
  /// on some later unrelated connect).
  void discardPendingDeepLink() => pendingDeepLink = null;

  final Set<String> _notifiedInteractions = {};
  String? _lastNotifiedPhase;

  /// If a notification tap asked us to open a session, returns its
  /// `(workspaceKey, sessionId)` and clears the pending link.
  (String, String)? consumePendingDeepLink() {
    final link = pendingDeepLink;
    if (link == null) return null;
    pendingDeepLink = null;
    final parts = link.split('|');
    if (parts.length != 2 || parts[0].isEmpty || parts[1].isEmpty) return null;
    return (parts[0], parts[1]);
  }

  Timer? _stallTimer;
  DateTime? _lastActivityAt;
  bool _stallNotified = false;
  static const _stallThreshold = Duration(minutes: 10);

  void _startStallMonitor() {
    _stopStallMonitor();
    _lastActivityAt = DateTime.now();
    _stallNotified = false;
    _stallTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      final hook = onNotificationEvent;
      final last = _lastActivityAt;
      if (hook == null || last == null) return;
      final state = _conversation?.state;
      if (state != null &&
          state.phase == 'running' &&
          DateTime.now().difference(last) > _stallThreshold &&
          !_stallNotified) {
        _stallNotified = true;
        hook({'type': 'stall', 'sessionId': state.sessionId});
      }
    });
  }

  void _stopStallMonitor() {
    _stallTimer?.cancel();
    _stallTimer = null;
  }

  void _handleConversationState(ConversationState state) {
    _lastActivityAt = DateTime.now();
    _cacheState(state);
    final hook = onNotificationEvent;
    if (hook == null) return;
    // Notify only for interactions we have not notified about yet — the
    // state stream fires on every delta frame and would otherwise spam.
    for (final interaction in state.pendingInteractions) {
      if (_notifiedInteractions.contains(interaction.interactionId)) continue;
      _notifiedInteractions.add(interaction.interactionId);
      hook({
        'type': 'pending-interaction',
        'sessionId': state.sessionId,
        'workspaceKey': _bridge?.activeWorkspace?.workspaceKey,
        'interactionId': interaction.interactionId,
        'prompt': interaction.prompt,
        'toolName': interaction.toolName,
      });
    }
    // Notify on phase *transitions* to terminal states, once each.
    final phase = state.phase;
    if (SessionPhase.isTerminal(phase) && _lastNotifiedPhase != phase) {
      _lastNotifiedPhase = phase;
      hook({
        'type': 'phase',
        'sessionId': state.sessionId,
        'workspaceKey': _bridge?.activeWorkspace?.workspaceKey,
        'phase': phase,
      });
    }
  }

  // ---------- Offline cache (ADR-0002: text only) ----------

  final Set<int> _cachedRowIds = {};

  /// Writes the current conversation state into the text cache. Only new or
  /// changed rows are written; the session row is refreshed on every update.
  void _cacheState(ConversationState state) {
    final workspace = _bridge?.activeWorkspace;
    if (workspace == null) return;
    final title = state.meta?['title']?.toString() ?? '';
    var preview = '';
    for (final row in state.orderedRows.reversed) {
      if (row is AssistantTextRow && row.text.trim().isNotEmpty) {
        preview = row.text.trim();
        break;
      }
    }
    if (preview.length > 200) preview = '${preview.substring(0, 200)}…';
    db.cacheSession(
      state.sessionId,
      workspace.workspaceKey,
      title,
      DateTime.now().millisecondsSinceEpoch,
      preview,
    );
    for (final row in state.orderedRows) {
      if (_cachedRowIds.contains(row.rowId)) continue;
      _cachedRowIds.add(row.rowId);
      db.cacheRow(state.sessionId, row.rowId, jsonEncode(row.toCacheMap()));
    }
  }

  /// Cached sessions for a workspace, for the offline session list.
  Future<List<CachedSession>> offlineSessions(String workspaceKey) =>
      db.cachedSessions(workspaceKey);

  // ---------- Lifecycle ----------

  Future<void> disconnect() async {
    await _conversation?.dispose();
    _conversation = null;
    await _phaseSub?.cancel();
    await _workspacesSub?.cancel();
    await _errorsSub?.cancel();
    await _relayFailureSub?.cancel();
    _phaseSub = null;
    _workspacesSub = null;
    _errorsSub = null;
    _relayFailureSub = null;
    await _bridge?.dispose();
    await _relay?.dispose();
    _bridge = null;
    _relay = null;
    _workspaces = [];
    _workspaceModelConfigCache = null;
    activePairing = null;
    lastError = null;
    _phase = BridgePhase.idle;
    notifyListeners();
  }

  static String _generateClientId() => ids.newClientId();

  @override
  void dispose() {
    unawaited(_deepLinkController.close());
    super.dispose();
  }
}

/// Defensive sessionId extraction from a createSession command result: host
/// builds have returned it at `result.sessionId`, `result.result.sessionId`,
/// or `result.taskId`.
String? extractSessionIdFromResult(Map<String, Object?> result) {
  String? pick(Map<String, Object?> m, String key) {
    final v = m[key];
    return v is String && v.isNotEmpty ? v : null;
  }

  final direct = pick(result, 'sessionId') ?? pick(result, 'taskId');
  if (direct != null) return direct;
  final nested = result['result'];
  if (nested is Map<String, Object?>) {
    return pick(nested, 'sessionId') ?? pick(nested, 'taskId');
  }
  return null;
}
