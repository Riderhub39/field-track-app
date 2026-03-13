import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_background_service/flutter_background_service.dart'; 
import 'package:geolocator/geolocator.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'notification_service.dart';
import 'time_service.dart';
import 'package:firebase_database/firebase_database.dart';

final trackingProvider = NotifierProvider<TrackingNotifier, bool>(() {
  return TrackingNotifier();
});

class TrackingNotifier extends Notifier<bool> {
  String? _currentUserId;
  Timer? _autoStopTimer;

  @override
  bool build() {
    _initServiceState();
    return false;
  }

  Future<void> _initServiceState() async {
    final service = FlutterBackgroundService();
    if (await service.isRunning()) {
      final prefs = await SharedPreferences.getInstance();
      _currentUserId = prefs.getString('current_tracking_uid');
      if (_currentUserId != null) {
        state = true;
      }
    }
  }

  Future<void> resumeTrackingSession(String authUid) async {
    debugPrint("🔄 Attempting to resume tracking session for $authUid...");
    final now = TimeService.now;
    final todayStr = DateFormat('yyyy-MM-dd').format(now);
    
    try {
      final attQuery = await FirebaseFirestore.instance
          .collection('attendance')
          .where('uid', isEqualTo: authUid)
          .where('date', isEqualTo: todayStr)
          .get();

      if (attQuery.docs.isNotEmpty) {
        final validDocs = attQuery.docs.where((doc) {
          final status = doc.data()['verificationStatus'];
          return status != 'Rejected' && status != 'Archived';
        }).toList();

        if (validDocs.isNotEmpty) {
          validDocs.sort((a, b) => (a['timestamp'] as Timestamp).compareTo(b['timestamp'] as Timestamp));
          final lastSession = validDocs.last.data()['session'];

          if (lastSession == 'Clock In' || lastSession == 'Break In') {
            if (!state) {
              await startTracking(authUid, isResume: true);
            }

            try {
              LocationPermission permission = await Geolocator.checkPermission();
              if (permission == LocationPermission.whileInUse || permission == LocationPermission.always) {
                Position pos = await Geolocator.getCurrentPosition(
                  locationSettings: const LocationSettings(accuracy: LocationAccuracy.high)
                ).timeout(const Duration(seconds: 10));

                await FirebaseDatabase.instance.ref("live_locations/$authUid").update({
                  'uid': authUid,
                  'lat': pos.latitude,
                  'lng': pos.longitude,
                  'lastUpdate': ServerValue.timestamp,
                });
              }
            } catch (e) {
              debugPrint("❌ [App Resume] Location Push Failed: $e");
            }
            
          } else if (lastSession == 'Clock Out' || lastSession == 'Break Out') {
            await stopTracking();
          }
        }
      }
    } catch (e) {
      debugPrint("❌ Resume failed: $e");
    }
  }

  Future<void> startTracking(String userId, {bool isResume = false}) async {
    if (state && !isResume) return; 

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.whileInUse || permission == LocationPermission.always) {
      try {
        final userDocQuery = await FirebaseFirestore.instance.collection('users').where('authUid', isEqualTo: userId).limit(1).get();
        if (userDocQuery.docs.isEmpty) return;

        final userDoc = userDocQuery.docs.first;
        final data = userDoc.data();
        bool isDriver = data['isDriver'] == true || 
                        data['isDriver'] == 'true' || 
                        data['role']?.toString().toLowerCase() == 'driver';

        if (!isDriver) {
          debugPrint("🚫 User is not a driver. Tracking aborted.");
          return;
        }

        // 🚀 核心逻辑 1：获取员工排班表，判断是否超过下班时间
        final String myEmpCode = userDoc.id; // schedule 集合用的是这个 ID
        final now = TimeService.now;
        final todayStr = DateFormat('yyyy-MM-dd').format(now);
        
        final schedSnap = await FirebaseFirestore.instance.collection('schedules')
            .where('userId', isEqualTo: myEmpCode)
            .where('date', isEqualTo: todayStr)
            .get();

        DateTime shiftEndTime;
        if (schedSnap.docs.isNotEmpty) {
          final schedData = schedSnap.docs.first.data();
          if (schedData['end'] != null) {
            // 💡 设定：给 30 分钟的宽限期（考虑到轻微加班或下班路上还在回公司）
            // 如果你想严格准点关闭，把 minutes: 30 改成 0 即可。
            shiftEndTime = (schedData['end'] as Timestamp).toDate().add(const Duration(minutes: 30));
          } else {
            shiftEndTime = DateTime(now.year, now.month, now.day, 23, 59, 59);
          }
        } else {
          // 如果今天没有排班表，为了安全起见，默认当天 23:59:59 结束追踪
          shiftEndTime = DateTime(now.year, now.month, now.day, 23, 59, 59);
        }

        // 🚀 核心防御：如果当前时间已经超过了下班时间，直接拒绝启动追踪！
        if (now.isAfter(shiftEndTime)) {
          debugPrint("🚫 Shift time has passed. Tracking will not start.");
          return; 
        }

        _currentUserId = userId;
        state = true;

        // 存入缓存，供后台服务读取
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('current_tracking_uid', userId);
        await prefs.setString('shift_end_time', shiftEndTime.toIso8601String()); // 传递关闭时间给后台

        final service = FlutterBackgroundService();
        if (!(await service.isRunning())) {
          await service.startService();
        }

        // 设定前台定时器同步 UI
        _autoStopTimer?.cancel();
        _autoStopTimer = Timer(shiftEndTime.difference(now), stopTracking);

        debugPrint("🚀 Tracking Started (Auto-stop scheduled at $shiftEndTime)");
      } catch (e) {
        debugPrint("❌ Start tracking failed: $e");
      }
    }
  }

  Future<void> stopTracking() async {
    _autoStopTimer?.cancel();
    
    final service = FlutterBackgroundService();
    service.invoke('stopService');

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('current_tracking_uid');
    await prefs.remove('shift_end_time'); // 清除时间

    _currentUserId = null;
    state = false;
    await NotificationService().cancelTrackingNotification();
    debugPrint("🛑 Tracking Stopped");
  }
}