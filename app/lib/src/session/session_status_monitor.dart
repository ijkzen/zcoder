/// Terminal-state detection for workspace session-list snapshots.
///
/// Pure logic, no I/O: the app controller feeds each refreshed session list
/// here and gets back the sessions that just crossed into a terminal state.
/// The per-session notified map is shared with the detail-page notifier, so
/// the two independent polls (detail 2s vs list 20s) never double-notify.
library;

import '../protocol/topics/topic_models.dart';

/// Coarse terminal bucket shared by both notification sources:
/// `completedSuccess`/`completedInterrupted`/list `completed` → `completed`,
/// `error` → `error`; anything else (running/idle/…) returns null.
String? normalizeTerminalStatus(String phaseOrStatus) {
  switch (phaseOrStatus) {
    case SessionPhase.completedSuccess:
    case SessionPhase.completedInterrupted:
    case 'completed':
      return 'completed';
    case SessionPhase.error:
      return 'error';
    default:
      return null;
  }
}

/// Detects session-status crossings into a terminal state.
class SessionStatusMonitor {
  SessionStatusMonitor(this.notifiedTerminal);

  /// Shared with the detail-page notifier: `taskId → terminal bucket` already
  /// notified. Written here on detection so the other source skips it.
  final Map<String, String> notifiedTerminal;

  /// Last seen `taskId → displayStatus`; the baseline for transitions.
  final Map<String, String> _snapshot = {};

  /// Feeds one refreshed list; returns the crossings into a terminal state
  /// that have not been notified yet (and marks them notified). The monitor
  /// itself is workspace-agnostic — the caller feeds every task of every
  /// workspace and decides routing from the returned workspaceKey.
  List<({String taskId, String workspaceKey, String status})> detect(
    Iterable<Workspace> fresh,
  ) {
    final events = <({String taskId, String workspaceKey, String status})>[];
    for (final task in fresh) {
      final id = task.taskId;
      final status = task.displayStatus;
      if (id == null) continue;
      final terminal = normalizeTerminalStatus(status);
      if (terminal == null) {
        // Non-terminal: update the baseline and wait for the crossing.
        _snapshot[id] = status;
        continue;
      }
      final prev = _snapshot[id];
      _snapshot[id] = status;
      // First sight or already-terminal-stayed-terminal: no transition.
      if (prev == null || normalizeTerminalStatus(prev) == terminal) continue;
      if (notifiedTerminal[id] == terminal) continue;
      notifiedTerminal[id] = terminal;
      events.add((taskId: id, workspaceKey: task.workspaceKey, status: status));
    }
    return events;
  }
}