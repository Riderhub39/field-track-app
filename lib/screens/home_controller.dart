// home_controller.dart

import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart'; 
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart'; 
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

  final bool shouldShowLogoutDialog;
  final String logoutReason;
  final bool shouldShowAnnouncement;
  final Map<String, dynamic>? announcementData;
  final bool shouldShowBiometricPrompt;
  
  final bool shouldShowUpdatePrompt;
  final String? updateLatestVersion;
  final String? updateReleaseNotes;
  final String? updateApkUrl;
  final bool forceUpdate;

  // --- 提示信息 ---
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
    
    this.shouldShowUpdatePrompt = false,
    this.updateLatestVersion,
    this.updateReleaseNotes,
    this.updateApkUrl,
    this.forceUpdate = false,

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
    
    bool? shouldShowUpdatePrompt,
    String? updateLatestVersion,
    String? updateReleaseNotes,
    String? updateApkUrl,
    bool? forceUpdate,

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
      
      shouldShowUpdatePrompt: shouldShowUpdatePrompt ?? this.shouldShowUpdatePrompt,
      updateLatestVersion: updateLatestVersion ?? this.updateLatestVersion,
      updateReleaseNotes: updateReleaseNotes ?? this.updateReleaseNotes,
      updateApkUrl: updateApkUrl ?? this.updateApkUrl,
      forceUpdate: forceUpdate ?? this.forceUpdate,

      successMessage: clearMessages ? null : (successMessage ?? this.successMessage),
      errorMessage: clearMessages ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

// ==========================================
// 2. 逻辑控制器 (Controller)
// ==========================================
class HomeNotifier extends Notifier<HomeState> {
  StreamSubscription? _announcementSubscription;
  StreamSubscription? _userStatusSubscription;
  StreamSubscription<bool>? _kickOutSubscription;

  @override
  HomeState build() {
    _initAll();
    
    ref.onDispose(() {
      _announcementSubscription?.cancel();
      _userStatusSubscription?.cancel();
      _kickOutSubscription?.cancel();
    });

    return HomeState();
  }

  void _initAll() async {
    // 1. 静默检查更新
    _checkForUpdates(); 
    
    // 2. 启动实时监听
    _listenToUserStatus();
    _startDeviceMonitoring();
    _listenForAnnouncements();

    // 3. 恢复用户状态与后台服务
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      NotificationService().startListeningToUserUpdates(user.uid);
      _checkAndResumeTracking(user.uid);
    }

    // 4. 延迟检查生物识别
    Future.delayed(const Duration(seconds: 1), _checkBiometricSetup);
  }

  // ==========================================
  // 🟢 模块：版本更新检查
  // ==========================================
  Future<void> _checkForUpdates() async {
    try {
      PackageInfo packageInfo = await PackageInfo.fromPlatform();
      String currentVersion = packageInfo.version;

      DocumentSnapshot doc = await FirebaseFirestore.instance.collection('settings').doc('app_version').get();

      if (doc.exists && doc.data() != null) {
        final data = doc.data() as Map<String, dynamic>;
        String latestVersion = data['latest_version'] ?? currentVersion;
        String apkUrl = data['apk_url'] ?? "";
        String releaseNotes = data['release_notes'] ?? "New version is available.";
        bool isForce = data['force_update'] ?? false;

        if (currentVersion != latestVersion && apkUrl.isNotEmpty) {
          state = state.copyWith(
            shouldShowUpdatePrompt: true,
            updateLatestVersion: latestVersion,
            updateReleaseNotes: releaseNotes,
            updateApkUrl: apkUrl,
            forceUpdate: isForce,
          );
        }
      }
    } catch (e) {
      debugPrint("Auto Update Check Failed: $e");
    }
  }

  void dismissUpdatePrompt() {
    state = state.copyWith(shouldShowUpdatePrompt: false);
  }

  // ==========================================
  // 模块：账号状态与设备踢出监听
  // ==========================================
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

    state = state.copyWith(
      shouldShowLogoutDialog: true,
      logoutReason: reason,
    );
  }

  void resetLogoutDialog() {
    state = state.copyWith(shouldShowLogoutDialog: false);
  }

  // ==========================================
  // 模块：全局公告监听
  // ==========================================
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

  // ==========================================
  // 模块：生物识别检查
  // ==========================================
  Future<void> _checkBiometricSetup() async {
    final prefs = await SharedPreferences.getInstance();
    bool hasAsked = prefs.getBool('has_asked_biometrics') ?? false;
    bool isEnabled = prefs.getBool('biometric_enabled') ?? false;

    if (hasAsked || isEnabled) return;

    try {
      bool isHardwareSupported = await BiometricService().isDeviceSupported();
      if (!isHardwareSupported) return;

      state = state.copyWith(shouldShowBiometricPrompt: true);
    } catch (e) {
      debugPrint("❌ [Biometric Debug] Exception caught: $e");
    }
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

  // ==========================================
  // 模块：辅助与清理函数
  // ==========================================
  void _checkAndResumeTracking(String uid) {
    ref.read(trackingProvider.notifier).resumeTrackingSession(uid);
  }

  Future<void> _cacheUserName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('cached_staff_name', name);
  }

  void clearMessages() {
    state = state.copyWith(clearMessages: true);
  }

  // ==========================================
  // 模块：头像上传
  // ==========================================
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

final homeProvider = NotifierProvider<HomeNotifier, HomeState>(() {
  return HomeNotifier();
});