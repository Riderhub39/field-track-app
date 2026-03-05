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
import 'time_service.dart';

// ==========================================
// 1. 初始化服务 (在 main.dart 或 UI 中调用)
// ==========================================
Future<void> initializeBackgroundService() async {
  final service = FlutterBackgroundService();

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'tracking_channel', 
    'Live Tracking Service', 
    description: 'This channel is used for live location tracking.', 
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
      initialNotificationTitle: 'FieldTrack Active',
      initialNotificationContent: 'Tracking your location...',
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
// 2. 后台隔离区核心逻辑 (独立于 UI 运行)
// ==========================================
@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  // 1. 在后台 Isolate 重新初始化必要的组件
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  
  // 🟢 极度重要：因为 Isolate 内存不共享，后台服务必须自己同步一次 NTP 真实时间！
  await TimeService.syncTime();

  final prefs = await SharedPreferences.getInstance();
  
  // 监听停止命令
  service.on('stopService').listen((event) {
    service.stopSelf();
  });

  // 获取当前追踪的员工 ID
  final String? userId = prefs.getString('current_tracking_uid');
  if (userId == null) {
    service.stopSelf();
    return;
  }

  // 2. 配置高精度流 (后台专用)
  final locationSettings = AndroidSettings(
    accuracy: LocationAccuracy.high,
    distanceFilter: 20,
    forceLocationManager: true,
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
        'lastUpdate': ServerValue.timestamp, // ServerValue 永远是安全的，不受手机时间影响
      });
      
      debugPrint("✅ [Background] Location updated & cached.");

      // 更新前台通知内容 (Android)
      if (service is AndroidServiceInstance) {
        service.setForegroundNotificationInfo(
          title: "FieldTrack is Active",
          content: "Speed: ${(position.speed * 3.6).toStringAsFixed(1)} km/h",
        );
      }
    } catch (e) {
      debugPrint("❌ [Background] Error processing location: $e");
    }
  });
}