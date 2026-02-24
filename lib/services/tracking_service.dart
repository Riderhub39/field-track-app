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
  static const double _uploadDistanceFilter = 150.0;
  Timer? _autoStopTimer;

  double? _officeLat;
  double? _officeLng;
  double _officeRadius = 500.0;
  bool? _wasInsideOffice;

  static const String _prefLastLat = 'tracking_last_lat';
  static const String _prefLastLng = 'tracking_last_lng';

  @override
  bool build() {
    return false;
  }

  /// 🔄 恢复会话 (App 启动时由 main.dart 或首页调用)
  Future<void> resumeTrackingSession(String authUid) async {
    debugPrint("🔄 Attempting to resume tracking session for $authUid...");
    
    final now = DateTime.now();
    final todayStr = DateFormat('yyyy-MM-dd').format(now);
    
    try {
      final attQuery = await FirebaseFirestore.instance
          .collection('attendance')
          .where('uid', isEqualTo: authUid)
          .where('date', isEqualTo: todayStr)
          .get();

      if (attQuery.docs.isNotEmpty) {
        // 🟢 核心修改：过滤掉所有被管理员拒绝的打卡记录
        final validDocs = attQuery.docs.where((doc) {
          final status = doc.data()['verificationStatus'];
          return status != 'Rejected' && status != 'Archived';
        }).toList();

        if (validDocs.isNotEmpty) {
          // 按时间排序找最后一条“有效”记录
          validDocs.sort((a, b) => (a['timestamp'] as Timestamp).compareTo(b['timestamp'] as Timestamp));
          final lastSession = validDocs.last.data()['session'];

          debugPrint("📍 Latest Valid State: $lastSession");

          // 如果最后状态是上班中，且当前未在追踪，则强制恢复
          if ((lastSession == 'Clock In' || lastSession == 'Break In') && !state) {
            debugPrint("✅ Resuming tracking because status is $lastSession");
            await startTracking(authUid, isResume: true);
          } else if (state && (lastSession == 'Clock Out' || lastSession == 'Break Out')) {
            // 如果最后有效状态是下班/休息，但追踪还在跑（比如刚刚被Reject），则停止
            debugPrint("🛑 Suspending tracking because status is $lastSession");
            await stopTracking();
          }
        }
      }
    } catch (e) {
      debugPrint("❌ Failed to resume session: $e");
    }
  }

  /// ▶️ 开始追踪
  Future<void> startTracking(String userId, {bool isResume = false}) async {
    if (state && !isResume) return; 

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.whileInUse || permission == LocationPermission.always) {
      
      try {
        final userQuery = await FirebaseFirestore.instance.collection('users').where('authUid', isEqualTo: userId).limit(1).get();

        if (userQuery.docs.isNotEmpty) {
          final userData = userQuery.docs.first.data();
          if (userData['isDriver'] != true) {
            debugPrint("🚫 User is not a Driver.");
            return; 
          }
        } else { return; }

        // 二次验证状态（排除 Rejected）
        final now = DateTime.now();
        final todayStr = DateFormat('yyyy-MM-dd').format(now);
        final attQuery = await FirebaseFirestore.instance
            .collection('attendance')
            .where('uid', isEqualTo: userId)
            .where('date', isEqualTo: todayStr)
            .get();

        if (attQuery.docs.isNotEmpty) {
          // 🟢 同样过滤掉被拒绝的记录
          final validDocs = attQuery.docs.where((doc) {
            final status = doc.data()['verificationStatus'];
            return status != 'Rejected' && status != 'Archived';
          }).toList();

          if (validDocs.isNotEmpty) {
            validDocs.sort((a, b) => (a['timestamp'] as Timestamp).compareTo(b['timestamp'] as Timestamp));
            final lastSession = validDocs.last.data()['session'];

            if (lastSession == 'Clock Out' || lastSession == 'Break Out') {
              debugPrint("🚫 Invalid state for tracking: $lastSession");
              if (state) stopTracking();
              return;
            }
          }
        }
      } catch (e) {
        debugPrint("Verification failed: $e");
        return; 
      }

      await _fetchOfficeLocation();

      _currentUserId = userId;
      _wasInsideOffice = null; 
      state = true; 

      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('notifications_enabled') ?? true) {
        await NotificationService().showTrackingNotification();
      }

      try {
        Position initialPos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
        );

        bool shouldForceUpload = true;

        if (isResume) {
          final double? savedLat = prefs.getDouble(_prefLastLat);
          final double? savedLng = prefs.getDouble(_prefLastLng);

          if (savedLat != null && savedLng != null) {
            double distanceMoved = Geolocator.distanceBetween(
              savedLat, savedLng,
              initialPos.latitude, initialPos.longitude,
            );

            if (distanceMoved < _uploadDistanceFilter) {
              shouldForceUpload = false;
              _lastUploadedPosition = Position(
                latitude: savedLat, longitude: savedLng,
                timestamp: DateTime.now(), accuracy: 0, altitude: 0, heading: 0, speed: 0, speedAccuracy: 0, altitudeAccuracy: 0, headingAccuracy: 0
              );
              debugPrint("📍 Position stable (<150m).");
            }
          }
        }

        if (shouldForceUpload) {
          await _uploadLocationAndCheckGeofence(initialPos, forceUpload: true);
        }

      } catch (e) {
        debugPrint("Initial POS failed: $e");
      }

      late LocationSettings locationSettings;
      if (defaultTargetPlatform == TargetPlatform.android) {
        locationSettings = AndroidSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 20, 
          forceLocationManager: true,
          foregroundNotificationConfig: const ForegroundNotificationConfig(
            notificationText: "FieldTrack is recording your location in the background.",
            notificationTitle: "GPS Tracking Active",
            enableWakeLock: true, 
          ),
        );
      } else if (defaultTargetPlatform == TargetPlatform.iOS) {
        locationSettings = AppleSettings(
          accuracy: LocationAccuracy.high,
          activityType: ActivityType.automotiveNavigation,
          distanceFilter: 20,
          pauseLocationUpdatesAutomatically: false,
          showBackgroundLocationIndicator: true,
        );
      } else {
        locationSettings = const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 20);
      }

      _positionStream = Geolocator.getPositionStream(locationSettings: locationSettings)
          .listen((Position position) {
        _uploadLocationAndCheckGeofence(position); 
      });

      _scheduleAutoStop(userId); 
    }
  }

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
      debugPrint("Office Loc Error: $e");
    }
  }

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
        _checkIfForgotClockOut(); 
        NotificationService().showGeofenceAlert(
          "Leaving the Office? 🚗", 
          "You are leaving the work zone. Don't forget to clock out if your shift is over."
        );
      }
      _wasInsideOffice = isInside; 
    }

    if (!forceUpload && _lastUploadedPosition != null) {
      double distanceMoved = Geolocator.distanceBetween(
        _lastUploadedPosition!.latitude, _lastUploadedPosition!.longitude,
        pos.latitude, pos.longitude,
      );
      if (distanceMoved < _uploadDistanceFilter) return; 
    }

    final now = DateTime.now();
    final todayStr = DateFormat('yyyy-MM-dd').format(now);
    final batch = FirebaseFirestore.instance.batch();

    batch.set(FirebaseFirestore.instance.collection('tracking_logs').doc(), {
      'uid': _currentUserId,
      'lat': pos.latitude,
      'lng': pos.longitude,
      'speed': pos.speed, 
      'heading': pos.heading,
      'timestamp': FieldValue.serverTimestamp(),
      'date': todayStr,
    });

    batch.set(FirebaseFirestore.instance.collection('user_last_locations').doc(_currentUserId), {
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
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_prefLastLat, pos.latitude);
      await prefs.setDouble(_prefLastLng, pos.longitude);
    } catch (e) {
      debugPrint("Firebase Upload Error: $e");
    }
  }

  Future<void> _checkIfForgotClockOut() async {
    if (_currentUserId == null) return;
    try {
      final now = DateTime.now();
      final todayStr = DateFormat('yyyy-MM-dd').format(now);
      final schedSnap = await FirebaseFirestore.instance
          .collection('schedules')
          .where('userId', isEqualTo: _currentUserId)
          .where('date', isEqualTo: todayStr)
          .limit(1)
          .get();

      if (schedSnap.docs.isNotEmpty) {
        final shiftEnd = (schedSnap.docs.first.data()['end'] as Timestamp).toDate();
        if (now.isAfter(shiftEnd)) {
           await NotificationService().showForgotClockOutAlert();
        }
      }
    } catch (e) {
      debugPrint("Forgot check failed: $e");
    }
  }

  Future<void> _scheduleAutoStop(String authUid) async {
    try {
      final now = DateTime.now();
      final todayStr = DateFormat('yyyy-MM-dd').format(now);
      final schedSnap = await FirebaseFirestore.instance.collection('schedules').where('date', isEqualTo: todayStr).get();
      var mySchedule = schedSnap.docs.where((doc) => doc.data()['userId'] == authUid || doc.data()['userId'] == _currentUserId).toList();

      DateTime? forceStopTime;
      if (mySchedule.isNotEmpty) {
        Timestamp endTs = mySchedule.first.data()['end']; 
        forceStopTime = endTs.toDate().add(const Duration(hours: 1)); 
      } else {
        forceStopTime = now.add(const Duration(hours: 12)); 
      }

      final duration = forceStopTime.difference(DateTime.now());
      _autoStopTimer?.cancel();
      _autoStopTimer = Timer(duration.isNegative ? const Duration(hours: 1) : duration, stopTracking);
    } catch (e) {
      debugPrint("Auto-stop timer error: $e");
    }
  }
}