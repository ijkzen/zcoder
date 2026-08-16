import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../bridge/bridge_manager.dart';
import '../session/models.dart';
import 'project_avatar.dart';
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

/// Screen 2: projects (workspaces) open on the connected desktop device.
/// Tapping one opens the bridge to it and pushes that project's session list.
class WorkspacesPage extends StatelessWidget {
  final AppController app;
  const WorkspacesPage({super.key, required this.app});

  Future<void> _open(BuildContext context, ProjectGroup project) async {
    await app.selectWorkspace(project.representative);
    if (!context.mounted) return;
    if (app.phase != BridgePhase.ready) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('打开项目失败：${app.lastError ?? '未知错误'}')),
      );
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          SessionsPage(app: app, workspace: project.representative),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(app.activePairing?.displayName ?? '项目'),
        actions: [
          IconButton(
            tooltip: '断开',
            icon: const Icon(Icons.link_off),
            onPressed: () {
              app.disconnect();
              Navigator.of(context).pop();
            },
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: app,
        builder: (context, _) {
          final projects = groupProjects(app.workspaces);
          if (projects.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.folder_off_outlined,
                        size: 56, color: scheme.outline),
                    const SizedBox(height: 12),
                    Text(
                      '桌面端没有打开的项目',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '在电脑上先打开一个项目，然后回到这里刷新',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: () => app.bridge?.sendPayload({
                        'zcode_type': 'workspace-list-request',
                        'requestId':
                            'refresh-${DateTime.now().millisecondsSinceEpoch}',
                      }),
                      icon: const Icon(Icons.refresh),
                      label: const Text('刷新'),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: projects.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final project = projects[i];
              final running = project.runningCount;
              return Card(
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: projectAvatarColor(project.label),
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
                          padding: const EdgeInsets.only(right: 4),
                          child: Chip(
                            label: Text('$running 运行中'),
                            labelStyle: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(color: scheme.onPrimaryContainer),
                            backgroundColor: scheme.primaryContainer,
                            side: BorderSide.none,
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      const Icon(Icons.chevron_right),
                    ],
                  ),
                  onTap: () => _open(context, project),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
