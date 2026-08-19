/// 读取当前安装包的实际版本号（Android `versionName`，如 `0.4.9`）与设备型号。
///
/// 取代在 UI 代码里手工与 pubspec.yaml 同步的版本常量——手工维护容易
/// 漂移（曾长期停留在 `0.4.6`），导致自更新把已是最新的 App 判为旧版。
/// 设备型号用于日志文件启动头，方便多机型日志对号。
library;

import 'dart:io';

import 'package:flutter/services.dart';

import '../protocol/zlog.dart';

/// 与 MainActivity 的 `device_info` 通道复用（见 getSupportedAbis）。
const _platform = MethodChannel('dev.ijkzen.zcode_remote/device_info');

/// Android 安装包 versionName；非 Android 平台或读取失败时返回 null。
Future<String?> currentAppVersion() async {
  if (!Platform.isAndroid) return null;
  try {
    final version = await _platform.invokeMethod<String>('getAppVersion');
    if (version != null && version.isNotEmpty) return version;
    zlog('[appVersion] 通道返回空版本号');
  } on PlatformException catch (e) {
    zlog('[appVersion] 读取失败: $e');
  }
  return null;
}

/// Android 设备型号（`Build.MODEL`，如 `Pixel 7`）；读取失败返回 null。
Future<String?> deviceModel() async {
  if (!Platform.isAndroid) return null;
  try {
    final model = await _platform.invokeMethod<String>('getDeviceModel');
    if (model != null && model.isNotEmpty) return model;
  } on PlatformException catch (e) {
    zlog('[appVersion] 读取型号失败: $e');
  }
  return null;
}
