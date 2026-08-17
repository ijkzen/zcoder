/// Android notifications: a foreground service keeps the relay connection
/// alive in the background, and local notifications fire for approvals,
/// completions, stalls, and disconnects.
library;

import 'dart:async';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../app_controller.dart';
import '../bridge/bridge_manager.dart';
import '../protocol/topics/topic_models.dart';

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();
  final _channel = const NotificationDetails(
    android: AndroidNotificationDetails(
      'zcode_remote_events',
      'ZCode 远程事件',
      channelDescription: 'Agent 批准、完成与断线提醒',
      importance: Importance.high,
      priority: Priority.high,
    ),
  );
  final _channelQuiet = const NotificationDetails(
    android: AndroidNotificationDetails(
      'zcode_remote_quiet',
      'ZCode 状态变化',
      channelDescription: '低优先级状态提醒',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
    ),
  );

  /// Maps notification tap to a deep link the app interprets on launch.
  static const String _approvalPrefix = 'zcode-remote://approval/';

  bool _initialized = false;
  bool _suppressNext = false;
  final Set<int> _reconnectNotifIds = {};

  /// Init must run before runApp. [app] may be null in tests.
  Future<void> init(AppController? app) async {
    if (_initialized) return;
    _initialized = true;

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _local.initialize(
      settings: const InitializationSettings(android: androidInit),
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload;
        if (payload != null && payload.startsWith(_approvalPrefix)) {
          app?.requestDeepLink(payload.substring(_approvalPrefix.length));
        }
      },
    );
    // Android 13+ runtime notification permission — asked once here; denial
    // only silences system notifications, in-app approval chips still work.
    await _local
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();

    if (app != null) {
      app.onNotificationEvent = _handleEvent;
      app.bridgeNotificationHook = _handleBridgeEvent;
    }

    // The foreground task itself holds the connection; starting it begins the
    // Android foreground service that keeps the process (and WebSocket) alive.
    FlutterForegroundTask.initCommunicationPort();
    _startForegroundTask();
  }

  Future<void> _startForegroundTask() async {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'zcode_remote_fgs',
        channelName: 'ZCode 远程连接',
        channelDescription: '保持与桌面端的连接',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowAutoRestart: true,
      ),
    );
    await FlutterForegroundTask.startService(
      serviceTypes: [ForegroundServiceTypes.dataSync],
      notificationTitle: 'ZCode 远程',
      notificationText: '保持与桌面端的连接',
    );
  }

  void _handleEvent(Map<String, Object?> event) {
    if (_suppressNext) {
      _suppressNext = false;
      return;
    }
    switch (event['type']) {
      case 'pending-interaction':
        final prompt = (event['prompt'] ?? '').toString();
        final toolName = (event['toolName'] ?? '').toString();
        final sessionId = event['sessionId']?.toString() ?? '';
        final workspaceKey = event['workspaceKey']?.toString() ?? '';
        _local.show(
          id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          title: '需要你的操作',
          body: toolName.isNotEmpty ? '「$toolName」等待批准：$prompt' : prompt,
          notificationDetails: _channel,
          payload: '$_approvalPrefix$workspaceKey|$sessionId',
        );
      case 'phase':
        final phase = event['phase']?.toString() ?? '';
        final done = switch (phase) {
          SessionPhase.completedSuccess => '任务已完成',
          SessionPhase.completedInterrupted => '任务已中断',
          SessionPhase.error => '执行出错',
          _ => null,
        };
        if (done != null) {
          final sessionId = event['sessionId']?.toString() ?? '';
          final workspaceKey = event['workspaceKey']?.toString() ?? '';
          _local.show(
            id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
            title: done,
            body: '会话 ${event['sessionId']}',
            notificationDetails: _channelQuiet,
            payload: '$_approvalPrefix$workspaceKey|$sessionId',
          );
        }
      case 'stall':
        final sessionId = event['sessionId']?.toString() ?? '';
        final workspaceKey = event['workspaceKey']?.toString() ?? '';
        _local.show(
          id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          title: 'Agent 已停滞',
          body: '会话 ${event['sessionId']} 长时间没有新输出，去看看？',
          notificationDetails: _channelQuiet,
          payload: '$_approvalPrefix$workspaceKey|$sessionId',
        );
    }
  }

  Future<void> _handleBridgeEvent(BridgeException e) async {
    final body = switch (e.reason) {
      'desktopOffline' => '桌面端已离线，正在等待重连',
      'sessionExpired' => '链接已失效，请重新扫码配对',
      'sessionConflict' => '已被其他设备接管',
      'kicked' => '已被其他设备接管，连接已断开',
      'relayUnavailable' => '无法连接中转服务，正在重试',
      'bridge-degraded' => '连接不稳定，正在重连',
      'desktop-disconnected' => '与桌面端的连接已断开，正在重连',
      _ => e.message.isEmpty ? '连接中断，正在重连' : e.message,
    };
    // Cancel previous reconnect notification before posting a new one.
    if (_reconnectNotifIds.isNotEmpty) {
      for (final oldId in _reconnectNotifIds) {
        await _local.cancel(id: oldId);
      }
      _reconnectNotifIds.clear();
    }
    final id = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _reconnectNotifIds.add(id);
    _local.show(
      id: id,
      title: '连接中断',
      body: body,
      notificationDetails: _channelQuiet,
    );
  }

  /// Dismiss the current reconnect notification when the bridge recovers.
  Future<void> cancelReconnectNotification() async {
    if (_reconnectNotifIds.isEmpty) return;
    for (final id in _reconnectNotifIds) {
      await _local.cancel(id: id);
    }
    _reconnectNotifIds.clear();
  }

  /// Call while the app is foregrounded to swallow the next event (the
  /// user already sees it).
  void suppressNext() => _suppressNext = true;

  Future<void> stopForegroundTask() async {
    await FlutterForegroundTask.stopService();
  }
}
