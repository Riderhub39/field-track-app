import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_background_service/flutter_background_service.dart'; // 🟢 引入保活服务
import 'package:geolocator/geolocator.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'notification_service.dart';
import 'local_db_service.dart';
import 'time_service.dart';
final trackingProvider = NotifierProvider<TrackingNotifier, bool>(() {
  return TrackingNotifier();
});

class TrackingNotifier extends Notifier<bool> {
  String? _currentUserId;
  Timer? _batchUploadTimer;
  Timer? _autoStopTimer;

  static const Duration _uploadInterval = Duration(minutes: 15);

  @override
  bool build() {
    _initServiceState();
    return false;
  }

  // 🟢 App 重启时，检查后台服务是否还在运行，同步 UI 状态
  Future<void> _initServiceState() async {
    final service = FlutterBackgroundService();
    if (await service.isRunning()) {
      final prefs = await SharedPreferences.getInstance();
      _currentUserId = prefs.getString('current_tracking_uid');
      if (_currentUserId != null) {
        state = true;
        _startBatchUploadTimer();
      }
    }
  }

  // ==========================================
  // 1. 会话生命周期 (指挥官逻辑)
  // ==========================================

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

          if ((lastSession == 'Clock In' || lastSession == 'Break In') && !state) {
            await startTracking(authUid, isResume: true);
          } else if (state && (lastSession == 'Clock Out' || lastSession == 'Break Out')) {
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
        if (userDocQuery.docs.isEmpty || userDocQuery.docs.first.data()['isDriver'] != true) {
          debugPrint("🚫 User is not a driver.");
          return;
        }

        _currentUserId = userId;
        state = true;

        // 🟢 1. 存入 SharedPreferences，供后台 Isolate 读取
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('current_tracking_uid', userId);

        // 🟢 2. 发送指令：启动无坚不摧的后台服务！
        final service = FlutterBackgroundService();
        if (!(await service.isRunning())) {
          await service.startService();
        }

        // 🟢 3. 启动前台的定时批量上传
        _startBatchUploadTimer();
        _scheduleAutoStop(userId);

        debugPrint("🚀 Tracking Started (Background Isolate Activated)");
      } catch (e) {
        debugPrint("❌ Start tracking failed: $e");
      }
    }
  }

  Future<void> stopTracking() async {
    _batchUploadTimer?.cancel();
    _autoStopTimer?.cancel();
    
    // 🟢 1. 发送指令：停止后台服务
    final service = FlutterBackgroundService();
    service.invoke('stopService');

    // 🟢 2. 补传最后一段轨迹，清空本地 SQLite
    await _performBatchUpload();

    // 🟢 3. 清理缓存
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('current_tracking_uid');

    _currentUserId = null;
    state = false;
    await NotificationService().cancelTrackingNotification();
    debugPrint("🛑 Tracking Stopped");
  }

  // ==========================================
  // 2. 批量上传 (依然保留在前台进行打包)
  // ==========================================

  void _startBatchUploadTimer() {
    _batchUploadTimer?.cancel();
    _batchUploadTimer = Timer.periodic(_uploadInterval, (_) => _performBatchUpload());
  }

  Future<void> _performBatchUpload() async {
    if (_currentUserId == null) return;

    // 从本地 SQLite 读取这段时间积累的点
    final List<Map<String, dynamic>> localPoints = await LocalDbService().getUnuploadedLocations();
    if (localPoints.isEmpty) return;

    debugPrint("📦 Batch Uploading ${localPoints.length} points to Firestore...");

    final now = TimeService.now;
    final todayStr = DateFormat('yyyy-MM-dd').format(now);
    final String batchDocId = "${_currentUserId}_${now.millisecondsSinceEpoch}";

    try {
      await FirebaseFirestore.instance.collection('tracking_batches').doc(batchDocId).set({
        'uid': _currentUserId,
        'date': todayStr,
        'uploadedAt': FieldValue.serverTimestamp(),
        'points': localPoints.map((p) => {
          'lat': p['latitude'],
          'lng': p['longitude'],
          'ts': p['timestamp'],
        }).toList(),
      });

      // 成功后清理本地缓存
      final List<int> ids = localPoints.map((p) => p['id'] as int).toList();
      await LocalDbService().clearUploaded(ids);
      
      debugPrint("✅ Batch Upload Success");
    } catch (e) {
      debugPrint("❌ Batch Upload Failed: $e");
    }
  }

  // ==========================================
  // 3. 辅助函数
  // ==========================================

  Future<void> _scheduleAutoStop(String userId) async {
    final now = TimeService.now;
    final todayStr = DateFormat('yyyy-MM-dd').format(now);
    final schedSnap = await FirebaseFirestore.instance.collection('schedules').where('date', isEqualTo: todayStr).get();
    var mySchedule = schedSnap.docs.where((doc) => doc.data()['userId'] == userId).toList();

    DateTime stopAt = mySchedule.isNotEmpty 
      ? (mySchedule.first.data()['end'] as Timestamp).toDate().add(const Duration(hours: 1))
      : (TimeService.now).add(const Duration(hours: 12));

    _autoStopTimer?.cancel();
    _autoStopTimer = Timer(stopAt.difference(TimeService.now), stopTracking);
  }
}