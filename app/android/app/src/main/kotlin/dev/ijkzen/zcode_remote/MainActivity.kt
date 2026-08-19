package dev.ijkzen.zcode_remote

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import me.leolin.shortcutbadger.ShortcutBadger

class MainActivity : FlutterActivity() {

    private val channelName = "dev.ijkzen.zcode_remote/device_info"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getSupportedAbis" ->
                        result.success(Build.SUPPORTED_ABIS.toList())
                    "getAppVersion" -> {
                        @Suppress("DEPRECATION")
                        val info = packageManager.getPackageInfo(packageName, 0)
                        result.success(info.versionName ?: "")
                    }
                    "getDeviceModel" ->
                        result.success(Build.MODEL)
                    "getManufacturer" ->
                        result.success(Build.MANUFACTURER.lowercase())
                    "isIgnoringBatteryOptimizations" -> {
                        val pm = getSystemService(POWER_SERVICE) as PowerManager
                        result.success(pm.isIgnoringBatteryOptimizations(packageName))
                    }
                    "openBatteryOptimizationSettings" -> {
                        try {
                            val intent = Intent(
                                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                Uri.parse("package:$packageName"),
                            )
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                            result.success(true)
                        } catch (_: Exception) {
                            // Fallback: open app details settings
                            val intent = Intent(
                                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.parse("package:$packageName"),
                            )
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                            result.success(true)
                        }
                    }
                    "openAppSettings" -> {
                        // 等价于 permission_handler 的 openAppSettings：跳转本应用
                        // 的系统设置详情页，供被拒权限（如相机）手动授予。
                        val intent = Intent(
                            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            Uri.parse("package:$packageName"),
                        )
                        startActivity(intent)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        // Launcher-app-icon badge. applyCount can be slow on some launchers, so
        // run it off the main thread and post the result back.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.ijkzen.zcode_remote/launcher_badge")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setBadgeCount" -> {
                        val count = call.argument<Int>("count") ?: 0
                        Thread {
                            var ok = false
                            try {
                                if (count <= 0) {
                                    ShortcutBadger.removeCount(this@MainActivity)
                                } else {
                                    ShortcutBadger.applyCount(this@MainActivity, count)
                                }
                                ok = true
                            } catch (_: Exception) {
                                ok = false
                            }
                            Handler(Looper.getMainLooper()).post { result.success(ok) }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
