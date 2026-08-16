/// Layer 5 — typed wrappers for the `zcode-task` and `zcode-session`
/// service channels. Only methods with probe-verified argument shapes are
/// exposed; the full method inventory lives in
/// docs/protocol/06-service-inventory.md.
library;

import 'dart:async';

import '../rpc/channel_client.dart';

/// Every call takes a workspace target: `{workspacePath, workspaceIdentity?}`.
class WorkspaceTarget {
  final String workspacePath;
  final String? workspaceIdentity;

  const WorkspaceTarget({required this.workspacePath, this.workspaceIdentity});

  Map<String, Object?> toJson() => {
        'workspacePath': workspacePath,
        if (workspaceIdentity != null) 'workspaceIdentity': workspaceIdentity,
      };
}

/// Shared plumbing for service wrappers: every call takes the workspace
/// target alongside the method-specific args.
abstract class WorkspaceService {
  final RpcChannel _channel;
  final WorkspaceTarget target;

  WorkspaceService(this._channel, this.target);

  Future<Map<String, Object?>> _call(String method, Map<String, Object?> args) async {
    final raw = await _channel.call(method, {...target.toJson(), ...args});
    return raw is Map<String, Object?> ? raw : const {};
  }
}

/// `zcode-task` — the terminal-facing task facade.
class ZcodeTaskService extends WorkspaceService {
  ZcodeTaskService(RpcChannel channel, WorkspaceTarget target)
      : super(channel, target);

  /// Cumulative token counters for a task.
  Future<Map<String, Object?>> getTaskTokenUsage(String taskId) =>
      _call('getTaskTokenUsage', {'taskId': taskId});

  /// Renames a task (no baseRevision needed, unlike the renameSession
  /// conversation command).
  Future<Map<String, Object?>> renameTask(String taskId, String title) =>
      _call('renameTask', {'taskId': taskId, 'title': title});

  /// Archives a task — archived tasks drop out of the workspace task list.
  Future<Map<String, Object?>> archiveTask(String taskId) =>
      _call('archiveTask', {'taskId': taskId});

  Future<Map<String, Object?>> unarchiveTask(String taskId) =>
      _call('unarchiveTask', {'taskId': taskId});

  /// Permanently deletes a task (the desktop cancels it first if running).
  Future<Map<String, Object?>> deleteTask(String taskId) =>
      _call('deleteTask', {'taskId': taskId});

  /// Marks a task (un)read — drives the unread badge on the sessions list.
  /// `expectedUnreadAt` optionally guards the clear against races.
  Future<Map<String, Object?>> setTaskUnread(
    String taskId, {
    required bool unread,
    int? expectedUnreadAt,
  }) =>
      _call('setTaskUnread', {
        'taskId': taskId,
        'unread': unread,
        if (expectedUnreadAt != null) 'expectedUnreadAt': expectedUnreadAt,
      });

  /// Pins / unpins a task.
  Future<Map<String, Object?>> setTaskPinned(String taskId, {required bool pinned}) =>
      _call('setTaskPinned', {'taskId': taskId, 'pinned': pinned});
}

/// `zcode-session` — session-level reads and settings.
class ZcodeSessionService extends WorkspaceService {
  ZcodeSessionService(RpcChannel channel, WorkspaceTarget target)
      : super(channel, target);

  /// Snapshot of one session: `{session:{status, …}, settings:{model,
  /// thoughtLevel}, runtime:{contextUsage}, projection:{pendingPermissions},
  /// messages?}`.
  Future<Map<String, Object?>> readSession(
    String sessionId, {
    int? messageLimit,
    int? afterSeq,
  }) =>
      _call('readSession', {
        'sessionId': sessionId,
        if (messageLimit != null) 'messageLimit': messageLimit,
        if (afterSeq != null) 'afterSeq': afterSeq,
      });

  /// Switches the session's model (and optionally thought level) directly on
  /// the runtime — no baseRevision needed, unlike the switchModelConfig
  /// conversation command.
  Future<Map<String, Object?>> setModel(
    String sessionId, {
    required String provider,
    required String model,
    String? thoughtLevel,
  }) =>
      _call('setModel', {
        'sessionId': sessionId,
        'model': '$provider/$model',
        if (thoughtLevel != null) 'thoughtLevel': thoughtLevel,
      });

  /// Switches the session's thought level (reasoning effort).
  Future<Map<String, Object?>> setThoughtLevel(String sessionId, String thoughtLevel) =>
      _call('setThoughtLevel', {'sessionId': sessionId, 'thoughtLevel': thoughtLevel});

  /// The workspace's model registry and default thought level.
  Future<Map<String, Object?>> readWorkspaceState() => _call('readWorkspaceState', const {});
}
