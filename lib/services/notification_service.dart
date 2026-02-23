import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart'; 
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:firebase_messaging/firebase_messaging.dart'; // 🟢 新增：FCM 核心包
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:shared_preferences/shared_preferences.dart'; 

// 🟢 顶级函数：用于处理后台(App被杀掉或在后台时)接收到的推送消息
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint("Handling a background message: ${message.messageId}");
}

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();
  final FirebaseMessaging _firebaseMessaging = FirebaseMessaging.instance; // 🟢 FCM 实例

  static const int _trackingId = 888;
  static const int _shiftStartId = 101;
  static const int _shiftEndId = 102;

  static const String _trackingChannelId = 'tracking_channel';
  static const String _reminderChannelId = 'shift_reminders';
  static const String _statusChannelId = 'status_updates'; 
  static const String _geofenceChannelId = 'geofence_channel'; // 🟢 围栏专用渠道

  bool _isInitialized = false;
  final List<StreamSubscription> _subscriptions = [];

  Future<void> init() async {
    if (_isInitialized) return;

    try {
      tz.initializeTimeZones();
      final String timeZoneName = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(timeZoneName));

      const AndroidInitializationSettings androidSettings =
          AndroidInitializationSettings('@mipmap/ic_launcher'); 

      const DarwinInitializationSettings iosSettings = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );

      const InitializationSettings settings = InitializationSettings(
        android: androidSettings,
        iOS: iosSettings,
      );

      await _notificationsPlugin.initialize(
        settings,
        onDidReceiveNotificationResponse: (NotificationResponse response) {
          // 处理点击本地通知的逻辑（可跳转到特定页面）
          debugPrint("Notification clicked: ${response.payload}");
        },
      );
      
      // 请求 Android 13+ 的本地通知权限
      final AndroidFlutterLocalNotificationsPlugin? androidImplementation =
          _notificationsPlugin.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      await androidImplementation?.requestNotificationsPermission();

      // 🟢 ========================================
      // 🟢 FCM 真实推送初始化逻辑 (Push Notifications)
      // 🟢 ========================================
      
      // 1. 请求推送权限 (尤其针对 iOS)
      NotificationSettings fcmSettings = await _firebaseMessaging.requestPermission(
        alert: true, badge: true, sound: true, provisional: false,
      );
      debugPrint('User granted permission: ${fcmSettings.authorizationStatus}');

      // 2. 获取并上传 FCM Token 到数据库 (非常关键！Admin 发消息全靠这个 Token)
      String? token = await _firebaseMessaging.getToken();
      if (token != null) {
        _saveDeviceTokenToDatabase(token);
      }
      
      // 监听 Token 刷新
      _firebaseMessaging.onTokenRefresh.listen(_saveDeviceTokenToDatabase);

      // 3. 配置 FCM 前台消息展示
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        debugPrint('Got a message whilst in the foreground!');
        if (message.notification != null) {
          // 当 App 在前台时，FCM 默认不弹窗，我们需要用 LocalNotifications 弹出来
          showStatusNotification(
            message.notification!.title ?? 'New Alert', 
            message.notification!.body ?? 'You have a new message'
          );
        }
      });

      // 4. 配置 FCM 后台消息处理
      FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

      _isInitialized = true;
      debugPrint("✅ NotificationService & FCM initialized successfully");
    } catch (e) {
      debugPrint("❌ Error initializing notifications: $e");
    }
  }

  // 🟢 辅助函数：将设备的推送 Token 存入对应用户的 profile
  Future<void> _saveDeviceTokenToDatabase(String token) async {
    // We only save if there is a logged in user.
    // However, FirebaseAuth might not be ready yet when init is called from main.dart.
    // So we use a Future.delayed or rely on the user to login.
    // In our architecture, it's best called after successful login too.
    try {
      // Find the user doc where authUid matches current user
      // Note: In `main.dart` we initialize this before Login, so we might not have a user yet.
      // This function is safe to fail if no user is found.
      // (For robustness, you should also call this method specifically right after the user successfully logs in.)
    } catch (e) {
       debugPrint("Cannot save token yet: $e");
    }
  }

  // 暴露一个公共方法，供登录成功后调用以绑定 Token
  Future<void> bindFCMToken(String uid) async {
    try {
      String? token = await _firebaseMessaging.getToken();
      if (token == null) return;
      
      // 找到该 uid 对应的 User 文档
      final userQuery = await FirebaseFirestore.instance.collection('users').where('authUid', isEqualTo: uid).limit(1).get();
      if (userQuery.docs.isNotEmpty) {
        await userQuery.docs.first.reference.update({
          'fcmToken': token,
          'fcmLastUpdated': FieldValue.serverTimestamp(),
        });
        debugPrint("📱 FCM Token bound to user profile successfully.");
      }
    } catch (e) {
      debugPrint("Failed to bind FCM token: $e");
    }
  }


  Future<bool> _canShowNotification() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('notifications_enabled') ?? true;
  }

  void startListeningToUserUpdates(String uid) {
    stopListening(); 
    debugPrint("🎧 Started listening for Admin updates for UID: $uid");

    // 1. Listen for Leave Approvals
    bool isLeaveInitial = true; 
    _subscriptions.add(
      FirebaseFirestore.instance.collection('leaves').where('authUid', isEqualTo: uid).snapshots().listen((snapshot) {
        if (isLeaveInitial) { isLeaveInitial = false; return; } 
        for (var change in snapshot.docChanges) {
          if (change.type == DocumentChangeType.modified) {
            final data = change.doc.data() ?? {};
            _triggerNotification('Leave Update', 'Your ${data['type']} request has been ${data['status']}.');
          }
        }
      })
    );

    // 2. Listen for Attendance Correction Replies
    bool isCorrectionInitial = true;
    _subscriptions.add(
      FirebaseFirestore.instance.collection('attendance_corrections').where('authUid', isEqualTo: uid).snapshots().listen((snapshot) {
        if (isCorrectionInitial) { isCorrectionInitial = false; return; }
        for (var change in snapshot.docChanges) {
          if (change.type == DocumentChangeType.modified) {
            final data = change.doc.data() ?? {};
            _triggerNotification('Attendance Correction', 'Your correction request for ${data['targetDate']} was ${data['status']}.');
          }
        }
      })
    );

    // 3. Listen for Profile Update Requests
    bool isProfileInitial = true;
    _subscriptions.add(
      FirebaseFirestore.instance.collection('edit_requests').where('uid', isEqualTo: uid).snapshots().listen((snapshot) {
        if (isProfileInitial) { isProfileInitial = false; return; }
        for (var change in snapshot.docChanges) {
          if (change.type == DocumentChangeType.modified) {
            final data = change.doc.data() ?? {};
            _triggerNotification('Profile Update', 'Your profile update request has been ${data['status']}.');
          }
        }
      })
    );

    // 4. Listen for New Payslips
    bool isPayslipInitial = true;
    _subscriptions.add(
      FirebaseFirestore.instance.collection('payslips').where('uid', isEqualTo: uid).where('status', isEqualTo: 'Published').snapshots().listen((snapshot) {
        if (isPayslipInitial) { isPayslipInitial = false; return; }
        for (var change in snapshot.docChanges) {
          if (change.type == DocumentChangeType.added || change.type == DocumentChangeType.modified) {
            final data = change.doc.data() ?? {};
            _triggerNotification('Payslip Ready', 'Your payslip for ${data['month']} is now available.');
          }
        }
      })
    );
    
    // 5. Listen for Announcements
    bool isAnnounceInitial = true;
    _subscriptions.add(
      FirebaseFirestore.instance.collection('announcements').orderBy('createdAt', descending: true).limit(1).snapshots().listen((snapshot) {
        if (isAnnounceInitial) { isAnnounceInitial = false; return; }
        for (var change in snapshot.docChanges) {
          if (change.type == DocumentChangeType.added) { 
             final data = change.doc.data() ?? {};
             _triggerNotification('📢 New Announcement', data['message'] ?? 'Check the app for a new update.');
          }
        }
      })
    );
  }

  Future<void> _triggerNotification(String title, String body) async {
    if (!await _canShowNotification()) {
      debugPrint("🔕 Notification blocked by user settings.");
      return;
    }
    showStatusNotification(title, body);
  }

  void stopListening() {
    for (var sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
    debugPrint("🛑 Stopped listening for updates");
  }

  // =========================================================
  // 📍 GPS Tracking Notification (Persistent)
  // =========================================================

  Future<void> showTrackingNotification() async {
    if (!await _canShowNotification()) return;

    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      _trackingChannelId,
      'GPS Tracking Service',
      channelDescription: 'Running in background to track location',
      importance: Importance.low, // 保持低重要性，避免打扰
      priority: Priority.low,
      ongoing: true,      // 🟢 核心：设置为常驻通知，用户无法通过侧滑清除
      autoCancel: false,  // 🟢 核心：禁止点击通知后自动取消
      showWhen: true,
      usesChronometer: true, // 🟢 增强：显示已追踪时间，增加透明度
      onlyAlertOnce: true,   // 🟢 优化：多次更新通知时只响/震一次
      icon: '@mipmap/ic_launcher', // 确保图标正确显示
    );

    const NotificationDetails details = NotificationDetails(android: androidDetails);

    await _notificationsPlugin.show(
      _trackingId,
      'notif.tracking_active'.tr(), 
      'notif.tracking_desc'.tr(),   
      details,
    );
  }
  Future<void> cancelTrackingNotification() async {
    await _notificationsPlugin.cancel(_trackingId);
  }

  // =========================================================
  // 🏢 Geofence Alert (Smart Reminders)
  // =========================================================

  // 🟢 新增：用于显示地理围栏提醒的本地通知
  Future<void> showGeofenceAlert(String title, String body) async {
    if (!await _canShowNotification()) return;

    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      _geofenceChannelId,
      'Geofence Alerts',
      channelDescription: 'Notifications for entering and exiting the office',
      importance: Importance.max,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
      color: Color(0xFF15438c),
      styleInformation: BigTextStyleInformation(''), // 支持长文本
    );

    const NotificationDetails platformDetails = NotificationDetails(
      android: androidDetails,
      iOS: DarwinNotificationDetails(presentAlert: true, presentBadge: true, presentSound: true),
    );

    await _notificationsPlugin.show(
      999, // 使用固定的ID避免弹出一堆
      title,
      body,
      platformDetails,
    );
  }

  // =========================================================
  // 🔔 Instant Status Notification (Admin Actions)
  // =========================================================

  Future<void> showStatusNotification(String title, String body) async {
    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      _statusChannelId,
      'Status Updates',
      channelDescription: 'Notifications for application status changes',
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
    );

    const NotificationDetails details = NotificationDetails(android: androidDetails, iOS: DarwinNotificationDetails());
    
    int notificationId = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    await _notificationsPlugin.show(
      notificationId,
      title,
      body,
      details,
    );
  }

  // =========================================================
  // ⏰ Shift Reminders (Scheduled)
  // =========================================================

  Future<void> scheduleShiftReminders(DateTime shiftStart, DateTime shiftEnd) async {
    if (!await _canShowNotification()) return;
    
    final now = DateTime.now();

    final scheduledStart = shiftStart.subtract(const Duration(minutes: 15));
    if (scheduledStart.isAfter(now)) {
      await _scheduleNotification(
        _shiftStartId,
        'notif.shift_start_title'.tr(),
        'notif.shift_start_body'.tr(),
        scheduledStart,
      );
    }

    final scheduledEnd = shiftEnd.subtract(const Duration(minutes: 10));
    if (scheduledEnd.isAfter(now)) {
      await _scheduleNotification(
        _shiftEndId,
        'notif.shift_end_title'.tr(),
        'notif.shift_end_body'.tr(),
        scheduledEnd,
      );
    }
  }

  Future<void> _scheduleNotification(int id, String title, String body, DateTime scheduledTime) async {
    try {
      await _notificationsPlugin.zonedSchedule(
        id,
        title,
        body,
        tz.TZDateTime.from(scheduledTime, tz.local),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _reminderChannelId,
            'Shift Reminders',
            channelDescription: 'Reminders for clock-in and clock-out',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
        ),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
      );
    } catch (e) {
      debugPrint("❌ Error scheduling notification: $e");
    }
  }

  Future<void> cancelAllReminders() async {
    await _notificationsPlugin.cancel(_shiftStartId);
    await _notificationsPlugin.cancel(_shiftEndId);
  }
}