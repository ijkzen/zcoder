/// Battery optimization status and device manufacturer helpers.
///
/// Wraps the `dev.ijkzen.zcode_remote/device_info` method channel calls
/// added for background keep-alive diagnostics. Follows the same pattern
/// as [app_version.dart]: free functions, Platform guard, nullable return.
library;

import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import '../protocol/zlog.dart';

const _platform = MethodChannel('dev.ijkzen.zcode_remote/device_info');

/// Whether the app is exempt from battery optimization (Doze whitelist).
///
/// Returns `false` on non-Android or on error.
Future<bool> isIgnoringBatteryOptimizations() async {
  if (!Platform.isAndroid) return false;
  try {
    final result = await _platform.invokeMethod<bool>(
      'isIgnoringBatteryOptimizations',
    );
    final exempt = result ?? false;
    zlog('[battery] isIgnoringBatteryOptimizations: $exempt');
    return exempt;
  } on PlatformException catch (e) {
    zlog('[battery] isIgnoringBatteryOptimizations failed: ${e.message}');
    return false;
  }
}

/// Device manufacturer in lowercase (e.g. `xiaomi`, `huawei`, `samsung`).
///
/// Returns `null` on non-Android or on error.
Future<String?> deviceManufacturer() async {
  if (!Platform.isAndroid) return null;
  try {
    final result = await _platform.invokeMethod<String>('getManufacturer');
    if (result != null && result.isNotEmpty) {
      zlog('[battery] manufacturer: $result');
      return result;
    }
  } on PlatformException catch (e) {
    zlog('[battery] getManufacturer failed: ${e.message}');
  }
  return null;
}

/// Opens the system battery optimization settings for this app.
///
/// Tries `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` first; falls back to
/// the app details settings page if the intent is not available.
Future<bool> openBatteryOptimizationSettings() async {
  if (!Platform.isAndroid) return false;
  try {
    final result = await _platform.invokeMethod<bool>(
      'openBatteryOptimizationSettings',
    );
    final ok = result ?? false;
    zlog('[battery] openBatteryOptimizationSettings: $ok');
    return ok;
  } on PlatformException catch (e) {
    zlog('[battery] openBatteryOptimizationSettings failed: ${e.message}');
    return false;
  }
}
