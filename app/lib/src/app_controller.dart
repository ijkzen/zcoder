/// Central app state: pairings, the active relay/bridge connection, the
/// workspace's session list, and the open conversation. UI listens to this
/// ChangeNotifier and calls its methods.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show ChangeNotifier, debugPrint;

import 'core/random_ids.dart' as ids;
import 'bridge/bridge_manager.dart';
import 'relay/relay_client.dart';
import 'relay/relay_types.dart';
import 'session/conversation_controller.dart';
import 'session/models.dart';
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

  /// Adds a pairing from a scanned QR URL. Returns the stored pairing.
  Future<StoredPairing> addPairingFromUrl(String url) async {
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
    return pairing;
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
    if (bridge == null) return;
    if (_phase == BridgePhase.ready &&
        bridge.activeWorkspace?.workspaceKey == workspace.workspaceKey) {
      return;
    }
    await bridge.selectWorkspace(workspace);
    notifyListeners();
  }

  // ---------- Sessions (tasks of the active workspace) ----------

  /// Sessions of the active workspace, sourced from the workspace-list
  /// `tasks` payload (the desktop's own task list — this is what the web
  /// client renders, not the sessions-index topic).
  List<Workspace> get sessions {
    final workspace = _bridge?.activeWorkspace;
    if (workspace == null) return const [];
    return _workspaces
        .where((w) =>
            w.taskId != null &&
            !w.archived &&
            w.workspaceKey == workspace.workspaceKey)
        .toList();
  }

  bool get sessionsIndexConnected => _bridge?.activeWorkspace != null;

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
    final hasSnapshotBase = (state?.revision ?? 0) > 0 &&
        (state?.logEpoch.isNotEmpty ?? false);
    return bridge.sendCommand(
      sessionId: sessionId ?? state?.sessionId,
      baseRevision: hasSnapshotBase ? state!.revision : null,
      baseLogEpoch: hasSnapshotBase ? state!.logEpoch : null,
      type: type,
      payload: payload,
    );
  }

  Future<Map<String, Object?>> sendText(String text, {String? sessionId}) =>
      _sendCommand('sendText', {'text': text}, sessionId: sessionId);

  Future<Map<String, Object?>> sendGoalCommand(String text) =>
      _sendCommand('sendGoalCommand', {'text': text});

  Future<void> stop() async {
    await _sendCommand('stop', const {});
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
        if (optionId != null) 'optionId': optionId,
        if (action != null) 'action': action,
        if (content != null) 'content': content,
      },
    });
  }

  /// Switches the open session's model (+ optional thought level) directly via
  /// the zcode-session service — no baseRevision needed.
  Future<void> switchModel(String provider, String model,
      {String? thoughtLevel}) async {
    final channel = _bridge?.sessionChannel;
    if (channel == null) throw StateError('未连接');
    final sessionId = _conversation?.state?.sessionId;
    if (sessionId == null) throw StateError('会话未打开');
    await channel.setSessionModel(sessionId,
        provider: provider, model: model, thoughtLevel: thoughtLevel);
  }

  /// Switches the open session's thought level (reasoning effort).
  Future<void> switchThoughtLevel(String thoughtLevel) async {
    final channel = _bridge?.sessionChannel;
    if (channel == null) throw StateError('未连接');
    final sessionId = _conversation?.state?.sessionId;
    if (sessionId == null) throw StateError('会话未打开');
    await channel.setSessionThoughtLevel(sessionId, thoughtLevel);
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
        if (optionId != null) 'optionId': optionId,
        if (freeText != null) 'freeText': freeText,
        if (action != null) 'action': action,
        if (content != null) 'content': content,
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
    final channel = _bridge?.sessionChannel;
    if (channel == null) throw StateError('未连接');
    final result = await channel.readWorkspaceState();
    final settings = result['settings'];
    final config = SessionModelConfig.fromSettings(
      settings is Map<String, Object?> ? settings : null,
    );
    if (config.availableModels.isNotEmpty) {
      _workspaceModelConfigCache = config;
    }
    return config;
  }

  SessionModelConfig? _workspaceModelConfigCache;

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

  Future<void> createSession(
    String firstInput, {
    String? provider,
    String? model,
    String? thoughtLevel,
  }) async {
    final workspace = _bridge?.activeWorkspace;
    if (workspace == null) return;
    final result = await _sendCommand('createSession', {
      'workspaceId': workspace.workspaceKey,
      'firstInput': {'text': firstInput},
      // The desktop accepts the session's initial model/thought level as
      // `config: {provider, model, thought}` (probe-verified schema). Each
      // field is optional, so a partial config (e.g. thought level only) is
      // fine.
      if (provider != null || model != null || thoughtLevel != null)
        'config': {
          if (provider != null) 'provider': provider,
          if (model != null) 'model': model,
          if (thoughtLevel != null) 'thought': thoughtLevel,
        },
    });
    // The RPC returning OK only means the host accepted the frame — the
    // command result carries status/result.type (e.g. accepted+createSession
    // with the new sessionId, or a fault). Log it so silent drops are visible.
    debugPrint('[zremote] createSession result: $result');
  }

  Future<void> renameSession(String sessionId, String title) async {
    final channel = _bridge?.sessionChannel;
    if (channel == null) throw StateError('未连接');
    await channel.renameTask(sessionId, title);
    await refreshSessions();
  }

  Future<void> archiveSession(String sessionId) async {
    final channel = _bridge?.sessionChannel;
    if (channel == null) throw StateError('未连接');
    await channel.archiveTask(sessionId);
    // Optimistic removal — the desktop keeps archived tasks in the payload
    // (flagged archived:true); the refresh below reconciles the list.
    _workspaces.removeWhere((w) => w.taskId == sessionId);
    notifyListeners();
    await refreshSessions();
  }

  /// Archives several sessions at once. Returns the number that failed
  /// (0 = all archived). Removes the succeeded ones optimistically.
  Future<int> archiveSessions(List<String> sessionIds) async {
    final channel = _bridge?.sessionChannel;
    if (channel == null) throw StateError('未连接');
    final failed = <String>[];
    for (final id in sessionIds) {
      try {
        await channel.archiveTask(id);
        _workspaces.removeWhere((w) => w.taskId == id);
      } catch (_) {
        failed.add(id);
      }
    }
    notifyListeners();
    await refreshSessions();
    return failed.length;
  }

  /// Re-pulls the workspace/task list so the sessions list reflects remote
  /// changes (rename, archive). Timeouts are swallowed — the workspaces stream
  /// still fires when the response eventually lands.
  Future<void> refreshSessions() async {
    try {
      await _bridge?.refreshWorkspaceList()
          .timeout(const Duration(seconds: 10));
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
  }) =>
      db.saveWorkspaceModelPrefs(WorkspaceModelPrefs(
        workspaceKey: workspaceKey,
        provider: provider,
        model: model,
        thoughtLevel: thoughtLevel,
      ));

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
        hook({
          'type': 'stall',
          'sessionId': state.sessionId,
        });
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
}
