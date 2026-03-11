import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart'; // 🟢 添加了 material.dart 用于 debugPrint
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart'; // 🟢 确保引入
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
  
  // 🟢 自动更新弹窗状态
  final bool shouldShowUpdatePrompt;
  final String? updateLatestVersion;
  final String? updateReleaseNotes;
  final String? updateApkUrl;
  final bool forceUpdate;
  
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
    this.shouldShowUpdatePrompt = false,
    this.updateLatestVersion,
    this.updateReleaseNotes,
    this.updateApkUrl,
    this.forceUpdate = false,
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
    bool? shouldShowUpdatePrompt,
    String? updateLatestVersion,
    String? updateReleaseNotes,
    String? updateApkUrl,
    bool? forceUpdate,
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
      shouldShowUpdatePrompt: shouldShowUpdatePrompt ?? this.shouldShowUpdatePrompt,
      updateLatestVersion: updateLatestVersion ?? this.updateLatestVersion,
      updateReleaseNotes: updateReleaseNotes ?? this.updateReleaseNotes,
      updateApkUrl: updateApkUrl ?? this.updateApkUrl,
      forceUpdate: forceUpdate ?? this.forceUpdate,
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
    debugPrint("🚀 [HomeNotifier] build() triggered");
    _initAll();
    
    ref.onDispose(() {
      _announcementSubscription?.cancel();
      _userStatusSubscription?.cancel();
      _kickOutSubscription?.cancel();
    });

    return HomeState();
  }

  void _initAll() {
    _checkForUpdates(); // 🟢 1. 第一时间在后台静默检查是否有新版本
    _listenToUserStatus();
    _startDeviceMonitoring();
    _listenForAnnouncements();

    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      NotificationService().startListeningToUserUpdates(user.uid);
      _checkAndResumeTracking(user.uid);
    }

    // 这里原先设定了 1 秒延迟
    debugPrint("⏳ [HomeNotifier] Queuing Biometric Check in 1 second...");
    Future.delayed(const Duration(seconds: 1), _checkBiometricSetup);
  }

  // 🚀 新增：静默检查更新逻辑
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
        bool isForce = data['force_update'] ?? false; // 数据库可以控制是否强更

        if (currentVersion != latestVersion && apkUrl.isNotEmpty) {
          // 发现新版本，触发状态更新通知 UI 弹窗
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

  // 🚀 新增：用于用户点击稍后更新时关闭弹窗
  void dismissUpdatePrompt() {
    state = state.copyWith(shouldShowUpdatePrompt: false);
  }

  void clearMessages() {
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

  // 🔴 重点调试区域
  Future<void> _checkBiometricSetup() async {
    debugPrint("🔍 [Biometric Debug] _checkBiometricSetup started. Waiting 800ms...");
    await Future.delayed(const Duration(milliseconds: 800));

    final prefs = await SharedPreferences.getInstance();
    bool hasAsked = prefs.getBool('has_asked_biometrics') ?? false;
    bool isEnabled = prefs.getBool('biometric_enabled') ?? false;

    debugPrint("🔍 [Biometric Debug] Cache values -> hasAsked: $hasAsked | isEnabled: $isEnabled");

    if (hasAsked || isEnabled) {
      debugPrint("🛑 [Biometric Debug] Exiting: Already asked or enabled.");
      return;
    }

    debugPrint("🔍 [Biometric Debug] Checking hardware support...");
    try {
      bool isHardwareSupported = await BiometricService().isDeviceSupported();
      debugPrint("🔍 [Biometric Debug] isDeviceSupported returned: $isHardwareSupported");

      if (!isHardwareSupported) {
        debugPrint("🛑 [Biometric Debug] Exiting: Hardware not supported OR no fingerprint enrolled on Emulator.");
        return;
      }

      debugPrint("✅ [Biometric Debug] Conditions met. Updating state to show prompt!");
      state = state.copyWith(shouldShowBiometricPrompt: true);
    } catch (e) {
      debugPrint("❌ [Biometric Debug] Exception caught during biometric check: $e");
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

final homeProvider = NotifierProvider<HomeNotifier, HomeState>(() {
  return HomeNotifier();
});