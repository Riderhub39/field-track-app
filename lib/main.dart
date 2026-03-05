import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'; // 🟢 引入 Riverpod
import 'services/time_service.dart';
// 📦 Import Biometric Guard 
import 'widgets/biometric_guard.dart'; 
import 'services/background_service.dart';
import 'firebase_options.dart';
import 'screens/login_screen.dart'; 
import 'screens/home_screen.dart';
import 'services/notification_service.dart';

// 🟢 1. 定义一个全局的 Auth 状态 Provider
// 以后任何页面想要知道用户是否登录、获取 user.uid，只需 ref.watch(authStateProvider) 即可
final authStateProvider = StreamProvider<User?>((ref) {
  return FirebaseAuth.instance.authStateChanges();
});

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // 1. Initialize Firebase
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // 2. Initialize Notification Service (包含 FCM 初始化)
  await NotificationService().init();
  await initializeBackgroundService();
  await TimeService.syncTime();
  // 3. Initialize Localization
  await EasyLocalization.ensureInitialized();

  // 4. 使用 ProviderScope 包装应用最外层
  runApp(
    ProviderScope(
      child: EasyLocalization(
        supportedLocales: const [
          Locale('en'), // English
          Locale('ms'), // Malay
          Locale('zh')  // Chinese
        ],
        path: 'assets/translations', 
        fallbackLocale: const Locale('en'),
        startLocale: const Locale('en'), 
        child: const MyApp(),
      ),
    ),
  );
}

// 🟢 2. 将 StatelessWidget 替换为 ConsumerWidget，使其具备读取 Provider 的能力
class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 🟢 3. 监听登录状态
    final authState = ref.watch(authStateProvider);

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      
      // Localization Hookup
      localizationsDelegates: context.localizationDelegates,
      supportedLocales: context.supportedLocales,
      locale: context.locale, 

      title: 'Field Track App',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      
      // Use 'builder' to wrap the entire app with BiometricGuard
      builder: (context, child) {
        return BiometricGuard(
          child: child ?? const SizedBox.shrink(),
        );
      },

      // 🟢 4. 使用 Riverpod 的 .when() 优雅地处理异步状态流
      home: authState.when(
        data: (user) {
          if (user != null) {
            // 登录成功后，绑定 FCM Token
            NotificationService().bindFCMToken(user.uid);
            return const HomeScreen(); 
          }
          // 未登录
          return const LoginScreen(); 
        },
        loading: () => const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        ),
        error: (e, stack) => Scaffold(
          body: Center(child: Text("Connection Error: $e\nPlease restart.")),
        ),
      ),
    );
  }
}