import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'; // 🟢 新增：引入 Riverpod

// 📦 Import Biometric Guard 
import 'widgets/biometric_guard.dart'; 
import 'services/background_service.dart';
import 'firebase_options.dart';
import 'screens/login_screen.dart'; 
import 'screens/home_screen.dart';
import 'services/notification_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // 1. Initialize Firebase
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // 2. Initialize Notification Service (包含 FCM 初始化)
  await NotificationService().init();
  await BackgroundService.initialize();
  
  // 3. Initialize Localization
  await EasyLocalization.ensureInitialized();

  // 🟢 4. 使用 ProviderScope 包装应用最外层，这是使用 Riverpod 的必要条件
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

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
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

      // Auth Flow
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          
          if (snapshot.hasError) {
            return const Scaffold(
              body: Center(child: Text("Connection Error. Please restart.")),
            );
          }

          if (snapshot.hasData) {
            // 🟢 登录成功后，绑定 FCM Token，以便后台能推送消息给这个人
            final user = snapshot.data!;
            NotificationService().bindFCMToken(user.uid);
            
            return const HomeScreen(); 
          }

          return const LoginScreen(); 
        },
      ),
    );
  }
}