import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:cloud_firestore/cloud_firestore.dart'; 
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart'; 
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

  // 2. 后台 15 分钟批量上传 & 超时自杀定时器 (🚀 已修改为 15 分钟)
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

  service.on('stopService').listen((event) async {
    await _performBackgroundBatchUpload(userId);
    service.stopSelf();
  });

  const LocationSettings locationSettings = LocationSettings(
    accuracy: LocationAccuracy.high,
    distanceFilter: 10, 
  );

  Position? lastLocalSavedPosition;
  const double localDistanceFilter = 150.0; // 🚀 已修改为 150 米

  // 3. 启动不间断的位置监听
  Geolocator.getPositionStream(locationSettings: locationSettings).listen((Position position) async {
    
    if (shiftEndTime != null && DateTime.now().isAfter(shiftEndTime)) {
      debugPrint("🛑 [Background] Shift time is over! Self-terminating from GPS stream...");
      await _performBackgroundBatchUpload(userId);
      service.stopSelf();
      return;
    }

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
      });
      
      if (service is AndroidServiceInstance) {
        service.setForegroundNotificationInfo(
          title: "FieldTrack Pro - Active",
          content: "Your location is being updated in the background.", 
        );
      }
    } catch (e) {
      debugPrint("❌ Background Location Error: $e");
    }
  });
}

// 批量上传逻辑保持不变
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