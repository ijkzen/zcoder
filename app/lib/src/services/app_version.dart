/// 读取当前安装包的实际版本号（Android `versionName`，如 `0.4.9`）。
///
/// 取代在 UI 代码里手工与 pubspec.yaml 同步的版本常量——手工维护容易
/// 漂移（曾长期停留在 `0.4.6`），导致自更新把已是最新的 App 判为旧版。
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';

/// 与 MainActivity 的 `device_info` 通道复用（见 getSupportedAbis）。
const _platform = MethodChannel('dev.ijkzen.zcode_remote/device_info');

/// Android 安装包 versionName；非 Android 平台或读取失败时返回 null。
Future<String?> currentAppVersion() async {
  if (!Platform.isAndroid) return null;
  try {
    final version = await _platform.invokeMethod<String>('getAppVersion');
    if (version != null && version.isNotEmpty) return version;
    debugPrint('[appVersion] 通道返回空版本号');
  } on PlatformException catch (e) {
    debugPrint('[appVersion] 读取失败: $e');
  }
  return null;
}
