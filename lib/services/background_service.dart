import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../firebase_options.dart'; 
import 'local_db_service.dart';


// ==========================================
// 1. 初始化服务 (在 main.dart 或 UI 中调用)
// ==========================================
Future<void> initializeBackgroundService() async {
  final service = FlutterBackgroundService();

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'tracking_channel', 
    'Working Hours Location Tracking', // 🟢 明确是工作时间的追踪
    description: 'This notifies you that your location is being shared with the admin in the background during working hours.', // 🟢 增加 PDPA 与后台说明
    importance: Importance.low, 
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
  await flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false, 
      isForegroundMode: true,
      notificationChannelId: 'tracking_channel',
      initialNotificationTitle: 'FieldTrack Pro',
      initialNotificationContent: 'Initializing location service...',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
  );
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  return true;
}

// ==========================================
// 2. 核心后台逻辑 (独立 Isolate 运行)
// ==========================================
@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  // 1. 初始化 Firebase
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  } catch (e) {
    debugPrint("Firebase already initialized or error: $e");
  }

  // 2. 获取当前追踪的 userId
  final prefs = await SharedPreferences.getInstance();
  String? userId = prefs.getString('current_tracking_uid');
  if (userId == null) {
    service.stopSelf();
    return;
  }

  // 监听前台发来的停止指令
  service.on('stopService').listen((event) {
    service.stopSelf();
  });

  const LocationSettings locationSettings = LocationSettings(
    accuracy: LocationAccuracy.high,
    distanceFilter: 10, 
  );

  Position? lastLocalSavedPosition;
  const double localDistanceFilter = 50.0; 

  // 3. 启动不间断的位置监听
  Geolocator.getPositionStream(locationSettings: locationSettings).listen((Position position) async {
    
    // 过滤距离 (50米)
    if (lastLocalSavedPosition != null) {
      double distance = Geolocator.distanceBetween(
        lastLocalSavedPosition!.latitude, lastLocalSavedPosition!.longitude,
        position.latitude, position.longitude,
      );
      if (distance < localDistanceFilter) return; 
    }

    lastLocalSavedPosition = position;

    try {
      // 🟢 A: 存入本地 SQLite
      await LocalDbService().insertLocation(position.latitude, position.longitude);

      // 🟢 B: 同步至 RTDB (实时地图)
      FirebaseDatabase.instance.ref("live_locations/$userId").update({
        'uid': userId,
        'lat': position.latitude,
        'lng': position.longitude,
        'speed': position.speed,
        'heading': position.heading,
        'lastUpdate': ServerValue.timestamp, 
      });
      
      debugPrint("✅ [Background] Location updated & cached.");

      // 🟢 更新前台通知内容 (Android 合规要求)
      if (service is AndroidServiceInstance) {
        service.setForegroundNotificationInfo(
          title: "FieldTrack Pro - Active",
          content: "Your location is being updated in the background.", // 明确告知用户后台正在定位
        );
      }
    } catch (e) {
      debugPrint("❌ Background Location Error: $e");
    }
  });
}