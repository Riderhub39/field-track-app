import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'; // 🟢 引入 Riverpod
import 'notification_service.dart';

// 🟢 1. 定义全局 Riverpod Provider，替代旧的 Singleton 模式
final trackingProvider = NotifierProvider<TrackingNotifier, bool>(() {
  return TrackingNotifier();
});

// 🟢 2. 使用 Riverpod 的 Notifier 管理状态 (状态本身是一个 bool: isTracking)
class TrackingNotifier extends Notifier<bool> {
  StreamSubscription<Position>? _positionStream;
  String? _currentUserId;
  
  Position? _lastUploadedPosition;
  static const double _uploadDistanceFilter = 200.0;
  Timer? _autoStopTimer;

  // 📍 智能地理围栏 (Geofencing) 变量
  double? _officeLat;
  double? _officeLng;
  double _officeRadius = 500.0;
  bool? _wasInsideOffice; // 记录上次状态，用于判断是“进入”还是“离开”

  @override
  bool build() {
    return false; // 初始状态：未在追踪
  }

  /// 🔄 恢复会话 (App 启动时调用)
  Future<void> resumeTrackingSession(String authUid) async {
    try {
      final now = DateTime.now();
      final todayStr = DateFormat('yyyy-MM-dd').format(now);

      final q = await FirebaseFirestore.instance
          .collection('attendance')
          .where('uid', isEqualTo: authUid)
          .where('date', isEqualTo: todayStr)
          .get();

      if (q.docs.isNotEmpty) {
        final data = q.docs.first.data();
        if (data['clockIn'] != null && data['clockOut'] == null) {
          debugPrint("🔄 Resuming tracking session for $authUid");
          startTracking(authUid);
        }
      }
    } catch (e) {
      debugPrint("Error resuming tracking: $e");
    }
  }

  /// ▶️ 开始追踪 (包含权限验证与围栏初始化)
  Future<void> startTracking(String userId) async {
    if (state) return; // 如果已经在追踪，直接返回

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.whileInUse || permission == LocationPermission.always) {
      
      // 检查是否为司机
      try {
        final userQuery = await FirebaseFirestore.instance.collection('users').where('authUid', isEqualTo: userId).limit(1).get();

        if (userQuery.docs.isNotEmpty) {
          final userData = userQuery.docs.first.data();
          bool isDriver = userData['isDriver'] == true;

          if (!isDriver) {
            debugPrint("🚫 User is not setup as a Driver. Tracking skipped.");
            return; 
          }
        } else {
          return;
        }
      } catch (e) {
        return; 
      }

      // 🟢 获取公司办公区坐标，用于智能围栏
      await _fetchOfficeLocation();

      _currentUserId = userId;
      _lastUploadedPosition = null; 
      _wasInsideOffice = null; // 重置围栏状态
      
      final prefs = await SharedPreferences.getInstance();
      final bool shouldNotify = prefs.getBool('notifications_enabled') ?? true;
      
      if (shouldNotify) {
        await NotificationService().showTrackingNotification();
      }

      const LocationSettings locationSettings = LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10, 
      );

      _positionStream = Geolocator.getPositionStream(locationSettings: locationSettings)
          .listen((Position position) {
        _uploadLocationAndCheckGeofence(position); // 🟢 更新位置并检查围栏
      });

      state = true; // 🟢 Riverpod 触发状态更新，UI会自动响应
      _scheduleAutoStop(userId); 
      debugPrint("✅ Tracking Started (Driver Verified & Geofence Active)");
    } else {
      debugPrint("❌ Location permission denied");
    }
  }

  /// ⏹️ 停止追踪
  Future<void> stopTracking() async {
    await _positionStream?.cancel();
    _positionStream = null;
    _autoStopTimer?.cancel();
    _currentUserId = null;
    _lastUploadedPosition = null;
    _wasInsideOffice = null;
    
    state = false; // 🟢 Riverpod 触发状态更新
    
    await NotificationService().cancelTrackingNotification();
    debugPrint("🛑 Tracking Stopped");
  }

  /// 🏢 拉取公司坐标 (Geofencing)
  Future<void> _fetchOfficeLocation() async {
    try {
      final doc = await FirebaseFirestore.instance.collection('settings').doc('office_location').get();
      if (doc.exists) {
        final data = doc.data()!;
        _officeLat = (data['latitude'] as num?)?.toDouble();
        _officeLng = (data['longitude'] as num?)?.toDouble();
        _officeRadius = (data['radius'] as num?)?.toDouble() ?? 500.0;
        debugPrint("🏢 Office Geofence loaded: $_officeLat, $_officeLng (Radius: $_officeRadius m)");
      }
    } catch (e) {
      debugPrint("Error fetching office location for geofence: $e");
    }
  }

  /// ☁️ 核心逻辑：上传位置 + 地理围栏检测
  Future<void> _uploadLocationAndCheckGeofence(Position pos) async {
    if (_currentUserId == null) return;

    // 📍 1. 智能地理围栏检测 (Smart Geofencing)
    if (_officeLat != null && _officeLng != null) {
      double distanceToOffice = Geolocator.distanceBetween(
        pos.latitude, pos.longitude, _officeLat!, _officeLng!
      );

      bool isInside = distanceToOffice <= _officeRadius;

      if (_wasInsideOffice == false && isInside) {
        // 触发进入围栏提醒
        debugPrint("📍 User ENTERED geofence");
        NotificationService().showGeofenceAlert(
          "Welcome to the Office! 🏢", 
          "You have entered the work zone. Please remember to clock in."
        );
      } else if (_wasInsideOffice == true && !isInside) {
        // 触发离开围栏提醒
        debugPrint("📍 User EXITED geofence");
        NotificationService().showGeofenceAlert(
          "Leaving the Office? 🚗", 
          "You are leaving the work zone. Don't forget to clock out if your shift is over."
        );
      }
      _wasInsideOffice = isInside; // 更新状态
    }

    // ☁️ 2. 上传距离过滤 (200米才上传数据库，防扣费)
    if (_lastUploadedPosition != null) {
      double distanceMoved = Geolocator.distanceBetween(
        _lastUploadedPosition!.latitude, _lastUploadedPosition!.longitude,
        pos.latitude, pos.longitude,
      );
      if (distanceMoved < _uploadDistanceFilter) return; 
    }

    // 💾 3. 写入 Firebase
    final now = DateTime.now();
    final todayStr = DateFormat('yyyy-MM-dd').format(now);
    final batch = FirebaseFirestore.instance.batch();

    final logRef = FirebaseFirestore.instance.collection('tracking_logs').doc();
    batch.set(logRef, {
      'uid': _currentUserId,
      'lat': pos.latitude,
      'lng': pos.longitude,
      'speed': pos.speed, 
      'heading': pos.heading,
      'timestamp': FieldValue.serverTimestamp(),
      'date': todayStr,
    });

    final lastLocRef = FirebaseFirestore.instance.collection('user_last_locations').doc(_currentUserId);
    batch.set(lastLocRef, {
      'uid': _currentUserId,
      'lat': pos.latitude,
      'lng': pos.longitude,
      'speed': pos.speed,
      'timestamp': FieldValue.serverTimestamp(),
      'lastUpdate': now, 
    });

    try {
      await batch.commit();
      _lastUploadedPosition = pos;
    } catch (e) {
      debugPrint("Error uploading location: $e");
    }
  }

  /// ⏰ 智能自动停止逻辑
  Future<void> _scheduleAutoStop(String authUid) async {
    try {
      final now = DateTime.now();
      final todayStr = DateFormat('yyyy-MM-dd').format(now);

      final schedSnap = await FirebaseFirestore.instance.collection('schedules').where('date', isEqualTo: todayStr).get();

      var mySchedule = schedSnap.docs.where((doc) {
        return doc.data()['userId'] == authUid || doc.data()['userId'] == _currentUserId; 
      }).toList();

      DateTime? forceStopTime;

      if (mySchedule.isNotEmpty) {
        Timestamp endTs = mySchedule.first.data()['end']; 
        DateTime shiftEnd = endTs.toDate();
        forceStopTime = shiftEnd.add(const Duration(hours: 1)); // 下班后1小时自动关
      } else {
        forceStopTime = now.add(const Duration(hours: 12)); // 默认12小时
      }

      final duration = forceStopTime.difference(DateTime.now());

      if (duration.isNegative) {
        _autoStopTimer = Timer(const Duration(hours: 1), () {
            // Because we are inside a Notifier, we can call methods directly, but we can't access `ref` without passing it.
            // Since stopTracking just updates internal state and `state = false`, it's safe.
            stopTracking(); 
        });
      } else {
        _autoStopTimer = Timer(duration, stopTracking);
      }
    } catch (e) {
      debugPrint("Error scheduling auto-stop: $e");
    }
  }
}