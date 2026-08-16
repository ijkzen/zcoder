/// Notification deep links (`zcode-remote://approval/workspaceKey|sessionId`).
///
/// Two entry points share this coordinator: a tap while the app is running
/// (AppController.deepLinkStream) and the pending link consumed right after a
/// manual connect from the devices page. Resolution degrades gracefully:
/// session gone → that project's session list; project gone → the project
/// list; not connected → the link stays pending until the next successful
/// connect; no pairings at all → the link is dropped with a hint.
library;

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../bridge/bridge_manager.dart';
import 'conversation_page.dart';
import 'sessions_page.dart';
import 'workspaces_page.dart';

/// Global navigator key so notification taps can navigate from anywhere.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

(String, String)? _parse(String raw) {
  final parts = raw.split('|');
  if (parts.length != 2 || parts[0].isEmpty || parts[1].isEmpty) return null;
  return (parts[0], parts[1]);
}

void _toast(String message) {
  final context = appNavigatorKey.currentContext;
  if (context != null && context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

void _popToRoot() {
  appNavigatorKey.currentState?.popUntil((route) => route.isFirst);
}

/// Handles one deep link. Already-connected taps resolve immediately; a link
/// that arrives before any connection stays pending (the devices page takes
/// it after the next successful connect).
Future<void> handleDeepLink(AppController app, String raw) async {
  final parsed = _parse(raw);
  if (parsed == null) return;
  final (workspaceKey, sessionId) = parsed;

  final connected =
      app.phase == BridgePhase.pairing || app.phase == BridgePhase.ready;
  if (!connected) {
    // Stays pending unless there is nothing to connect with.
    if (app.pairings.isEmpty) {
      app.discardPendingDeepLink();
      _popToRoot();
      _toast('配对不存在，请先扫码配对');
    } else {
      _popToRoot();
    }
    return;
  }

  // Already looking at this exact session — nothing to do.
  if (app.conversation?.state?.sessionId == sessionId) return;

  final navigator = appNavigatorKey.currentState;
  if (navigator == null) return;

  final workspace = app.workspaces
      .where((w) => w.workspaceKey == workspaceKey)
      .firstOrNull;
  if (workspace == null) {
    _popToRoot();
    await navigator.push(
      MaterialPageRoute(builder: (_) => WorkspacesPage(app: app)),
    );
    _toast('会话已不存在');
    return;
  }

  try {
    await app.selectWorkspace(workspace);
  } catch (e) {
    _popToRoot();
    await navigator.push(
      MaterialPageRoute(builder: (_) => WorkspacesPage(app: app)),
    );
    _toast('打开项目失败：$e');
    return;
  }

  // The session may be archived — still openable (read-only).
  final task = app.sessions.where((s) => s.taskId == sessionId).firstOrNull;
  final archivedTask = app.archivedSessions
      .where((s) => s.taskId == sessionId)
      .firstOrNull;
  final found = task ?? archivedTask;

  _popToRoot();
  // Stack: devices → sessions → conversation. The intermediate sessions page
  // gets a zero-duration transition so the jump feels direct while the back
  // button still lands on the session list.
  await navigator.push(
    PageRouteBuilder(
      pageBuilder: (_, _, _) => SessionsPage(app: app, workspace: workspace),
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
    ),
  );
  if (found == null) {
    _toast('会话已不存在');
    return;
  }
  final title = (found.taskTitle != null && found.taskTitle!.isNotEmpty)
      ? found.taskTitle!
      : null;
  await navigator.push(
    MaterialPageRoute(
      builder: (_) => ConversationPage(
        app: app,
        sessionId: sessionId,
        title: title,
        archived: found.archived,
      ),
    ),
  );
}
