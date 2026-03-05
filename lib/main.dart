import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'; 
import 'services/time_service.dart';
import 'widgets/biometric_guard.dart'; 
import 'services/background_service.dart';
import 'firebase_options.dart';
import 'screens/login_screen.dart'; 
import 'screens/home_screen.dart';
import 'services/notification_service.dart';

// 🟢 声明一个全局的生命周期监听器（保持强引用，防止被回收）
late AppLifecycleListener globalLifecycleListener;

final authStateProvider = StreamProvider<User?>((ref) {
  return FirebaseAuth.instance.authStateChanges();
});

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // 1. Initialize Firebase
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // 2. Initialize Notification Service 
  await NotificationService().init();
  
  // 🟢 3. App 冷启动时，同步一次真实网络时间
  await TimeService.syncTime();
  
  // 4. 初始化后台防杀服务
  await initializeBackgroundService();
  
  // 🟢 5. 注册全局生命周期监听：防止用户把 App 挂在后台去修改系统时间
 globalLifecycleListener = AppLifecycleListener(
    onResume: () async {
      debugPrint("🔄 App 恢复到前台，重新校准防篡改时间...");
      await TimeService.syncTime();
    },
  );

  // 6. Initialize Localization
  await EasyLocalization.ensureInitialized();

  runApp(
    ProviderScope(
      child: EasyLocalization(
        supportedLocales: const [
          Locale('en'), 
          Locale('ms'), 
          Locale('zh')  
        ],
        path: 'assets/translations', 
        fallbackLocale: const Locale('en'),
        startLocale: const Locale('en'), 
        child: const MyApp(),
      ),
    ),
  );
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authStateProvider);

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      
      localizationsDelegates: context.localizationDelegates,
      supportedLocales: context.supportedLocales,
      locale: context.locale, 

      title: 'Field Track App',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      
      builder: (context, child) {
        return BiometricGuard(
          child: child ?? const SizedBox.shrink(),
        );
      },

      home: authState.when(
        data: (user) {
          if (user != null) {
            NotificationService().bindFCMToken(user.uid);
            return const HomeScreen(); 
          }
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