# Flutter — only keep what the engine actually needs via reflection/JNI
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.embedding.engine.** { *; }
-keep class io.flutter.plugin.common.** { *; }
-keep class io.flutter.view.FlutterView { *; }
-keep class io.flutter.plugins.GeneratedPluginRegistrant { *; }
-dontwarn io.flutter.embedding.**

# mobile_scanner — ML Kit barcode scanning (JNI + reflection)
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.libraries.barhopper.** { *; }
-keepclassmembers class * extends java.lang.Enum {
    <fields>;
    public static **[] values();
    public static ** valueOf(java.lang.String);
}

# flutter_local_notifications — Gson serialization
-keepattributes Signature
-keepattributes *Annotation*
-keep class * extends com.google.gson.TypeAdapter
-keep class * implements com.google.gson.TypeAdapterFactory
-keep class * implements com.google.gson.JsonSerializer
-keep class * implements com.google.gson.JsonDeserializer
-keepclassmembers,allowobfuscation class * {
  @com.google.gson.annotations.SerializedName <fields>;
}
-keep,allowobfuscation,allowshrinking class com.google.gson.reflect.TypeToken
-keep,allowobfuscation,allowshrinking class * extends com.google.gson.reflect.TypeToken

# flutter_foreground_task
-keep class com.github.pradyotheddy.flutter_foreground_task.** { *; }

# sqflite — SQLite JNI
-keep class com.tekartik.sqflite.** { *; }

# open_filex
-keep class com.crazecoder.open_filex.** { *; }

# permission_handler
-keep class com.baseflow.permissionhandler.** { *; }

# image_picker
-keep class io.flutter.plugins.imagepicker.** { *; }

# file_picker
-keep class com.mr.flutter.plugin.filepicker.** { *; }

# wakelock_plus
-keep class com.fluttercampus.wakelock.** { *; }

# path_provider
-keep class io.flutter.plugins.pathprovider.** { *; }

# shared_preferences
-keep class io.flutter.plugins.sharedpreferences.** { *; }

# package_info_plus
-keep class dev.flutter.plugins.packageinfo.** { *; }
