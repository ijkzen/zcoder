/// Central app state: pairings, the active relay/bridge connection, the
/// workspace's session list, and the open conversation. UI listens to this
/// ChangeNotifier and calls its methods.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ChangeNotifier;

import 'protocol/core/random_ids.dart' as ids;
import 'bridge/bridge_manager.dart';
import 'protocol/relay/relay_client.dart';
import 'protocol/relay/relay_frame.dart';
import 'services/launcher_badge.dart';
import 'services/launcher_badge_ledger.dart';
import 'services/notifications.dart';
import 'protocol/services/services.dart';
import 'protocol/zlog.dart';
import 'session/conversation_controller.dart';
import 'session/session_status_monitor.dart';
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

  /// The foreground service runs only while a live pairing exists (it keeps
  /// the relay WebSocket alive in the background). Set on the first
  /// successful pairing; cleared on disconnect or terminal failure.
  bool _foregroundTaskStarted = false;

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
  StreamSubscription<int>? _recoveredSub;

  /// True while the connection is down and the app is still trying to
  /// reconnect: the relay dropped (phase == `reconnecting`) or the bridge is
  /// degraded with recovery in flight (`BridgeManager.isDegraded`). Cleared
  /// once the connection is healthy again — drives the in-app reconnect
  /// banner on the project/session/conversation pages.
  bool get isReconnecting =>
      _phase == BridgePhase.reconnecting || (_bridge?.isDegraded ?? false);

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
      zlog('[zremote] bridge phase -> ${p.name}');
      _phase = p;
      // The foreground service exists to keep a live connection alive in the
      // background, so it starts only once a pairing actually succeeds — a
      // failed connect (desktop offline, relay unreachable, …) never reaches
      // `pairing` and therefore never raises the persistent notification. A
      // later relay drop (`reconnecting`) keeps it running so the background
      // retry loop can bring the link back; a terminal `failed` stops it.
      if (p == BridgePhase.pairing) {
        unawaited(_startForegroundTask());
      } else if (p == BridgePhase.failed) {
        unawaited(_stopForegroundTask());
      }
      if (p == BridgePhase.ready) {
        if (_bridge?.isDegraded ?? false) {
          zlog(
            '[zremote] phase=ready 但 bridge 仍降级',
          );
        }
        _startListStatusMonitor();
      } else {
        _stopListStatusMonitor();
      }
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
      zlog(
        '[zremote] relay failure: ${f.reason.name} — ${f.message}',
      );
      bridgeNotificationHook?.call(BridgeException(f.reason.name, f.message));
    });
    // Recovery completion clears the degraded flag without any phase change,
    // so re-notify here — otherwise the reconnect banner would stick around
    // after the connection is healthy again.
    _recoveredSub = bridge.recoveredStream.listen((_) {
      zlog('[zremote] bridge recovered — 连接已恢复');
      NotificationService.instance.cancelReconnectNotification();
      notifyListeners();
    });

    await bridge.start();
  }

  /// Starts the foreground service the first time a pairing succeeds. Both
  /// start/stop are guarded by [_foregroundTaskStarted] so reconnect/recovery
  /// cycles do not flap the service.
  Future<void> _startForegroundTask() async {
    if (_foregroundTaskStarted) return;
    _foregroundTaskStarted = true;
    await NotificationService.instance.startForegroundTask();
  }

  Future<void> _stopForegroundTask() async {
    if (!_foregroundTaskStarted) return;
    _foregroundTaskStarted = false;
    await NotificationService.instance.stopForegroundTask();
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
      zlog('[zremote] markTaskRead failed: $e');
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
      // Opening the session clears its unread badge (best-effort) and its
      // launcher-icon badge count.
      unawaited(markTaskRead(sessionId));
      unawaited(_clearBadgeSession(sessionId));
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

  /// Commands that require `baseRevision` (CAS — mirrors the reference
  /// client's `_casCommands`). The runtime rejects a stale base for these;
  /// non-CAS commands (sendText/stop/…) carry no base at all.
  static const _casCommands = {
    'applyFileRewind',
    'forkAssistant',
    'editUserQuery',
    'setAssistantFeedback',
    'sendQueuedNow',
    'editQueueItem',
    'reorderQueueItem',
    'deleteQueueItem',
    'setAutoDrain',
    'switchModelConfig',
    'switchCollaborationMode',
    'setFollowupMode',
    'pauseGoal',
    'resumeGoal',
  };

  /// Row-target commands that also require `baseLogEpoch`.
  static const _rowTargetCommands = {
    'applyFileRewind',
    'forkAssistant',
    'editUserQuery',
    'setAssistantFeedback',
  };

  /// Highest revision seen from command acks (`revisionAtDecision`) — acks
  /// land before the follow-up `state.updated` frame, and the next CAS
  /// command must not go stale (mirrors the reference client).
  final _ackedRevisions = <String, int>{};

  /// Sends a conversation command against the open conversation, attaching
  /// its revision/logEpoch as the base for optimistic concurrency (CAS
  /// commands only). Tracks the server's `revisionAtDecision` from each ack
  /// and retries once on `stale` with the reported revision.
  Future<Map<String, Object?>> _sendCommand(
    String type,
    Map<String, Object?> payload, {
    String? sessionId,
  }) async {
    final bridge = _bridge;
    if (bridge == null) throw StateError('未连接');
    final state = _conversation?.state;
    final sid = sessionId ?? state?.sessionId;
    final snapshotRev = state?.revision ?? 0;
    final ackedRev = sid == null ? 0 : (_ackedRevisions[sid] ?? 0);
    final baseRevision = _casCommands.contains(type)
        ? (snapshotRev > ackedRev ? snapshotRev : ackedRev)
        : 0;
    final hasLogEpoch = (state?.logEpoch.isNotEmpty ?? false);
    final baseLogEpoch = (_rowTargetCommands.contains(type) && hasLogEpoch)
        ? state!.logEpoch
        : null;

    Future<Map<String, Object?>> send(int revision) => bridge.sendCommand(
      sessionId: sid,
      baseRevision: revision > 0 ? revision : null,
      baseLogEpoch: baseLogEpoch,
      type: type,
      payload: payload,
    );

    var result = await send(baseRevision);
    final ackRev = result['revisionAtDecision'];
    if (sid != null && ackRev is num) {
      final serverRev = ackRev.toInt();
      final status = result['status'];
      // revisionAtDecision is the base at decision time; an accepted
      // command bumps the revision by one, so the next CAS base is +1.
      final floor =
          (status == 'accepted' || status == 'noop' || status == 'duplicate')
          ? serverRev + 1
          : serverRev;
      if (floor > (_ackedRevisions[sid] ?? 0)) {
        _ackedRevisions[sid] = floor;
      }
    }
    if (sid != null && result['status'] == 'stale' && ackRev is num) {
      // Retry once at the server's current revision (fresh commandId is
      // generated inside bridge.sendCommand).
      result = await send(ackRev.toInt());
    }
    return result;
  }

  Future<Map<String, Object?>> sendText(
    String text, {
    String? sessionId,
    List<Map<String, Object?>>? attachments,
    String? heldQueueDisposition,
    List<String>? expectedHeldQueueItemIds,
  }) => _sendCommand('sendText', {
    'text': text,
    if (attachments != null && attachments.isNotEmpty)
      'attachments': attachments,
    'heldQueueDisposition': ?heldQueueDisposition,
    if (expectedHeldQueueItemIds != null && expectedHeldQueueItemIds.isNotEmpty)
      'expectedHeldQueueItemIds': expectedHeldQueueItemIds,
  }, sessionId: sessionId);

  Future<Map<String, Object?>> sendGoalCommand(
    String text, {
    String? heldQueueDisposition,
    List<String>? expectedHeldQueueItemIds,
  }) => _sendCommand('sendGoalCommand', {
    'text': text,
    'heldQueueDisposition': ?heldQueueDisposition,
    if (expectedHeldQueueItemIds != null && expectedHeldQueueItemIds.isNotEmpty)
      'expectedHeldQueueItemIds': expectedHeldQueueItemIds,
  });

  Future<void> stop() async {
    await _sendCommand('stop', const {});
  }

  /// Compacts the open conversation (summarizes the history so far).
  Future<Map<String, Object?>> compact() => _sendCommand('compact', const {});

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

  /// Sends one queued message immediately, jumping the queue (doc 08 §2.4).
  Future<Map<String, Object?>> sendQueuedNow(String queueItemId) =>
      _sendCommand('sendQueuedNow', {'queueItemId': queueItemId});

  /// Edits the text of one queued message.
  Future<Map<String, Object?>> editQueueItem(
    String queueItemId,
    String newText,
  ) => _sendCommand('editQueueItem', {
    'queueItemId': queueItemId,
    'newText': newText,
  });

  /// Deletes one queued message.
  Future<Map<String, Object?>> deleteQueueItem(String queueItemId) =>
      _sendCommand('deleteQueueItem', {'queueItemId': queueItemId});

  /// Moves one queued message before another (`beforeQueueItemId` empty moves
  /// it to the front).
  Future<Map<String, Object?>> reorderQueueItem(
    String queueItemId,
    String beforeQueueItemId,
  ) => _sendCommand('reorderQueueItem', {
    'queueItemId': queueItemId,
    'beforeQueueItemId': beforeQueueItemId,
  });

  /// Auto-drain switch: when off, messages sent while the agent runs hold in
  /// the queue instead of executing.
  Future<Map<String, Object?>> setAutoDrain(bool autoDrain) =>
      _sendCommand('setAutoDrain', {'autoDrain': autoDrain});

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

  /// Fetches the open session's plan history (TodoWrite tool-call rows via
  /// `conversationPlansV4`) for the 计划 view.
  Future<Map<String, Object?>> fetchPlans() async {
    final topic = _bridge?.topicSession;
    final sessionId = _conversation?.state?.sessionId;
    if (topic == null || sessionId == null) throw StateError('会话未打开');
    return topic.conversationPlans(sessionId);
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
      'answer': {'optionId': ?optionId, 'action': ?action, 'content': ?content},
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
    // The host's setModel resolves only the model ref — a requested thought
    // level goes through the dedicated RPC, which resolves against the
    // runtime model setModel just cached.
    if (thoughtLevel != null) {
      await service.setThoughtLevel(sessionId, thoughtLevel);
    }
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
  ///
  /// [refresh] bypasses the cache: there is no change event for the workspace
  /// registry, so a provider deleted on the desktop (or the phone's provider
  /// page) keeps showing in pickers until the registry is re-read.
  Future<SessionModelConfig> fetchWorkspaceModelConfig({
    bool refresh = false,
  }) async {
    final cached = _workspaceModelConfigCache;
    if (cached != null && !refresh) return cached;
    final service = _bridge?.sessionService;
    if (service == null) throw StateError('未连接');
    final result = await service.readWorkspaceState();
    final settings = result['settings'];
    zlog(
      '[zremote] readWorkspaceState settings keys: '
      '${settings is Map ? settings.keys.toList() : null} '
      'mode=${settings is Map ? settings['mode'] : null}',
    );
    var config = SessionModelConfig.fromSettings(
      settings is Map<String, Object?> ? settings : null,
    );
    config = await _pruneDeletedProviders(config);
    zlog(
      '[zremote] workspace registry source (refresh=$refresh): '
      '${config.availableModels.length} models / '
      '${config.availableModels.map((m) => m.provider).toSet().length} providers '
      '[${config.availableModels.map((m) => m.provider).toSet().join(', ')}]; '
      'current=${config.provider ?? '-'}/${config.model ?? '-'} '
      'thought=${config.thoughtLevel ?? '-'}',
    );
    if (config.availableModels.isNotEmpty) {
      _workspaceModelConfigCache = config;
    }
    return config;
  }

  SessionModelConfig? _workspaceModelConfigCache;

  /// Drops the cached workspace registry after phone-side provider CRUD so
  /// the next fetch sees the desktop's current registry.
  void invalidateWorkspaceModelConfig() => _workspaceModelConfigCache = null;

  /// The desktop runtime's `settings.model.available` is not rebuilt when a
  /// provider is deleted (only on workspace bootstrap), so it can list
  /// providers that no longer exist in the registry — deleted providers then
  /// linger in every model picker. Cross-check against the live registry
  /// (`getAllCached`, which the host refreshes on every provider change) and
  /// drop models whose provider is gone. Offline, or when the registry is
  /// unavailable, the list passes through unchanged.
  Future<SessionModelConfig> _pruneDeletedProviders(
    SessionModelConfig config,
  ) async {
    if (config.availableModels.isEmpty) return config;
    final service = modelProviderService;
    if (service == null) return config;
    try {
      final providers = await service.getAllCached();
      final liveIds = providers
          .map((p) => p['id']?.toString())
          .whereType<String>()
          .toSet();
      if (liveIds.isEmpty) return config;
      final kept = config.availableModels
          .where((m) => liveIds.contains(m.provider))
          .toList();
      if (kept.length == config.availableModels.length) return config;
      zlog(
        '[zremote] pruned ${config.availableModels.length - kept.length} '
        'models from deleted providers '
        '[${config.availableModels.map((m) => m.provider).toSet().difference(liveIds).join(', ')}]',
      );
      return SessionModelConfig(
        provider: config.provider,
        model: config.model,
        thoughtLevel: config.thoughtLevel,
        mode: config.mode,
        availableModels: kept,
        availableThoughtLevels: config.availableThoughtLevels,
      );
    } catch (e) {
      zlog('[zremote] provider prune skipped: $e');
      return config;
    }
  }

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
  /// Re-reads the registry on every open so providers deleted since the last
  /// fetch don't linger in the sheet.
  /// Falls back to the session-only config when the workspace registry is
  /// unavailable (offline).
  Future<SessionModelConfig> conversationPickerConfig() async {
    final current = sessionModelConfig;
    try {
      final ws = await fetchWorkspaceModelConfig(refresh: true);
      zlog(
        '[zremote] picker config: '
        '${ws.availableModels.isNotEmpty ? 'workspace' : 'SESSION-FALLBACK'} '
        '${ws.availableModels.length} models '
        '[${ws.availableModels.map((m) => m.provider).toSet().join(', ')}] '
        'session=${current.provider ?? '-'}/${current.model ?? '-'}',
      );
      if (ws.availableModels.isNotEmpty) {
        return SessionModelConfig(
          provider: current.provider,
          model: current.model,
          thoughtLevel: current.thoughtLevel,
          mode: current.mode,
          availableModels: ws.availableModels,
          availableThoughtLevels: ws.availableThoughtLevels,
        );
      }
    } catch (e) {
      // Offline — fall through to the session-only config.
      zlog(
        '[zremote] picker config: SESSION-FALLBACK (workspace fetch failed: $e)',
      );
    }
    return current;
  }

  /// Creates a session and returns the new sessionId when the command result
  /// carries one (null when the host's acceptance frame omits it — the new
  /// session still shows up in the list on the next workspace-list refresh).
  ///
  /// A null [firstInput] creates the session WITHOUT its first message — the
  /// caller sends it later via sendText. Used by the attachment flow: uploads
  /// need the sessionId first, and the attachments then ride the first
  /// sendText so text + files land as ONE message (protocol: `firstInput?
  /// {text, attachments?}` only takes already-uploaded descriptors).
  Future<String?> createSession(
    String? firstInput, {
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
      if (firstInput != null) 'firstInput': {'text': firstInput},
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
    zlog('[zremote] createSession result: $result');
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
  Future<WorkspaceModelPrefs?> loadWorkspaceModelPrefs(
    String workspaceKey,
  ) async {
    final prefs = await db.getWorkspaceModelPrefs(workspaceKey);
    zlog(
      '[zremote] prefs load key=$workspaceKey → '
      '${prefs == null ? 'null' : '${prefs.provider}/${prefs.model}/${prefs.thoughtLevel}'}',
    );
    return prefs;
  }

  Future<void> saveWorkspaceModelPrefs(
    String workspaceKey, {
    String? provider,
    String? model,
    String? thoughtLevel,
  }) async {
    zlog(
      '[zremote] prefs save key=$workspaceKey → $provider/$model/$thoughtLevel',
    );
    await db.saveWorkspaceModelPrefs(
      WorkspaceModelPrefs(
        workspaceKey: workspaceKey,
        provider: provider,
        model: model,
        thoughtLevel: thoughtLevel,
      ),
    );
  }

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

  /// Whether the app is interactively in the foreground (resumed). Kept in
  /// sync with `WidgetsBinding`'s lifecycle by the root app widget; used to
  /// skip task-completion notifications for the session the user is looking
  /// at right now.
  bool isForeground = true;

  /// True when a task-completion event for [sessionId] should be suppressed
  /// because the user is interactively viewing that session's detail page —
  /// firing a notification for it would just double what is already on screen.
  static bool suppressCompletionFor({
    required bool foreground,
    required String? openSessionId,
    required String sessionId,
  }) =>
      foreground && openSessionId == sessionId;

  /// Convenience wrapper with the app's own lifecycle + open-session state.
  bool _completionIsVisible(String sessionId) => suppressCompletionFor(
    foreground: isForeground,
    openSessionId: _conversation?.state?.sessionId,
    sessionId: sessionId,
  );

  /// Per-session terminal bucket already notified (`taskId → completed|error`).
  /// Shared by the detail-phase notifier and the session-list monitor so the
  /// two independent polls never double-notify.
  final Map<String, String> _notifiedTerminal = {};

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

  /// Best-effort session title for notification bodies: the workspace-list
  /// `title` (wire `title` → [Workspace.taskTitle]) for any workspace's task,
  /// falling back to the live snapshot's `meta.title`. Unknown → ''.
  String _sessionTitle(String taskId) {
    for (final w in _workspaces) {
      if (w.taskId == taskId) return w.taskTitle ?? '';
    }
    return _conversation?.state?.meta?['title']?.toString() ?? '';
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
        hook({
          'type': 'stall',
          'sessionId': state.sessionId,
          'title': _sessionTitle(state.sessionId),
          'workspaceKey': _bridge?.activeWorkspace?.workspaceKey,
        });
      }
    });
  }

  void _stopStallMonitor() {
    _stallTimer?.cancel();
    _stallTimer = null;
  }

  // ---------- Session-list completion monitor ----------

  /// Low-frequency poll of the workspace session list so completion
  /// notifications keep flowing while the user is not inside the session
  /// (the detail controller's 2s poll only lives while its page is open).
  /// Runs only while the bridge is `ready`; terminal crossings are detected
  /// by [SessionStatusMonitor] against the same per-session notified map as
  /// the detail path, so the two polls never double-notify.
  Timer? _listStatusTimer;
  static const _listStatusInterval = Duration(seconds: 20);
  late final SessionStatusMonitor _sessionMonitor =
      SessionStatusMonitor(_notifiedTerminal);

  /// One backfill of the launcher badge per connect: sessions that crossed
  /// into a terminal state while this app was not connected (see
  /// [_backfillLauncherBadge]).
  bool _badgeBackfilled = false;

  void _startListStatusMonitor() {
    _stopListStatusMonitor();
    _badgeBackfilled = false;
    unawaited(_pollListStatus()); // baseline immediately, then every tick
    _listStatusTimer = Timer.periodic(_listStatusInterval, (_) {
      unawaited(_pollListStatus());
    });
  }

  void _stopListStatusMonitor() {
    _listStatusTimer?.cancel();
    _listStatusTimer = null;
  }

  Future<void> _pollListStatus() async {
    final bridge = _bridge;
    final hook = onNotificationEvent;
    if (bridge == null || hook == null) return;
    try {
      await bridge.refreshWorkspaceList().timeout(
        const Duration(seconds: 10),
      );
    } catch (_) {
      return; // transient — keep the snapshot and retry next tick
    }
    _emitListStatusTransitions();
    // First successful list after (re)connect: fold in anything that already
    // finished while this app was dead/offline, once per connection.
    if (!_badgeBackfilled) {
      _badgeBackfilled = true;
      unawaited(_backfillLauncherBadge());
    }
  }

  void _emitListStatusTransitions() {
    final hook = onNotificationEvent;
    if (hook == null || _bridge == null) return;
    // The workspace-list payload carries every task of every workspace (each
    // task names its workspace), so the monitor is not tied to the active
    // workspace — a task finishing in another project still notifies. The
    // payload's workspaceKey is the task's own, so tapping the notification
    // resolves to the right project.
    final fresh = _workspaces.where((w) => w.taskId != null && !w.archived);
    for (final (:taskId, :workspaceKey, :status) in _sessionMonitor.detect(fresh)) {
      // The user is watching that session's detail page — no notification
      // needed (the shared notified map already marks it, so nothing fires
      // later either); the badge likewise stays untouched because it is
      // already on screen.
      if (_completionIsVisible(taskId)) continue;
      unawaited(_badgeSession(taskId));
      hook({
        'type': 'phase',
        'sessionId': taskId,
        'title': _sessionTitle(taskId),
        'workspaceKey': workspaceKey,
        'phase': status,
      });
    }
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
    // Notify on transitions into a terminal state, once per session. The
    // shared per-session map also dedups against the session-list monitor,
    // which polls independently while the user is not in the detail page.
    final phase = state.phase;
    final terminal = normalizeTerminalStatus(phase);
    if (terminal != null &&
        _notifiedTerminal[state.sessionId] != terminal) {
      _notifiedTerminal[state.sessionId] = terminal;
      // User is on this session's detail page in the foreground — the state
      // change is already visible, so skip the notification (and the badge).
      if (_completionIsVisible(state.sessionId)) return;
      unawaited(_badgeSession(state.sessionId));
      hook({
        'type': 'phase',
        'sessionId': state.sessionId,
        'title': _sessionTitle(state.sessionId),
        'workspaceKey': _bridge?.activeWorkspace?.workspaceKey,
        'phase': phase,
      });
    }
  }

  // ---------- Launcher badge (unviewed terminal-state sessions) ----------

  /// Counted session keys (`deviceSid|taskId`), mirrored into the
  /// `launcher_badge` table so the count survives process death.
  final LauncherBadgeLedger _badges = LauncherBadgeLedger();
  bool _badgeLoaded = false;

  /// One session in the badge ledger, disambiguated across pairings.
  static String _badgeKey(String deviceSid, String taskId) =>
      '$deviceSid|$taskId';

  /// Loads the persisted counted-session set and applies the badge. Once per
  /// controller lifetime.
  Future<void> loadLauncherBadge() async {
    if (_badgeLoaded) return;
    _badgeLoaded = true;
    try {
      _badges.reset(await db.launcherBadgeIds());
    } catch (e) {
      zlog('[badge] 读取角标状态失败: $e');
    }
    await applyLauncherBadge();
  }

  /// Whether the persisted badge state has been loaded from the DB (startup).
  bool get launcherBadgeLoaded => _badgeLoaded;

  /// Pushes the current count to the launcher. Re-invoked on resume so a
  /// launcher that reset or capped the badge is brought back in sync.
  Future<void> applyLauncherBadge() =>
      LauncherBadge.instance.setCount(_badges.count);

  /// Counts a session on a terminal-state crossing — one point per session
  /// until it is opened ([openSession] → [_clearBadgeSession]). Idempotent
  /// across the list poll, the detail poll, and reconnect backfills.
  Future<void> _badgeSession(String taskId) async {
    final deviceSid = activePairing?.deviceSid;
    if (deviceSid == null) return;
    final key = _badgeKey(deviceSid, taskId);
    if (!_badges.add(key)) return;
    try {
      await db.launcherBadgeAdd(key);
    } catch (e) {
      zlog('[badge] 写入角标计数失败: $e');
    }
    await applyLauncherBadge();
  }

  /// Drops a session from the badge when it is opened (viewed).
  Future<void> _clearBadgeSession(String taskId) async {
    final deviceSid = activePairing?.deviceSid;
    if (deviceSid == null) return;
    final key = _badgeKey(deviceSid, taskId);
    if (!_badges.remove(key)) return;
    try {
      await db.launcherBadgeRemove(key);
    } catch (e) {
      zlog('[badge] 清除角标计数失败: $e');
    }
    await applyLauncherBadge();
  }

  /// Folds into the badge the sessions that crossed into a terminal state
  /// while this app was not connected (process killed / offline). The
  /// desktop's own `unreadAt` marks the change as unseen; sessions already
  /// counted are skipped.
  Future<void> _backfillLauncherBadge() async {
    await loadLauncherBadge();
    final deviceSid = activePairing?.deviceSid;
    if (deviceSid == null) return;
    var changed = false;
    for (final w in _workspaces) {
      final taskId = w.taskId;
      if (taskId == null || w.archived) continue;
      if (normalizeTerminalStatus(w.displayStatus) == null) continue;
      if (w.unreadAt == null) continue;
      final key = _badgeKey(deviceSid, taskId);
      if (!_badges.add(key)) continue;
      try {
        await db.launcherBadgeAdd(key);
      } catch (e) {
        zlog('[badge] 补计角标失败: $e');
      }
      changed = true;
    }
    if (changed) await applyLauncherBadge();
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
    zlog('[zremote] disconnect() 主动断开连接');
    NotificationService.instance.cancelReconnectNotification();
    await _stopForegroundTask();
    _stopListStatusMonitor();
    await _conversation?.dispose();
    _conversation = null;
    await _phaseSub?.cancel();
    await _workspacesSub?.cancel();
    await _errorsSub?.cancel();
    await _relayFailureSub?.cancel();
    await _recoveredSub?.cancel();
    _phaseSub = null;
    _workspacesSub = null;
    _errorsSub = null;
    _relayFailureSub = null;
    _recoveredSub = null;
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
