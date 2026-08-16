/// Subscribes to the `sessions-index/{workspaceKey}` topic and maintains the
/// live list of sessions for the active workspace.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../bridge/bridge_manager.dart';
import '../session/models.dart';
import '../session/session_channel.dart';

class SessionsIndexController {
  final BridgeManager bridge;
  final String workspaceKey;

  SessionsIndexController(this.bridge, this.workspaceKey);

  final _sessionsController = StreamController<List<SessionSummary>>.broadcast();
  final _connectedController = StreamController<bool>.broadcast();

  Stream<List<SessionSummary>> get sessionsStream => _sessionsController.stream;
  Stream<bool> get connectedStream => _connectedController.stream;

  List<SessionSummary> _sessions = [];
  List<SessionSummary> get sessions => _sessions;

  String? _subscriptionId;
  StreamSubscription<TopicFrame>? _frameSub;
  bool _disposed = false;
  String? _topic;

  Future<void> start() async {
    final channel = bridge.sessionChannel;
    if (channel == null) throw StateError('no session channel');
    _topic = 'sessions-index/$workspaceKey';

    _frameSub = channel.sessionsIndexFrames.listen(_onFrame);
    final ack = await channel.subscribeSessionsIndex(workspaceKey);
    _subscriptionId = ack.subscriptionId;
    if (!_disposed) _connectedController.add(true);
    // Pull the initial snapshot — subscribe alone only streams new deltas.
    try {
      await channel.resyncSessionsIndex(ack.subscriptionId, logEpoch: ack.logEpoch);
    } catch (e) {
      debugPrint('[zremote] sessions-index resync failed: $e');
    }
  }

  void _onFrame(TopicFrame frame) {
    if (frame is! TopicDataFrame) return;
    final payload = frame.payload;
    if (payload['kind'] == 'snapshot') {
      final snapshot = payload['snapshot'];
      if (snapshot is Map<String, Object?> && snapshot['sessions'] is List) {
        _sessions = (snapshot['sessions'] as List)
            .whereType<Map<String, Object?>>()
            .map(SessionSummary.fromJson)
            .toList();
        _emit();
      }
    } else {
      final deltas = payload['deltas'];
      if (deltas is List) {
        for (final d in deltas.whereType<Map<String, Object?>>()) {
          _applyDelta(d);
        }
        _emit();
      }
    }
  }

  void _applyDelta(Map<String, Object?> op) {
    switch (op['op'] ?? op['kind']) {
      case 'session.upserted':
        final s = op['session'];
        if (s is Map<String, Object?>) {
          final summary = SessionSummary.fromJson(s);
          final idx = _sessions.indexWhere((e) => e.sessionId == summary.sessionId);
          if (idx >= 0) {
            _sessions[idx] = summary;
          } else {
            _sessions.add(summary);
          }
        }
      case 'session.removed':
        final sessionId = op['sessionId'];
        if (sessionId is String) {
          _sessions.removeWhere((e) => e.sessionId == sessionId);
        }
    }
  }

  void _emit() {
    if (!_disposed && !_sessionsController.isClosed) {
      _sessionsController.add(List.unmodifiable(_sessions));
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await _frameSub?.cancel();
    final channel = bridge.sessionChannel;
    if (channel != null && _subscriptionId != null && _topic != null) {
      try {
        await channel.unsubscribe(_topic!, _subscriptionId!);
      } catch (_) {}
    }
    await _sessionsController.close();
    await _connectedController.close();
  }
}
