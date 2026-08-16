/// Applies conversation snapshots and deltas to an in-memory row store, and
/// exposes the current state as a change-notifying model the UI renders from.
///
/// Live updates arrive as topic wire frames (reassembled in the protocol
/// module); a rows-range poll and a readSession poll run alongside as a
/// fallback for the fields event push does not carry to terminal connections.
library;

import '../protocol/zlog.dart';

import 'dart:async';
import 'dart:collection';


import '../bridge/bridge_manager.dart';
import '../protocol/protocol.dart';
import '../protocol/topics/topic_models.dart';

class ConversationState {
  final String sessionId;
  String logEpoch;
  int revision;
  Map<String, Object?> control;
  Map<String, Object?>? availability;
  Map<String, Object?>? inputRouting;
  Map<String, Object?>? meta;
  Map<String, Object?>? config;
  List<PendingInteraction> pendingInteractions;
  // readSession polling state (snapshot-only fields: approvals, context
  // usage and model config all come from the readSession RPC).
  List<PendingRequest> pendingRequests;
  ContextUsage contextUsage;
  SessionModelConfig modelConfig;
  Map<String, Object?>? tokenUsage;
  // readSession 的 session.status（实测取值 running | idle | error）。
  String sessionStatus;
  final SplayTreeMap<int, ConversationRow> rows; // keyed by rowId
  bool needsOlderRows = false;

  ConversationState({
    required this.sessionId,
    required this.logEpoch,
    this.revision = 0,
    Map<String, Object?>? control,
    this.availability,
    this.inputRouting,
    this.meta,
    this.config,
    List<PendingInteraction>? pendingInteractions,
    List<PendingRequest>? pendingRequests,
    ContextUsage? contextUsage,
    SessionModelConfig? modelConfig,
    this.tokenUsage,
    this.sessionStatus = '',
  })  : control = control ?? const {},
        pendingInteractions = pendingInteractions ?? const [],
        pendingRequests = pendingRequests ?? const [],
        contextUsage = contextUsage ?? const ContextUsage(),
        modelConfig = modelConfig ?? const SessionModelConfig(),
        rows = SplayTreeMap<int, ConversationRow>();

  List<ConversationRow> get orderedRows => rows.values.toList();

  /// control.canStop — but only when the snapshot actually carried it.
  /// null means "unknown": the UI falls back to the readSession poll's
  /// sessionStatus.
  bool? get canStopOrNull {
    if (control.containsKey('canStop')) return control['canStop'] as bool?;
    return null;
  }

  bool get canStop => canStopOrNull ?? false;
  String get phase => control['phase']?.toString() ?? '';
  bool get sessionEnded => control['sessionEnded'] as bool? ?? false;

  /// Whether the agent has work in flight: the event-push snapshot's
  /// control.canStop unioned with readSession's session.status.
  bool get isAgentRunning =>
      sessionStatus == 'running' || (canStopOrNull ?? false);

  /// The parts of a readSession response the poll merges outside of
  /// settings/runtime/projection: the session's own status.
  void applyReadSession(Map<String, Object?> result) {
    final session = result['session'];
    if (session is Map<String, Object?>) {
      sessionStatus = session['status']?.toString() ?? '';
    }
  }

  void applySnapshot(ConversationSnapshot snapshot) {
    logEpoch = snapshot.logEpoch;
    revision = snapshot.revision;
    control = snapshot.control;
    availability = snapshot.availability;
    inputRouting = snapshot.inputRouting;
    meta = snapshot.meta;
    config = snapshot.config;
    pendingInteractions = snapshot.pendingInteractions
        .map(PendingInteraction.fromJson)
        .toList();
    rows.clear();
    for (final row in snapshot.rows) {
      rows[row.rowId] = row;
    }
    needsOlderRows = snapshot.totalCount > snapshot.rows.length;
  }

  /// Applies one deltas operation from a deltas payload.
  void applyDelta(Map<String, Object?> op) {
    switch (op['op'] ?? op['kind']) {
      case 'row.appended':
        final row = op['row'];
        if (row is Map<String, Object?>) {
          final r = ConversationRow.fromJson(row);
          rows[r.rowId] = r;
        }
      case 'row.upserted':
        final row = op['row'];
        if (row is Map<String, Object?>) {
          final r = ConversationRow.fromJson(row);
          rows[r.rowId] = r;
        }
      case 'row.removed':
        final fromRowId = op['fromRowId'];
        if (fromRowId is int) {
          rows.removeWhere((id, _) => id >= fromRowId);
        }
      case 'row.delta':
        final rowId = op['rowId'];
        final path = op['path'];
        final append = op['append'];
        if (rowId is int && path is List && append is String) {
          final existing = rows[rowId];
          if (existing != null) {
            rows[rowId] = existing.withDelta(
              path.map((e) => e.toString()).toList(),
              append,
            );
          } else {
            // Delta for a row we don't have yet — the snapshot will fill in
            // on resync; drop for now.
          }
        }
      case 'state.updated':
        final patch = op['patch'];
        if (patch is Map<String, Object?>) {
          _applyControlPatch(patch);
        }
    }
  }

  void _applyControlPatch(Map<String, Object?> patch) {
    final merged = Map<String, Object?>.from(control);
    patch.forEach((k, v) {
      if (v is Map<String, Object?> && merged[k] is Map<String, Object?>) {
        merged[k] = {...merged[k] as Map<String, Object?>, ...v};
      } else {
        merged[k] = v;
      }
    });
    control = merged;
  }
}

/// Owns the subscription to one conversation topic, applies topic frames
/// (snapshot + deltas with gap recovery), and runs the fallback polls.
class ConversationController {
  final BridgeManager bridge;
  final String sessionId;

  ConversationController(this.bridge, this.sessionId);

  final _stateController = StreamController<ConversationState>.broadcast();
  final _connectedController = StreamController<bool>.broadcast();

  Stream<ConversationState> get stateStream => _stateController.stream;
  Stream<bool> get connectedStream => _connectedController.stream;

  ConversationState? _state;
  ConversationState? get state => _state;

  String? _subscriptionId;
  String? _topicSeqEpoch;
  int _topicSeq = 0;
  bool _hasBase = false;
  StreamSubscription<TopicFrame>? _frameSub;
  bool _disposed = false;

  Future<void> start() async {
    final channel = bridge.topicSession;
    if (channel == null) throw StateError('no session channel');

    _frameSub = channel.conversationFrames.listen(_onFrame);

    final ack = await channel.subscribe(sessionId);
    _subscriptionId = ack.subscriptionId;
    if (!_disposed) _connectedController.add(true);
    // Best-effort snapshot via resync; the reliable path is the rows poll
    // below (RPC calls work even when event push does not).
    await _resync();
    // Poll the latest rows until the session channel is disposed. The first
    // pull fetches a deep window (history); steady-state pulls only need the
    // tail — a full 200-row window is ~370 KB, too heavy for 2s polling.
    await pollLatest(limit: 200);
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      pollLatest();
      pollSessionState();
    });
    // Token usage changes only between turns; refresh it on the same cadence
    // but it is cheap (small response).
    _tokenTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      pollTokenUsage();
    });
  }

  Timer? _pollTimer;
  Timer? _tokenTimer;

  Future<void> _resync() async {
    final channel = bridge.topicSession;
    final subscriptionId = _subscriptionId;
    if (channel == null || subscriptionId == null) return;
    try {
      await channel.resyncConversation(
        subscriptionId,
        sessionId,
        logEpoch: _hasBase ? _topicSeqEpoch : null,
        seq: _topicSeq,
      );
    } catch (e) {
      zlog('[zremote] conversation resync failed: $e');
    }
  }

  void _onFrame(TopicFrame frame) {
    if (frame.topic != 'conversation/$sessionId') return;
    final snapshot = frame.snapshot;
    if (snapshot != null) {
      if (_hasBase && frame.deliveryKind == 'online' && frame.toSeq <= _topicSeq) {
        return; // stale replay
      }
      _topicSeqEpoch = snapshot['logEpoch'] is String
          ? snapshot['logEpoch'] as String
          : _topicSeqEpoch;
      _topicSeq = frame.toSeq;
      _hasBase = true;
      final state = _state ??= ConversationState(sessionId: sessionId, logEpoch: '');
      state.applySnapshot(ConversationSnapshot.fromJson(snapshot));
      _emit();
      return;
    }
    final deltas = frame.deltas;
    if (deltas == null) return;
    if (!_hasBase) {
      _resync();
      return;
    }
    if (frame.toSeq <= _topicSeq) return; // duplicate
    if (frame.fromSeq != _topicSeq) {
      // Gap — recover from the last known base.
      _resync();
      return;
    }
    final state = _state;
    if (state == null) return;
    for (final d in deltas.whereType<Map<String, Object?>>()) {
      state.applyDelta(d);
    }
    _topicSeq = frame.toSeq;
    _emit();
  }

  void _emit() {
    final state = _state;
    if (!_disposed && state != null && !_stateController.isClosed) {
      _stateController.add(state);
    }
  }

  /// Pulls the live snapshot-ish state via readSession: pending requests
  /// (approvals + AskUserQuestion), context usage, and the session's model /
  /// thought level. Runs alongside the rows poll because event push does not
  /// deliver these fields to terminal connections.
  Future<void> pollSessionState() async {
    final service = bridge.sessionService;
    if (service == null) return;
    try {
      final result = await service.readSession(sessionId, messageLimit: 1);
      final state = _state ??= ConversationState(sessionId: sessionId, logEpoch: '');
      state.applyReadSession(result);
      final settings = result['settings'];
      if (settings is Map<String, Object?>) {
        state.modelConfig = SessionModelConfig.fromSettings(settings);
      }
      final runtime = result['runtime'];
      if (runtime is Map<String, Object?>) {
        final usage = runtime['contextUsage'];
        if (usage is Map<String, Object?>) {
          state.contextUsage = ContextUsage.fromJson(usage);
        }
      }
      final projection = result['projection'];
      if (projection is Map<String, Object?>) {
        final pending = projection['pendingPermissions'];
        if (pending is List) {
          state.pendingRequests = pending
              .whereType<Map<String, Object?>>()
              .map(PendingRequest.fromJson)
              .toList();
        }
      }
      _emit();
    } catch (e) {
      // A session the runtime has unloaded answers "Session is not active"
      // forever after — it is definitely not running, so clear a stale
      // running status instead of freezing the stop button on-screen.
      if ('$e'.toLowerCase().contains('not active')) {
        final state = _state;
        if (state != null && state.sessionStatus == 'running') {
          state.sessionStatus = 'idle';
          _emit();
        }
      }
      zlog('[zremote] readSession poll failed: $e');
    }
  }

  /// Pulls cumulative token counters for the token-usage detail sheet.
  Future<void> pollTokenUsage() async {
    final service = bridge.taskService;
    if (service == null) return;
    try {
      final result = await service.getTaskTokenUsage(sessionId);
      final state = _state;
      if (state == null || result.isEmpty) return;
      state.tokenUsage = result;
      _emit();
    } catch (e) {
      zlog('[zremote] token usage poll failed: $e');
    }
  }

  /// Fetches the newest rows (no beforeRowId → latest window) and merges them
  /// into the local state. Rows are upserted by rowId so streaming deltas and
  /// polls coexist. A rowId gap above the fetched window means rows were
  /// produced faster than the window covered — refetch deep once. A max-rowId
  /// regression means the desktop rewound (row.removed) — drop stale tails.
  Future<void> pollLatest({int limit = 60}) async {
    final channel = bridge.topicSession;
    if (channel == null) return;
    try {
      final result = await channel.rowsRange(sessionId, limit: limit);
      final rows = result['rows'];
      if (rows is! List) return;
      final state = _state ??= ConversationState(sessionId: sessionId, logEpoch: '');
      final atLogEpoch = result['atLogEpoch'];
      if (atLogEpoch is String && atLogEpoch.isNotEmpty) {
        state.logEpoch = atLogEpoch;
      }
      // Some host builds inline snapshot fields (control/pendingInteractions/
      // meta) in the rowsRange response; when present they are the only way
      // approvals and the notification feed reach us while event push (204
      // frames) is broken (E2E-verified 2026-08-16).
      final control = result['control'];
      if (control is Map<String, Object?>) state.control = control;
      final meta = result['meta'];
      if (meta is Map<String, Object?>) state.meta = meta;
      final interactions = result['pendingInteractions'];
      if (interactions is List) {
        state.pendingInteractions = interactions
            .whereType<Map<String, Object?>>()
            .map(PendingInteraction.fromJson)
            .toList();
      }
      int? minFetched;
      int? maxFetched;
      final parsed = <ConversationRow>[];
      for (final r in rows.whereType<Map<String, Object?>>()) {
        final row = ConversationRow.fromJson(r);
        parsed.add(row);
        minFetched = minFetched == null || row.rowId < minFetched ? row.rowId : minFetched;
        maxFetched = maxFetched == null || row.rowId > maxFetched ? row.rowId : maxFetched;
      }
      final knownMax = state.rows.isEmpty ? null : state.rows.lastKey();
      if (parsed.isNotEmpty && knownMax != null && minFetched! > knownMax + 1 && limit < 200) {
        // Gap: more rows appeared than the tail window covers.
        await pollLatest(limit: 200);
        return;
      }
      if (maxFetched != null && knownMax != null && maxFetched < knownMax) {
        state.rows.removeWhere((id, _) => id > maxFetched!);
      }
      for (final row in parsed) {
        state.rows[row.rowId] = row;
      }
      _emit();
    } catch (e) {
      zlog('[zremote] rows poll failed: $e');
    }
  }

  /// Seeds rows from the offline cache before the live snapshot arrives, so
  /// the user sees history immediately (and while offline).
  void seedRows(List<ConversationRow> rows) {
    final state = _state ??= ConversationState(sessionId: sessionId, logEpoch: '');
    for (final row in rows) {
      state.rows[row.rowId] = row;
    }
    _emit();
  }

  Future<void> loadOlderRows() async {
    final state = _state;
    final channel = bridge.topicSession;
    if (state == null || channel == null || state.rows.isEmpty) return;
    final firstRowId = state.rows.firstKey();
    if (firstRowId == null) return;
    final result = await channel.rowsRange(sessionId, beforeRowId: firstRowId);
    final rows = result['rows'];
    final hasMore = result['hasMore'] as bool? ?? false;
    if (rows is List) {
      for (final r in rows.whereType<Map<String, Object?>>()) {
        final row = ConversationRow.fromJson(r);
        state.rows[row.rowId] = row;
      }
      state.needsOlderRows = hasMore;
      _emit();
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _pollTimer?.cancel();
    _tokenTimer?.cancel();
    await _frameSub?.cancel();
    final channel = bridge.topicSession;
    final subscriptionId = _subscriptionId;
    if (channel != null && subscriptionId != null) {
      try {
        await channel.unsubscribeConversation(sessionId, subscriptionId);
      } catch (_) {}
    }
    await _stateController.close();
    await _connectedController.close();
  }
}
