/// Pure bookkeeping for the launcher-app-icon badge count.
///
/// The badge shows how many sessions entered a terminal state (completed /
/// interrupted / errored) that the user hasn't viewed yet: one point per
/// session, never more — [add] re-counting an already-counted session is a
/// no-op until [remove]d, and [remove] drops the point when the session is
/// opened. Workspace-agnostic: callers key sessions by pairing + task id.
///
/// No I/O: the app controller mirrors these mutations into the `launcher_badge`
/// table and pushes the resulting [count] to the launcher.
library;

class LauncherBadgeLedger {
  final Set<String> _counted = {};

  int get count => _counted.length;

  bool contains(String sessionKey) => _counted.contains(sessionKey);

  /// Returns true when the session was newly counted (count changed); false
  /// when it was already counted (per-session dedup).
  bool add(String sessionKey) => _counted.add(sessionKey);

  /// Returns true when the session was actually removed (count changed).
  bool remove(String sessionKey) => _counted.remove(sessionKey);

  /// Replaces the whole ledger with [sessionKeys] — used to load the persisted
  /// state on startup.
  void reset(Iterable<String> sessionKeys) {
    _counted
      ..clear()
      ..addAll(sessionKeys);
  }
}
