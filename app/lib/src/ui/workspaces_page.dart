import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../bridge/bridge_manager.dart';
import '../protocol/topics/topic_models.dart';
import '../protocol/zlog.dart';
import 'project_avatar.dart';
import 'pull_to_refresh.dart';
import 'reconnect_banner.dart';
import 'sessions_page.dart';

/// One project (workspace) on the desktop, with the sessions the desktop
/// reported for it via the workspace-list `tasks` payload.
class ProjectGroup {
  final Workspace representative;
  final List<Workspace> sessions;
  const ProjectGroup({required this.representative, required this.sessions});

  String get workspaceKey => representative.workspaceKey;
  String get label => representative.workspaceLabel.isEmpty
      ? representative.workspacePath
      : representative.workspaceLabel;
  String get path => representative.workspacePath;
  int get runningCount => sessions.where((s) => s.isRunning).length;
  int? get lastActivity {
    int? latest;
    for (final s in sessions) {
      final t = s.updatedAt ?? s.createdAt;
      if (t != null && (latest == null || t > latest)) latest = t;
    }
    return latest;
  }
}

/// Groups the flat task list by workspaceKey (archived tasks excluded — they
/// stay in the payload but must not render or count). Running projects
/// first, then by most recent activity.
List<ProjectGroup> groupProjects(List<Workspace> tasks) {
  final byKey = <String, List<Workspace>>{};
  for (final t in tasks.where((t) => !t.archived)) {
    byKey.putIfAbsent(t.workspaceKey, () => []).add(t);
  }
  final groups = [
    for (final entry in byKey.entries)
      ProjectGroup(representative: entry.value.first, sessions: entry.value),
  ];
  groups.sort((a, b) {
    final ar = a.runningCount > 0 ? 0 : 1;
    final br = b.runningCount > 0 ? 0 : 1;
    if (ar != br) return ar - br;
    return (b.lastActivity ?? 0).compareTo(a.lastActivity ?? 0);
  });
  return groups;
}

/// The task ids a project delete must remove: every task under the workspace
/// key, archived included (they still ride the workspace-list payload even
/// though the list only renders the live ones).
List<String> projectDeleteTaskIds(
  List<Workspace> workspaces,
  String workspaceKey,
) => [
  for (final w in workspaces)
    if (w.workspaceKey == workspaceKey && w.taskId != null) w.taskId!,
];

/// Confirm dialog for deleting a project. [taskCount] is every task under the
/// workspace (archived included); [visibleCount] is what the tile shows. When
/// they differ, the dialog calls out that archived tasks go too. Running
/// sessions are named explicitly — deleting the project interrupts them.
Future<bool> confirmDeleteProject(
  BuildContext context, {
  required String label,
  required int taskCount,
  required int visibleCount,
  int runningCount = 0,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('删除项目'),
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
      contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      content: Text(
        '确定要删除「$label」吗？\n将删除该项目下的 $taskCount 个会话'
        '${taskCount == visibleCount ? '' : '（含已归档）'}，删除后不可恢复。'
        '${runningCount > 0 ? '\n其中 $runningCount 个会话正在运行，删除将中断它们。' : ''}',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(dialogContext).colorScheme.error,
            foregroundColor: Theme.of(dialogContext).colorScheme.onError,
          ),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// Screen 2: projects (workspaces) open on the connected desktop device.
/// Tapping one opens the bridge to it and pushes that project's session list.
/// Long-pressing one offers to delete the project (all its tasks).
class WorkspacesPage extends StatefulWidget {
  final AppController app;
  const WorkspacesPage({super.key, required this.app});

  @override
  State<WorkspacesPage> createState() => _WorkspacesPageState();
}

class _WorkspacesPageState extends State<WorkspacesPage> {
  AppController get app => widget.app;

  bool _deleting = false;

  /// Re-requests the workspace/task list; the workspaces stream updates the
  /// page when the response lands. Also wired to pull-to-refresh.
  Future<void> _refresh() async {
    app.bridge?.sendPayload({
      'zcode_type': 'workspace-list-request',
      'requestId': 'refresh-${DateTime.now().millisecondsSinceEpoch}',
    });
  }

  Future<void> _open(BuildContext context, ProjectGroup project) async {
    zlog('[_open] enter phase=${app.phase} key=${project.workspaceKey}');
    try {
      await app.selectWorkspace(project.representative);
      zlog(
        '[_open] selectWorkspace returned, phase=${app.phase} '
        'lastError=${app.lastError}',
      );
    } catch (e) {
      zlog('[_open] selectWorkspace threw: $e');
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('打开项目失败：$e')));
      return;
    }
    if (!context.mounted) return;
    if (app.phase != BridgePhase.ready) {
      zlog('[_open] phase check failed: ${app.phase} (need ready)');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('打开项目失败：${app.lastError ?? '未知错误'}')),
      );
      return;
    }
    zlog('[_open] pushing SessionsPage');
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            SessionsPage(app: app, workspace: project.representative),
      ),
    );
  }

  Future<void> _deleteProject(ProjectGroup project) async {
    if (_deleting) return;
    final taskIds = projectDeleteTaskIds(app.workspaces, project.workspaceKey);
    final confirmed = await confirmDeleteProject(
      context,
      label: project.label,
      taskCount: taskIds.length,
      visibleCount: project.sessions.length,
      runningCount: project.runningCount,
    );
    if (!confirmed) return;
    setState(() => _deleting = true);
    try {
      final failed = await app.deleteProject(project.workspaceKey);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            failed == 0 ? '已删除「${project.label}」' : '删除完成：$failed 个会话删除失败',
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('删除项目失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // A project delete in flight must run to completion on this page: the
    // AbsorbPointer blocks touches, and PopScope blocks the system back
    // button so the result snackbar can't be lost to a half-way exit.
    return PopScope(
      canPop: !_deleting,
      child: Scaffold(
        appBar: AppBar(
          title: Text(app.activePairing?.displayName ?? '项目'),
          actions: [
            IconButton(
              tooltip: '断开',
              icon: const Icon(Icons.link_off),
              onPressed: _deleting
                  ? null
                  : () {
                      app.disconnect();
                      Navigator.of(context).pop();
                    },
            ),
          ],
          bottom: _deleting
              ? const PreferredSize(
                  preferredSize: Size.fromHeight(4),
                  child: LinearProgressIndicator(minHeight: 4),
                )
              : null,
        ),
        body: Column(
          children: [
            ReconnectBanner(app: app),
            Expanded(
              child: ListenableBuilder(
                listenable: app,
                builder: (context, _) {
                  final projects = groupProjects(app.workspaces);
                  final Widget content;
                  if (projects.isEmpty) {
                    content = RefreshIndicator(
                      onRefresh: _refresh,
                      child: RefreshableEmptyState(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.folder_off_outlined,
                                size: 56,
                                color: scheme.outline,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                '桌面端没有打开的项目',
                                style: Theme.of(
                                  context,
                                ).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '在电脑上先打开一个项目，然后回到这里刷新',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 16),
                              OutlinedButton.icon(
                                onPressed: _refresh,
                                icon: const Icon(Icons.refresh),
                                label: const Text('刷新'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  } else {
                    content = RefreshIndicator(
                      onRefresh: _refresh,
                      child: AbsorbPointer(
                        absorbing: _deleting,
                        child: ListView.separated(
                          padding: const EdgeInsets.all(12),
                          physics: const AlwaysScrollableScrollPhysics(),
                          itemCount: projects.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 8),
                          itemBuilder: (context, i) {
                            final project = projects[i];
                            final running = project.runningCount;
                            return Card(
                              child: ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: projectAvatarColor(
                                    project.label,
                                  ),
                                  child: Text(
                                    projectAvatarLetter(project.label),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                title: Text(
                                  project.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  '${project.sessions.length} 个会话 · ${project.path}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (running > 0)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          right: 4,
                                        ),
                                        child: Chip(
                                          label: Text('$running 运行中'),
                                          labelStyle: Theme.of(context)
                                              .textTheme
                                              .labelSmall
                                              ?.copyWith(
                                                color: scheme
                                                    .onPrimaryContainer,
                                              ),
                                          backgroundColor: scheme
                                              .primaryContainer,
                                          side: BorderSide.none,
                                          visualDensity: VisualDensity
                                              .compact,
                                        ),
                                      ),
                                    const Icon(Icons.chevron_right),
                                  ],
                                ),
                                onTap: () => _open(context, project),
                                onLongPress: _deleting
                                    ? null
                                    : () => _deleteProject(project),
                              ),
                            );
                          },
                        ),
                      ),
                    );
                  }
                  return content;
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
