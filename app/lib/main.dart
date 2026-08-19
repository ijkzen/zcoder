import 'dart:async';

import 'package:flutter/foundation.dart'
    show FlutterError, PlatformDispatcher, kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'src/app_controller.dart';
import 'src/protocol/log_file.dart';
import 'src/protocol/zlog.dart';
import 'src/services/app_version.dart';
import 'src/services/battery_optimization.dart';
import 'src/services/notifications.dart';
import 'src/services/update_checker.dart';
import 'src/storage/app_database.dart';
import 'src/ui/deep_link.dart';
import 'src/ui/devices_page.dart';
import 'src/ui/settings_page.dart';
import 'src/ui/theme.dart';

Future<void> main() async {
  runZonedGuarded(() async {
    // 必须和 runApp 在同一 zone 里初始化，否则 binding 报 Zone mismatch。
    WidgetsFlutterBinding.ensureInitialized();
    _installLogHandlers();
    await AppLogFile.instance.init(header: await _logHeader());

    final app = AppController();
    await app.loadPairings();
    await NotificationService.instance.init(app);

    runApp(ZcodeRemoteApp(app: app));
  }, (error, stack) {
    AppLogFile.instance.writeLine('[FATAL (zone)] $error\n$stack');
  });
}

/// 日志文件启动头：版本 + 机型 + 时间（时间由 AppLogFile 写入时补）。
Future<String> _logHeader() async {
  final version = await currentAppVersion();
  final model = await deviceModel();
  return '== 启动 ${version == null ? 'v?' : 'v$version'}'
      ' / ${model ?? '?'} ==';
}

/// 把未捕获异常/崩溃也写进日志文件，方便后续排查。
void _installLogHandlers() {
  final previousOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    AppLogFile.instance
        .writeLine('[FlutterError] ${details.exception}\n${details.stack}');
    // 开发期保留默认控制台输出，方便本地肉眼排查。
    if (kDebugMode && previousOnError != null) previousOnError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    AppLogFile.instance.writeLine('[Uncaught] $error\n$stack');
    return true;
  };
}

class ZcodeRemoteApp extends StatefulWidget {
  final AppController app;
  const ZcodeRemoteApp({super.key, required this.app});

  @override
  State<ZcodeRemoteApp> createState() => _ZcodeRemoteAppState();
}

class _ZcodeRemoteAppState extends State<ZcodeRemoteApp>
    with WidgetsBindingObserver {
  StreamSubscription<String>? _deepLinkSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Notification tap while the app is running: navigate immediately when a
    // connection is up; otherwise the link stays pending for the next connect.
    _deepLinkSub = widget.app.deepLinkStream.listen((raw) {
      zlog('[main] deepLinkStream 收到：$raw');
      unawaited(handleDeepLink(widget.app, raw));
    });
    // A tap that happened while the process was alive but the Activity was
    // recreated afterwards (cold-ish resume) loses the broadcast above; the
    // pending link survives on the controller and must be consumed here.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final pending = widget.app.pendingDeepLink;
      if (pending != null) {
        zlog('[main] 启动时发现未消费的链接：$pending');
        unawaited(handleDeepLink(widget.app, pending));
      }
    });
    // Silent update check on startup: shows a SnackBar only if a newer
    // version exists; failures are swallowed so the user is never bothered.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_silentCheckForUpdates());
    });
    // Battery optimization check: if the user has saved pairings but is not
    // exempt, show a one-time dialog nudging them to grant the exemption.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_checkBatteryOptimization());
    });
    // Restore the persisted launcher-app-icon badge count and re-apply it (a
    // process death must not drop unviewed session counts).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(widget.app.loadLauncherBadge());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // "Resumed" = interactively in the foreground. Completion notifications
    // are suppressed for the session the user is currently viewing (see
    // AppController._completionIsVisible); anything else stays eligible.
    widget.app.isForeground = state == AppLifecycleState.resumed;
    // Launchers sometimes reset or cap the icon badge; re-apply on resume. The
    // loaded guard avoids flashing a 0 before the persisted count is read.
    if (state == AppLifecycleState.resumed) {
      if (widget.app.launcherBadgeLoaded) {
        unawaited(widget.app.applyLauncherBadge());
      }
    }
    // 退到后台/被杀前把缓冲日志刷到文件，减少丢日志。
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(AppLogFile.instance.flush());
    }
  }

  Future<void> _silentCheckForUpdates() async {
    try {
      final currentVersion = await currentAppVersion();
      if (currentVersion == null) return;
      final channelLabel = await AppDatabase.instance.getSetting(
        'update_channel',
      );
      final channel = UpdateChannel.fromLabel(channelLabel);
      final checker = UpdateChecker(
        owner: 'ijkzen',
        repo: 'zcoder',
        currentVersion: currentVersion,
      );
      final info = await checker.checkForUpdate(channel: channel);
      if (info != null && mounted) {
        final messenger = ScaffoldMessenger.of(context);
        messenger.showSnackBar(
          SnackBar(
            content: Text('发现新版本 ${info.displayVersion}'),
            action: SnackBarAction(
              label: '查看',
              onPressed: () {
                appNavigatorKey.currentState?.push(
                  MaterialPageRoute(
                    builder: (_) => const SettingsPage(),
                  ),
                );
              },
            ),
          ),
        );
      }
    } catch (_) {
      // Silent: startup check failures should never interrupt the user.
    }
  }

  Future<void> _checkBatteryOptimization() async {
    try {
      // Only prompt when the user has at least one saved pairing (i.e. has
      // connected before). First-time users without pairings don't need this.
      if (widget.app.pairings.isEmpty) return;
      final exempt = await isIgnoringBatteryOptimizations();
      if (exempt || !mounted) return;
      final shouldOpen = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('保持后台连接'),
          content: const Text(
            '检测到电池优化未关闭，后台连接可能会中断。'
            '建议关闭电池优化以保持与桌面端的稳定连接。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('稍后再说'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('去设置'),
            ),
          ],
        ),
      );
      if (shouldOpen == true) {
        await openBatteryOptimizationSettings();
      }
    } catch (_) {
      // Silent: battery check failures should never interrupt the user.
    }
  }

  @override
  void dispose() {
    _deepLinkSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ZCode 远程',
      debugShowCheckedModeBanner: false,
      navigatorKey: appNavigatorKey,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: DevicesPage(app: widget.app),
    );
  }
}

/// Enables the foreground task's global handler; required by
/// flutter_foreground_task for background callbacks.
@pragma('vm:entry-point')
void startForegroundTask() {
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
  FlutterForegroundTask.startService(
    serviceTypes: [ForegroundServiceTypes.dataSync],
    notificationTitle: 'ZCode 远程',
    notificationText: '保持与桌面端的连接',
  );
}
