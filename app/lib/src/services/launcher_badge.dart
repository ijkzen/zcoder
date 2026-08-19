/// Pushes the launcher-app-icon badge count to the native side (ShortcutBadger).
/// Numeric badges only render on launchers that support them (Samsung, MIUI,
/// OPPO, vivo, …); on unsupported launchers the call is a safe no-op.
library;

import 'package:flutter/services.dart';

import '../protocol/zlog.dart';

class LauncherBadge {
  LauncherBadge._();
  static final LauncherBadge instance = LauncherBadge._();

  static const _channel = MethodChannel(
    'dev.ijkzen.zcode_remote/launcher_badge',
  );

  /// Applies [count] to the launcher icon; a count of 0 (or less) removes the
  /// badge. Failures are logged, never thrown — badges are best-effort.
  Future<void> setCount(int count) async {
    try {
      final ok = await _channel.invokeMethod<bool>(
        'setBadgeCount',
        {'count': count},
      );
      if (ok != true) {
        zlog('[badge] 角标未生效（launcher 可能不支持数字角标）count=$count');
      }
    } catch (e) {
      zlog('[badge] 设置角标失败: $e');
    }
  }
}
