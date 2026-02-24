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
  
  // 🟢 修改：上传距离过滤改为 150 米
  static const double _uploadDistanceFilter = 150.0;
  Timer? _autoStopTimer;

  double? _officeLat;
  double? _officeLng;
  double _officeRadius = 500.0;
  bool? _wasInsideOffice;

  // 🟢 用于持久化上一次上传坐标的 Key
  static const String _prefLastLat = 'tracking_last_lat';
  static const String _prefLastLng = 'tracking_last_lng';

  @override
  bool build() {
    return false;
  }

  /// 🔄 恢复会话 (App 启动时调用)
  Future<void> resumeTrackingSession(String authUid) async {
    await startTracking(authUid, isResume: true);
  }

  /// ▶️ 开始追踪 (增加了 isResume 标识来判断是否是断线重连)
  Future<void> startTracking(String userId, {bool isResume = false}) async {
    if (state) return; 

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.whileInUse || permission == LocationPermission.always) {
      
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
      _wasInsideOffice = null; 
      state = true; 

      final prefs = await SharedPreferences.getInstance();
      final bool shouldNotify = prefs.getBool('notifications_enabled') ?? true;
      if (shouldNotify) {
        await NotificationService().showTrackingNotification();
      }

      // 🟢 核心重构：判断初始点是否需要上传
      try {
        Position initialPos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
        );

        bool shouldForceUpload = true;

        if (isResume) {
          // 如果是断线重连/重启，尝试读取本地保存的上一次坐标
          final double? savedLat = prefs.getDouble(_prefLastLat);
          final double? savedLng = prefs.getDouble(_prefLastLng);

          if (savedLat != null && savedLng != null) {
            double distanceMoved = Geolocator.distanceBetween(
              savedLat, savedLng,
              initialPos.latitude, initialPos.longitude,
            );

            // 如果位移小于 150 米，说明还在原地，取消强制上传
            if (distanceMoved < _uploadDistanceFilter) {
              shouldForceUpload = false;
              
              // 顺便把旧坐标放回内存变量中，供后续的 Stream 过滤使用
              _lastUploadedPosition = Position(
                latitude: savedLat, longitude: savedLng,
                timestamp: DateTime.now(), accuracy: 0, altitude: 0, heading: 0, speed: 0, speedAccuracy: 0, altitudeAccuracy: 0, headingAccuracy: 0
              );
              
              debugPrint("📍 Reconnected. Position didn't change enough (<150m). Skipped initial log generation.");
            }
          }
        }

        if (shouldForceUpload) {
          await _uploadLocationAndCheckGeofence(initialPos, forceUpload: true);
          debugPrint("📍 Initial tracking point generated.");
        }

      } catch (e) {
        debugPrint("Could not get initial position: $e");
      }

      late LocationSettings locationSettings;

      if (defaultTargetPlatform == TargetPlatform.android) {
        locationSettings = AndroidSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 20, 
          forceLocationManager: true,
          // 🟢 核心：启动 Android 官方的前台服务 (Foreground Service)
          foregroundNotificationConfig: const ForegroundNotificationConfig(
            notificationText: "FieldTrack is recording your location in the background.",
            notificationTitle: "GPS Tracking Active",
            enableWakeLock: true, 
          ),
        );
      } else if (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.macOS) {
        locationSettings = AppleSettings(
          accuracy: LocationAccuracy.high,
          activityType: ActivityType.automotiveNavigation,
          distanceFilter: 20, 
          pauseLocationUpdatesAutomatically: false,
          showBackgroundLocationIndicator: true,
        );
      } else {
        locationSettings = const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 20, 
        );
      }

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

  /// ☁️ 核心逻辑：上传位置 + 地理围栏检测 + 保存到本地
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

    // ☁️ 距离过滤 (默认150米才上传)
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
      
      // 🟢 更新内存缓存
      _lastUploadedPosition = pos;
      
      // 🟢 核心：将成功上传的坐标持久化到本地 SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_prefLastLat, pos.latitude);
      await prefs.setDouble(_prefLastLng, pos.longitude);
      
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