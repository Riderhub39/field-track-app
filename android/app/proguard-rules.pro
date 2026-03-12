# Flutter Wrapper
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Google ML Kit & TensorFlow Lite (修复报错的关键)
-keep class com.google.mlkit.** { *; }
-keep class org.tensorflow.** { *; }
-keep class org.tensorflow.lite.** { *; }
-keep class org.tensorflow.lite.gpu.** { *; }
-dontwarn org.tensorflow.**
-dontwarn com.google.mlkit.**
-dontwarn io.flutter.embedding.engine.deferredcomponents.**
-dontwarn com.google.android.play.core.splitcompat.**
-dontwarn com.google.android.play.core.splitinstall.**
-dontwarn com.google.android.play.core.tasks.**
-dontwarn com.google.android.play.core.**

# 保持这些类不被混淆（为了防止意外的反射调用报错）
-keep class io.flutter.embedding.engine.deferredcomponents.** { *; }
-keep class com.google.android.play.core.splitcompat.** { *; }
# 防止移除 Native 方法
-keepclasseswithmembernames class * {
    native <methods>;
}