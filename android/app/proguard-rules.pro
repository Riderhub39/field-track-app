# ---------------------------------------------------------------------------
# Flutter 基础混淆规则
# ---------------------------------------------------------------------------
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.embedding.engine.** { *; }

# ---------------------------------------------------------------------------
# 第三方库保护 (修复崩溃的关键)
# ---------------------------------------------------------------------------

# 1. 修复 Gson / TypeToken 崩溃 (解决你控制台报错的根源)
-keepattributes Signature
-keepattributes *Annotation*
-keep class com.google.gson.** { *; }
-keep class com.google.gson.reflect.TypeToken { *; }
-keep class com.google.gson.reflect.TypeToken$* { *; }

# 2. 保护 flutter_local_notifications (防止反射调用失败)
-keep class com.dexterous.flutterlocalnotifications.** { *; }

# 3. 保护 Google ML Kit & TensorFlow Lite
-keep class com.google.mlkit.** { *; }
-keep class org.tensorflow.** { *; }
-keep class org.tensorflow.lite.** { *; }
-keep class org.tensorflow.lite.gpu.** { *; }
-dontwarn org.tensorflow.**
-dontwarn com.google.mlkit.**

# 4. 保护 DeviceInfo (确保设备ID在 Release 下稳定)
-keep class dev.fluttercommunity.plus.device_info.** { *; }

# 5. 忽略 Google Play Core 相关警告
-dontwarn io.flutter.embedding.engine.deferredcomponents.**
-dontwarn com.google.android.play.core.**

# 6. 防止移除 Native 方法 (必须)
-keepclasseswithmembernames class * {
    native <methods>;
}

# 7. 防止混淆 Keep 的泛型签名 (防止反射报错)
-keepattributes EnclosingMethod
-keepattributes InnerClasses