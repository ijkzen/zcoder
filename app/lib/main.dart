import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'src/app_controller.dart';
import 'src/protocol/zlog.dart';
import 'src/services/notifications.dart';
import 'src/services/update_checker.dart';
import 'src/storage/app_database.dart';
import 'src/ui/deep_link.dart';
import 'src/ui/devices_page.dart';
import 'src/ui/settings_page.dart';
import 'src/ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final app = AppController();
  await app.loadPairings();
  await NotificationService.instance.init(app);

  runApp(ZcodeRemoteApp(app: app));
}

class ZcodeRemoteApp extends StatefulWidget {
  final AppController app;
  const ZcodeRemoteApp({super.key, required this.app});

  @override
  State<ZcodeRemoteApp> createState() => _ZcodeRemoteAppState();
}

class _ZcodeRemoteAppState extends State<ZcodeRemoteApp> {
  StreamSubscription<String>? _deepLinkSub;

  @override
  void initState() {
    super.initState();
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
  }

  Future<void> _silentCheckForUpdates() async {
    try {
      final channelLabel = await AppDatabase.instance.getSetting(
        'update_channel',
      );
      final channel = UpdateChannel.fromLabel(channelLabel);
      final checker = UpdateChecker(
        owner: 'ijkzen',
        repo: 'zcoder',
        currentVersion: appVersion,
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

  @override
  void dispose() {
    _deepLinkSub?.cancel();
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
