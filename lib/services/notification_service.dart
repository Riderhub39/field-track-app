import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart'; 
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:firebase_messaging/firebase_messaging.dart'; 
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:shared_preferences/shared_preferences.dart'; 

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint("Handling a background message: ${message.messageId}");
}

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();
  final FirebaseMessaging _firebaseMessaging = FirebaseMessaging.instance; 

  static const int _trackingId = 888;
  static const int _shiftStartId = 101;

  static const String _trackingChannelId = 'tracking_channel';
  static const String _statusChannelId = 'status_updates'; 
  static const String _geofenceChannelId = 'geofence_channel'; 

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
          debugPrint("Notification clicked: ${response.payload}");
        },
      );
      
      final AndroidFlutterLocalNotificationsPlugin? androidImplementation =
          _notificationsPlugin.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      await androidImplementation?.requestNotificationsPermission();

      // ========================================
      // FCM Initialization
      // ========================================
      
      NotificationSettings fcmSettings = await _firebaseMessaging.requestPermission(
        alert: true, badge: true, sound: true, provisional: false,
      );
      debugPrint('User granted permission: ${fcmSettings.authorizationStatus}');

      
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        debugPrint('Got a message whilst in the foreground!');
        if (message.notification != null) {
          showStatusNotification(
            message.notification!.title ?? 'New Alert', 
            message.notification!.body ?? 'You have a new message'
          );
        }
      });

      FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

      _isInitialized = true;
      debugPrint("✅ NotificationService & FCM initialized successfully");
    } catch (e) {
      debugPrint("❌ Error initializing notifications: $e");
    }
  }

  Future<void> bindFCMToken(String uid) async {
    try {
      String? token = await _firebaseMessaging.getToken();
      if (token == null) return;
      
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
      importance: Importance.low, 
      priority: Priority.low,
      ongoing: true,      
      autoCancel: false,  
      showWhen: true,
      usesChronometer: true, 
      onlyAlertOnce: true,   
      icon: '@mipmap/ic_launcher', 
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
      styleInformation: BigTextStyleInformation(''), 
    );

    const NotificationDetails platformDetails = NotificationDetails(
      android: androidDetails,
      iOS: DarwinNotificationDetails(presentAlert: true, presentBadge: true, presentSound: true),
    );

    await _notificationsPlugin.show(
      999, 
      title,
      body,
      platformDetails,
    );
  }

  Future<void> showForgotClockOutAlert() async {
    if (!await _canShowNotification()) return;

    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      _geofenceChannelId,
      'Geofence Alerts',
      importance: Importance.max,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
      color: Colors.red,
      enableVibration: true,
      styleInformation: BigTextStyleInformation(''), 
    );

    const NotificationDetails platformDetails = NotificationDetails(
      android: androidDetails,
      iOS: DarwinNotificationDetails(presentAlert: true, presentBadge: true, presentSound: true),
    );

    await _notificationsPlugin.show(
      998, 
      '⚠️ ${'notif.shift_end_title'.tr()}', 
      'You have left the workplace after your shift. Did you forget to Clock Out?',
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
  // ⏰ Shift Reminders (Scheduled) - 🟢 已清空所有定时逻辑
  // =========================================================

  Future<void> scheduleShiftReminders(DateTime shiftStart, DateTime shiftEnd) async {
    // 🟢 这里不再放置任何逻辑，保持为空以防外部调用报错
  }

  Future<void> cancelAllReminders() async {
    await _notificationsPlugin.cancel(_shiftStartId);
  }
}