import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'notification_service.dart';

final trackingProvider = NotifierProvider<TrackingNotifier, bool>(() {
  return TrackingNotifier();
});

class TrackingNotifier extends Notifier<bool> {
  StreamSubscription<Position>? _positionStream;
  String? _currentUserId;
  
  Position? _lastUploadedPosition;
  static const double _uploadDistanceFilter = 200.0;
  Timer? _autoStopTimer;

  double? _officeLat;
  double? _officeLng;
  double _officeRadius = 500.0;
  bool? _wasInsideOffice;

  @override
  bool build() {
    return false;
  }

  /// 🔄 恢复会话 (App 启动时调用)
  Future<void> resumeTrackingSession(String authUid) async {
    // 复用增强后的 startTracking 逻辑，因为它自带了状态检查
    await startTracking(authUid);
  }

  /// ▶️ 开始追踪 (包含权限验证、防漏追踪、初始点生成)
  Future<void> startTracking(String userId) async {
    if (state) return; 

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.whileInUse || permission == LocationPermission.always) {
      
      try {
        // 1. 检查是否为司机
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

        // 🟢 2. 终极安全网：检查今天最后一次打卡状态
        final now = DateTime.now();
        final todayStr = DateFormat('yyyy-MM-dd').format(now);
        final attQuery = await FirebaseFirestore.instance
            .collection('attendance')
            .where('uid', isEqualTo: userId)
            .where('date', isEqualTo: todayStr)
            .get();

        if (attQuery.docs.isNotEmpty) {
          final docs = attQuery.docs;
          docs.sort((a, b) => (a['timestamp'] as Timestamp).compareTo(b['timestamp'] as Timestamp));
          final lastRecord = docs.last.data();
          final lastSession = lastRecord['session'];

          // 如果最后一次动作是下班或外出，则坚决不追踪
          if (lastSession == 'Clock Out' || lastSession == 'Break Out') {
            debugPrint("🚫 User is currently Clocked Out or Break Out. Tracking aborted.");
            return;
          }
        }
      } catch (e) {
        debugPrint("Tracking verification failed: $e");
        return; 
      }

      await _fetchOfficeLocation();

      _currentUserId = userId;
      _lastUploadedPosition = null; 
      _wasInsideOffice = null; 
      state = true; // 状态置为正在追踪

      final prefs = await SharedPreferences.getInstance();
      final bool shouldNotify = prefs.getBool('notifications_enabled') ?? true;
      if (shouldNotify) {
        await NotificationService().showTrackingNotification();
      }

      // 🟢 3. 初始破冰点 (Initial Point): 解决一直不移动导致的流不触发问题
      try {
        Position initialPos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
        );
        await _uploadLocationAndCheckGeofence(initialPos, forceUpload: true);
        debugPrint("📍 Initial tracking point generated.");
      } catch (e) {
        debugPrint("Could not get initial position: $e");
      }

      const LocationSettings locationSettings = LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10, // 这里的距离过滤器只是为了让Stream少触发，真正的上传防抖在 _uploadLocationAndCheckGeofence 里
      );

      _positionStream = Geolocator.getPositionStream(locationSettings: locationSettings)
          .listen((Position position) {
        _uploadLocationAndCheckGeofence(position); 
      });

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
    
    state = false; 
    
    await NotificationService().cancelTrackingNotification();
    debugPrint("🛑 Tracking Stopped");
  }

  /// 🏢 拉取公司坐标
  Future<void> _fetchOfficeLocation() async {
    try {
      final doc = await FirebaseFirestore.instance.collection('settings').doc('office_location').get();
      if (doc.exists) {
        final data = doc.data()!;
        _officeLat = (data['latitude'] as num?)?.toDouble();
        _officeLng = (data['longitude'] as num?)?.toDouble();
        _officeRadius = (data['radius'] as num?)?.toDouble() ?? 500.0;
      }
    } catch (e) {
      debugPrint("Error fetching office location: $e");
    }
  }

  /// ☁️ 核心逻辑：上传位置 + 地理围栏检测
  /// 增加 `forceUpload` 参数，用于强制写入初始坐标
  Future<void> _uploadLocationAndCheckGeofence(Position pos, {bool forceUpload = false}) async {
    if (_currentUserId == null) return;

    if (_officeLat != null && _officeLng != null) {
      double distanceToOffice = Geolocator.distanceBetween(
        pos.latitude, pos.longitude, _officeLat!, _officeLng!
      );

      bool isInside = distanceToOffice <= _officeRadius;

      if (_wasInsideOffice == false && isInside) {
        NotificationService().showGeofenceAlert(
          "Welcome to the Office! 🏢", 
          "You have entered the work zone. Please remember to clock in."
        );
      } else if (_wasInsideOffice == true && !isInside) {
        NotificationService().showGeofenceAlert(
          "Leaving the Office? 🚗", 
          "You are leaving the work zone. Don't forget to clock out if your shift is over."
        );
      }
      _wasInsideOffice = isInside; 
    }

    // ☁️ 距离过滤 (默认200米才上传)
    if (!forceUpload && _lastUploadedPosition != null) {
      double distanceMoved = Geolocator.distanceBetween(
        _lastUploadedPosition!.latitude, _lastUploadedPosition!.longitude,
        pos.latitude, pos.longitude,
      );
      if (distanceMoved < _uploadDistanceFilter) return; 
    }

    // 💾 写入 Firebase
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
        forceStopTime = shiftEnd.add(const Duration(hours: 1)); 
      } else {
        forceStopTime = now.add(const Duration(hours: 12)); 
      }

      final duration = forceStopTime.difference(DateTime.now());

      if (duration.isNegative) {
        _autoStopTimer = Timer(const Duration(hours: 1), stopTracking);
      } else {
        _autoStopTimer = Timer(duration, stopTracking);
      }
    } catch (e) {
      debugPrint("Error scheduling auto-stop: $e");
    }
  }
}