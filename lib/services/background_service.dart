import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
// 🚀 修复 1：隐藏 geolocator 中的 ActivityType，避免命名冲突
import 'package:geolocator/geolocator.dart' hide ActivityType; 
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:cloud_firestore/cloud_firestore.dart'; 
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart'; 
import 'package:flutter_activity_recognition/flutter_activity_recognition.dart'; 
import '../firebase_options.dart'; 
import 'local_db_service.dart';

Future<void> initializeBackgroundService() async {
  final service = FlutterBackgroundService();

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'tracking_channel', 
    'Working Hours Location Tracking', 
    description: 'This notifies you that your location is being shared with the admin in the background during working hours.', 
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

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  } catch (e) {
    debugPrint("Firebase already initialized or error: $e");
  }

  final prefs = await SharedPreferences.getInstance();
  String? userId = prefs.getString('current_tracking_uid');
  String? shiftEndTimeStr = prefs.getString('shift_end_time'); 
  
  if (userId == null) {
    service.stopSelf();
    return;
  }

  DateTime? shiftEndTime;
  if (shiftEndTimeStr != null) {
    shiftEndTime = DateTime.tryParse(shiftEndTimeStr);
  }

  // 1. Firebase 状态实时监听拦截 (Admin 操作拦截)
  final todayStr = DateFormat('yyyy-MM-dd').format(DateTime.now());
  FirebaseFirestore.instance
      .collection('attendance')
      .where('uid', isEqualTo: userId)
      .where('date', isEqualTo: todayStr)
      .snapshots()
      .listen((snapshot) async {
    if (snapshot.docs.isNotEmpty) {
      final docs = snapshot.docs.toList();
      docs.sort((a, b) => (a['timestamp'] as Timestamp).compareTo(b['timestamp'] as Timestamp));
      
      final lastSession = docs.last.data()['session'];
      final status = docs.last.data()['verificationStatus'];

      if ((lastSession == 'Clock Out' || lastSession == 'Break Out') && status != 'Rejected') {
        debugPrint("🛑 [Background] Detected Admin/User Clock/Break Out! Self-terminating...");
        await _performBackgroundBatchUpload(userId);
        service.stopSelf(); 
      }
    }
  });

  // 2. 后台 15 分钟批量上传 & 超时自杀定时器
  Timer.periodic(const Duration(minutes: 15), (timer) async {
    if (shiftEndTime != null && DateTime.now().isAfter(shiftEndTime)) {
      debugPrint("🛑 [Background] Shift time is over! Self-terminating from timer...");
      await _performBackgroundBatchUpload(userId);
      service.stopSelf();
      timer.cancel();
      return;
    }
    await _performBackgroundBatchUpload(userId);
  });

  // ==========================================
  // 🚀 核心优化：动态定位引擎 (防作弊 + 状态感知省电)
  // ==========================================
  StreamSubscription<Position>? positionSubscription;
  StreamSubscription<Activity>? activitySubscription;
  Position? lastLocalSavedPosition;

  // 动态启动/重启 GPS 监听的方法
  void startGpsStream(LocationAccuracy accuracy, int distanceFilter, String modeName) {
    positionSubscription?.cancel(); // 关掉旧的流
    debugPrint("🔄 GPS Engine Switched to: [$modeName] (Accuracy: $accuracy, Filter: ${distanceFilter}m)");

    positionSubscription = Geolocator.getPositionStream(
      locationSettings: LocationSettings(accuracy: accuracy, distanceFilter: distanceFilter),
    ).listen((Position position) async {
      
      // 🚨 优化 1：拦截“虚拟定位”防作弊 (Fake GPS)
      if (position.isMocked) {
        debugPrint("🚫 [Anti-Spoofing] Fake GPS Detected! Location ignored.");
        try {
          // 自动上报违规记录给 Admin
          FirebaseFirestore.instance.collection('tracking_violations').add({
            'uid': userId,
            'type': 'Fake GPS (Mock Location)',
            'timestamp': FieldValue.serverTimestamp(),
            'lat': position.latitude,
            'lng': position.longitude,
          });
        } catch(e) {
          // 🚀 修复 2：加入 debugPrint 避免空的 catch 块报警
          debugPrint("❌ Failed to log violation: $e");
        }
        return; // 直接踢掉，不存本地也不上传
      }

      // 拦截垃圾漂移点
      if (position.accuracy > 40.0) {
        debugPrint("🚫 GPS Drift Ignored: Poor accuracy (${position.accuracy}m)");
        return; 
      }

      double currentSpeedKmh = position.speed * 3.6;

      if (currentSpeedKmh > 0 && currentSpeedKmh < 5.0) {
      debugPrint("🚫 极低速原地漂移，忽略: ${currentSpeedKmh.toStringAsFixed(1)} km/h");
      return; 
    }

      if (shiftEndTime != null && DateTime.now().isAfter(shiftEndTime)) {
        await _performBackgroundBatchUpload(userId);
        service.stopSelf();
        return;
      }

      // 代码级存储距离过滤
      const double localDistanceFilter = 250.0; 
      if (lastLocalSavedPosition != null) {
        double distance = Geolocator.distanceBetween(
          lastLocalSavedPosition!.latitude, lastLocalSavedPosition!.longitude,
          position.latitude, position.longitude,
        );
        if (distance < localDistanceFilter) return; 
      }

      lastLocalSavedPosition = position;

      try {
        await LocalDbService().insertLocation(position.latitude, position.longitude);

        FirebaseDatabase.instance.ref("live_locations/$userId").update({
          'uid': userId,
          'lat': position.latitude,
          'lng': position.longitude,
          'speed': position.speed,
          'heading': position.heading,
          'lastUpdate': ServerValue.timestamp, 
          'isTracking': true,
          'currentMode': modeName, // 顺便把当前状态推给前端
        });
        
        if (service is AndroidServiceInstance) {
          service.setForegroundNotificationInfo(
            title: "FieldTrack Pro - Active",
            content: "Tracking ($modeName)", 
          );
        }
      } catch (e) {
        debugPrint("❌ Background Location Error: $e");
      }
    });
  }

  // 3. 初始启动：默认给予高精度模式和 50 米阈值
  startGpsStream(LocationAccuracy.high, 50, "Moving");

  // 🚨 优化 2：监听物理运动状态，动态调节功耗
  try {
    activitySubscription = FlutterActivityRecognition.instance.activityStream.listen((Activity activity) {
      debugPrint("🏃 Activity State Changed: ${activity.type}");
      
      if (activity.type == ActivityType.STILL) {
        // 状态【静止】：降低精度并放大过滤距离 (200m) 以极致省电
        startGpsStream(LocationAccuracy.low, 200, "Stationary");
        
      } else if (activity.type == ActivityType.IN_VEHICLE || 
                 activity.type == ActivityType.ON_BICYCLE || 
                 activity.type == ActivityType.RUNNING || 
                 activity.type == ActivityType.WALKING) {
        // 状态【移动】：瞬间恢复最高精度和 50 米过滤
        startGpsStream(LocationAccuracy.high, 50, "Moving");
      }
    });
  } catch (e) {
    debugPrint("❌ Activity Recognition failed to start: $e");
  }

  // 4. 确保服务关闭时销毁所有监听器
  service.on('stopService').listen((event) async {
    positionSubscription?.cancel();
    activitySubscription?.cancel();
    await _performBackgroundBatchUpload(userId);
    service.stopSelf();
  });
}

// 批量上传逻辑
Future<void> _performBackgroundBatchUpload(String userId) async {
  final List<Map<String, dynamic>> localPoints = await LocalDbService().getUnuploadedLocations();
  if (localPoints.isEmpty) return;

  debugPrint("📦 [Background] Batch Uploading ${localPoints.length} points to Firestore...");

  final now = DateTime.now();
  final todayStr = DateFormat('yyyy-MM-dd').format(now);
  final String batchDocId = "${userId}_${now.millisecondsSinceEpoch}";

  try {
    await FirebaseFirestore.instance.collection('tracking_batches').doc(batchDocId).set({
      'uid': userId,
      'date': todayStr,
      'uploadedAt': FieldValue.serverTimestamp(),
      'points': localPoints.map((p) => {
        'lat': p['latitude'],
        'lng': p['longitude'],
        'ts': p['timestamp'], 
      }).toList(),
    });

    final List<int> ids = localPoints.map((p) => p['id'] as int).toList();
    await LocalDbService().clearUploaded(ids);
    
    debugPrint("✅ [Background] Batch Upload Success");
  } catch (e) {
    debugPrint("❌ [Background] Batch Upload Failed: $e");
  }
}