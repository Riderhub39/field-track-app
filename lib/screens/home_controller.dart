import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/tracking_service.dart';
import '../services/notification_service.dart';
import '../services/biometric_service.dart';
import '../services/auth_service.dart';

// ==========================================
// 1. 状态定义 (State)
// ==========================================
class HomeState {
  final String staffName;
  final String? faceIdPhotoPath;

  // 弹窗触发标志位
  final bool shouldShowLogoutDialog;
  final String logoutReason;
  final bool shouldShowAnnouncement;
  final Map<String, dynamic>? announcementData;
  final bool shouldShowBiometricPrompt;
  
  // 提示信息
  final String? successMessage;
  final String? errorMessage;

  HomeState({
    this.staffName = "Staff",
    this.faceIdPhotoPath,
    this.shouldShowLogoutDialog = false,
    this.logoutReason = "",
    this.shouldShowAnnouncement = false,
    this.announcementData,
    this.shouldShowBiometricPrompt = false,
    this.successMessage,
    this.errorMessage,
  });

  HomeState copyWith({
    String? staffName,
    String? faceIdPhotoPath,
    bool? shouldShowLogoutDialog,
    String? logoutReason,
    bool? shouldShowAnnouncement,
    Map<String, dynamic>? announcementData,
    bool? shouldShowBiometricPrompt,
    String? successMessage,
    String? errorMessage,
    bool clearMessages = false,
  }) {
    return HomeState(
      staffName: staffName ?? this.staffName,
      faceIdPhotoPath: faceIdPhotoPath ?? this.faceIdPhotoPath,
      shouldShowLogoutDialog: shouldShowLogoutDialog ?? this.shouldShowLogoutDialog,
      logoutReason: logoutReason ?? this.logoutReason,
      shouldShowAnnouncement: shouldShowAnnouncement ?? this.shouldShowAnnouncement,
      announcementData: announcementData ?? this.announcementData,
      shouldShowBiometricPrompt: shouldShowBiometricPrompt ?? this.shouldShowBiometricPrompt,
      successMessage: clearMessages ? null : (successMessage ?? this.successMessage),
      errorMessage: clearMessages ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

// ==========================================
// 2. 逻辑控制器 (Controller)
// ==========================================
// 🔴 CHANGED: 从 StateNotifier 迁移至 Notifier
class HomeNotifier extends Notifier<HomeState> {
  StreamSubscription? _announcementSubscription;
  StreamSubscription? _userStatusSubscription;
  StreamSubscription<bool>? _kickOutSubscription;

  // 🔴 CHANGED: 使用 build 方法初始化状态和逻辑
  @override
  HomeState build() {
    _initAll();
    
    // 🔴 CHANGED: 使用 ref.onDispose 处理流的取消，代替 override dispose()
    ref.onDispose(() {
      _announcementSubscription?.cancel();
      _userStatusSubscription?.cancel();
      _kickOutSubscription?.cancel();
    });

    return HomeState();
  }

  void _initAll() {
    _listenToUserStatus();
    _startDeviceMonitoring();
    _listenForAnnouncements();

    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      NotificationService().startListeningToUserUpdates(user.uid);
      _checkAndResumeTracking(user.uid);
    }

    Future.delayed(const Duration(seconds: 1), _checkBiometricSetup);
  }

  void clearMessages() {
    // 🔴 CHANGED: Notifier 中直接赋值 state 即可，去掉了 if(mounted)
    state = state.copyWith(clearMessages: true);
  }

  // --- 后台监听服务 ---
  void _startDeviceMonitoring() {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      _kickOutSubscription = AuthService().listenForDeviceKickOut(user.uid).listen((shouldKickOut) {
        if (shouldKickOut) {
          _kickOutSubscription?.cancel();
          _triggerForceLogout("kicked_out"); 
        }
      });
    }
  }

  void _listenToUserStatus() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    _userStatusSubscription = FirebaseFirestore.instance
        .collection('users')
        .where('authUid', isEqualTo: user.uid)
        .limit(1)
        .snapshots()
        .listen((snapshot) async {
      if (snapshot.docs.isNotEmpty) {
        final data = snapshot.docs.first.data();
        final status = data['status'] ?? 'active';

        if (status == 'disabled' || status == 'inactive') {
          _triggerForceLogout(status);
          return;
        }

        String sName = "Staff";
        final personal = data['personal'] as Map<String, dynamic>?;
        if (personal != null) {
          if (personal['shortName'] != null && personal['shortName'].toString().isNotEmpty) {
            sName = personal['shortName'];
          } else if (personal['name'] != null) {
            sName = personal['name'];
          }
          _cacheUserName(sName);
        }

        // 🔴 CHANGED: 直接更新 state
        state = state.copyWith(
          staffName: sName,
          faceIdPhotoPath: data['faceIdPhoto'],
        );
      } else {
        _triggerForceLogout('not_found');
      }
    }, onError: (error) {
      debugPrint("Error listening to user status: $error");
    });
  }

  void _triggerForceLogout(String reason) async {
    _userStatusSubscription?.cancel();
    _kickOutSubscription?.cancel();

    try {
      ref.read(trackingProvider.notifier).stopTracking();
    } catch (e) {
      debugPrint("Error stopping tracking on force logout: $e");
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();

    await FirebaseAuth.instance.signOut();

    // 🔴 CHANGED: 直接更新 state
    state = state.copyWith(
      shouldShowLogoutDialog: true,
      logoutReason: reason,
    );
  }

  void resetLogoutDialog() {
    state = state.copyWith(shouldShowLogoutDialog: false);
  }

  void _listenForAnnouncements() {
    _announcementSubscription = FirebaseFirestore.instance
        .collection('announcements')
        .orderBy('createdAt', descending: true)
        .limit(1)
        .snapshots()
        .listen((snapshot) async {
      if (snapshot.docs.isEmpty) return;

      final data = snapshot.docs.first.data();
      final String message = data['message'] ?? '';
      final Timestamp? createdAt = data['createdAt'];

      if (createdAt == null || message.isEmpty) return;

      final prefs = await SharedPreferences.getInstance();
      int? lastShownTime = prefs.getInt('last_announcement_time');

      if (lastShownTime == null) {
        lastShownTime = DateTime.now().millisecondsSinceEpoch;
        await prefs.setInt('last_announcement_time', lastShownTime);
        return;
      }

      if (createdAt.millisecondsSinceEpoch > lastShownTime) {
        await prefs.setInt('last_announcement_time', createdAt.millisecondsSinceEpoch);
        // 🔴 CHANGED: 直接更新 state
        state = state.copyWith(
          shouldShowAnnouncement: true,
          announcementData: data,
        );
      }
    });
  }

  void resetAnnouncementDialog() {
    state = state.copyWith(shouldShowAnnouncement: false);
  }

  Future<void> _checkBiometricSetup() async {
    final prefs = await SharedPreferences.getInstance();
    bool hasAsked = prefs.getBool('has_asked_biometrics') ?? false;
    bool isEnabled = prefs.getBool('biometric_enabled') ?? false;

    if (hasAsked || isEnabled) return;

    bool isHardwareSupported = await BiometricService().isDeviceSupported();
    if (!isHardwareSupported) return;

    state = state.copyWith(shouldShowBiometricPrompt: true);
  }

  void setBiometricLater() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('has_asked_biometrics', true);
    state = state.copyWith(shouldShowBiometricPrompt: false);
  }

  Future<void> enableBiometric() async {
    final prefs = await SharedPreferences.getInstance();
    state = state.copyWith(shouldShowBiometricPrompt: false);

    bool success = await BiometricService().authenticateStaff();
    if (success) {
      await prefs.setBool('biometric_enabled', true);
      await prefs.setBool('has_asked_biometrics', true);
      state = state.copyWith(successMessage: 'settings.biometric_on_msg');
    }
  }

  void _checkAndResumeTracking(String uid) {
    ref.read(trackingProvider.notifier).resumeTrackingSession(uid);
  }

  Future<void> _cacheUserName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('cached_staff_name', name);
  }

  // --- 更新头像 ---
  Future<void> uploadProfilePhoto(XFile photo) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      final String fileName = 'face_id_${user.uid}.jpg';
      final Reference storageRef = FirebaseStorage.instance
          .ref()
          .child('user_faces')
          .child(fileName);

      await storageRef.putFile(File(photo.path));
      final String downloadUrl = await storageRef.getDownloadURL();

      final q = await FirebaseFirestore.instance
          .collection('users')
          .where('authUid', isEqualTo: user.uid)
          .limit(1)
          .get();

      if (q.docs.isNotEmpty) {
        await q.docs.first.reference.update({
          'faceIdPhoto': downloadUrl,
          'hasFaceId': true,
          'lastFaceUpdate': FieldValue.serverTimestamp(),
        });

        state = state.copyWith(
          faceIdPhotoPath: downloadUrl,
          successMessage: 'profile.save_success',
        );
      }
    } catch (e) {
      debugPrint("Error updating photo: $e");
      state = state.copyWith(errorMessage: 'home.msg_upload_fail');
    }
  }
}

// 🔴 CHANGED: 暴露 Provider 使用 NotifierProvider 语法
final homeProvider = NotifierProvider<HomeNotifier, HomeState>(() {
  return HomeNotifier();
});