/// Notification deep links (`zcode-remote://approval/workspaceKey|sessionId`).
///
/// Two entry points share this coordinator: a tap while the app is running
/// (AppController.deepLinkStream) and the pending link consumed right after a
/// manual connect from the devices page. Resolution degrades gracefully:
/// session gone → that project's session list; project gone → the project
/// list; not connected → the link stays pending until the next successful
/// connect; no pairings at all → the link is dropped with a hint.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../bridge/bridge_manager.dart';
import '../protocol/zlog.dart';
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
  final runId = DateTime.now().microsecondsSinceEpoch % 100000;
  zlog('[deepLink] ==== #$runId 开始处理 raw=$raw phase=${app.phase} ====');
  final parsed = _parse(raw);
  if (parsed == null) {
    zlog('[deepLink] 无法解析的通知链接: "$raw"（预期格式 '
        'workspaceKey|sessionId）');
    return;
  }
  final (workspaceKey, sessionId) = parsed;
  zlog('[deepLink] 收到链接 workspaceKey=$workspaceKey '
      'sessionId=$sessionId, phase=${app.phase}');

  final connected =
      app.phase == BridgePhase.pairing || app.phase == BridgePhase.ready;
  if (!connected) {
    // Stays pending unless there is nothing to connect with.
    if (app.pairings.isEmpty) {
      app.discardPendingDeepLink();
      _popToRoot();
      _toast('配对不存在，请先扫码配对');
      zlog('[deepLink] 无配对，丢弃链接');
    } else {
      _popToRoot();
      zlog('[deepLink] 未连接（phase=${app.phase}），链接保留待下次连接');
    }
    return;
  }

  // Already looking at this exact session — nothing to do.
  if (app.conversation?.state?.sessionId == sessionId) {
    zlog('[deepLink] 已在目标会话中，跳过');
    return;
  }

  final navigator = appNavigatorKey.currentState;
  if (navigator == null) {
    zlog('[deepLink] navigator 不可用');
    return;
  }

  zlog('[deepLink] workspaces=${app.workspaces.length} 个，查找 '
      'workspaceKey=$workspaceKey');
  final workspace = app.workspaces
      .where((w) => w.workspaceKey == workspaceKey)
      .firstOrNull;
  if (workspace == null) {
    _popToRoot();
    unawaited(
      navigator.push(
        MaterialPageRoute(builder: (_) => WorkspacesPage(app: app)),
      ),
    );
    _toast('会话已不存在');
    zlog('[deepLink] 工作区不存在，退回项目列表');
    return;
  }

  try {
    await app.selectWorkspace(workspace);
  } catch (e) {
    _popToRoot();
    unawaited(
      navigator.push(
        MaterialPageRoute(builder: (_) => WorkspacesPage(app: app)),
      ),
    );
    _toast('打开项目失败：$e');
    zlog('[deepLink] 打开项目失败：$e');
    return;
  }

  // The session may be archived — still openable (read-only).
  final task = app.sessions.where((s) => s.taskId == sessionId).firstOrNull;
  final archivedTask = app.archivedSessions
      .where((s) => s.taskId == sessionId)
      .firstOrNull;
  final found = task ?? archivedTask;
  zlog('[deepLink] 会话查找 taskId=$sessionId → '
      '${found == null ? "未找到" : "找到"}');

  zlog('[deepLink] ==== #$runId popToRoot 前');
  _popToRoot();
  zlog('[deepLink] ==== #$runId 开始 push SessionsPage');
  // Stack: devices → sessions → conversation. The intermediate sessions page
  // gets a zero-duration transition so the jump feels direct while the back
  // button still lands on the session list.
  //
  // NOTE: the pushes are intentionally NOT awaited — Navigator.push resolves
  // only when the pushed route is popped, so awaiting here would hang the
  // call and the ConversationPage push below would never run until the user
  // leaves the session list (the "tap notification → stuck on the list,
  // back pops into the conversation" bug).
  unawaited(
    navigator.push(
      PageRouteBuilder(
        pageBuilder: (_, _, _) => SessionsPage(app: app, workspace: workspace),
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      ),
    ),
  );
  zlog('[deepLink] ==== #$runId SessionsPage push 完成，found=${
      found == null ? "null" : found.taskId}');
  if (found == null) {
    _toast('会话已不存在');
    return;
  }
  final title = (found.taskTitle != null && found.taskTitle!.isNotEmpty)
      ? found.taskTitle!
      : null;
  zlog('[deepLink] ==== #$runId 开始 push ConversationPage');
  unawaited(
    navigator.push(
      MaterialPageRoute(
        builder: (_) => ConversationPage(
          app: app,
          sessionId: sessionId,
          title: title,
          archived: found.archived,
        ),
      ),
    ),
  );
  zlog('[deepLink] ==== #$runId ConversationPage push 完成');
}
