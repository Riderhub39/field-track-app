import 'dart:io'; // 🟢 新增：引入 dart:io 以使用 Platform
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/notification_service.dart';

// ==========================================
// 1. 状态定义 (State)
// ==========================================
class SettingsState {
  final bool isLoading;
  final bool notificationsEnabled;
  final bool biometricEnabled;
  final bool isLoggedOut;
  final String? successMessage; // 🟢 新增：用于显示最新版本提示
  final String? errorMessage;   // 🟢 新增：用于显示错误提示

  SettingsState({
    this.isLoading = true,
    this.notificationsEnabled = true,
    this.biometricEnabled = false,
    this.isLoggedOut = false,
    this.successMessage,
    this.errorMessage,
  });

  SettingsState copyWith({
    bool? isLoading,
    bool? notificationsEnabled,
    bool? biometricEnabled,
    bool? isLoggedOut,
    String? successMessage,
    String? errorMessage,
    bool clearMessages = false, // 用于重置提示状态
  }) {
    return SettingsState(
      isLoading: isLoading ?? this.isLoading,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      biometricEnabled: biometricEnabled ?? this.biometricEnabled,
      isLoggedOut: isLoggedOut ?? this.isLoggedOut,
      successMessage: clearMessages ? null : (successMessage ?? this.successMessage),
      errorMessage: clearMessages ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

// ==========================================
// 2. 逻辑控制器 (Controller)
// ==========================================
class SettingsNotifier extends AutoDisposeNotifier<SettingsState> {
  
  @override
  SettingsState build() {
    _loadSettings();
    return SettingsState(isLoading: true);
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    
    state = state.copyWith(
      notificationsEnabled: prefs.getBool('notifications_enabled') ?? true,
      biometricEnabled: prefs.getBool('biometric_enabled') ?? false,
      isLoading: false,
    );
  }

  Future<void> toggleNotifications(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('notifications_enabled', value);
    
    state = state.copyWith(notificationsEnabled: value);

    if (!value) {
      NotificationService().cancelAllReminders(); 
    }
  }

  Future<void> toggleBiometric(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('biometric_enabled', value);
    
    state = state.copyWith(biometricEnabled: value);
  }

  Future<void> logout() async {
    NotificationService().stopListening();
    await FirebaseAuth.instance.signOut();
    
    state = state.copyWith(isLoggedOut: true);
  }

  // 🚀 新增：检查版本更新逻辑
  Future<void> checkForUpdate(BuildContext context) async {
    state = state.copyWith(isLoading: true, clearMessages: true); 

    try {
      // 1. 获取本地安装的版本号 (需要 pubspec.yaml 中的 version 字段)
      PackageInfo packageInfo = await PackageInfo.fromPlatform();
      String currentVersion = packageInfo.version; 

      // 2. 获取云端最新版本配置
      DocumentSnapshot doc = await FirebaseFirestore.instance.collection('settings').doc('app_version').get();
      
      if (doc.exists && doc.data() != null) {
        final data = doc.data() as Map<String, dynamic>;
        String latestVersion = data['latest_version'] ?? currentVersion;
        String apkUrl = data['apk_url'] ?? "";
        String releaseNotes = data['release_notes'] ?? "Bug fixes and performance improvements.";

        // 3. 对比版本号
        if (currentVersion != latestVersion && apkUrl.isNotEmpty) {
          state = state.copyWith(isLoading: false);
          if (!context.mounted) return;
          _showUpdateDialog(context, latestVersion, releaseNotes, apkUrl);
        } else {
          // 已经是最新版
          state = state.copyWith(
            isLoading: false, 
            successMessage: "Your app is up to date (v$currentVersion)."
          );
        }
      } else {
        state = state.copyWith(isLoading: false, errorMessage: "Failed to retrieve update info.");
      }
    } catch (e) {
      state = state.copyWith(isLoading: false, errorMessage: "Error checking for updates: $e");
    }
  }

  // 🟢 新增：弹出更新提示框 (强制覆盖现有弹窗)
  void _showUpdateDialog(BuildContext context, String latestVersion, String releaseNotes, String apkUrl) {
    showDialog(
      context: context,
      barrierDismissible: false, // 点击空白处不可关闭
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        title: const Row(
          children: [
            Icon(Icons.system_update, color: Colors.blue),
            SizedBox(width: 10),
            Text("Update Available"),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("Version $latestVersion is ready to install!", style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            const Text("Release Notes:", style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 4),
            Text(releaseNotes, style: const TextStyle(fontSize: 14)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx), 
            child: const Text("Later", style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
            onPressed: () async {
              Navigator.pop(ctx);
              
              // 🟢 针对 iOS 拦截跳转，弹出提示框
              if (Platform.isIOS) {
                showDialog(
                  context: context,
                  builder: (innerCtx) => AlertDialog(
                    title: const Text("Notice"),
                    content: const Text("iOS update feature is not completed yet."),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(innerCtx),
                        child: const Text("OK"),
                      ),
                    ],
                  ),
                );
              } else {
                // Android 保持原有的外部链接跳转逻辑
                final Uri url = Uri.parse(apkUrl);
                if (await canLaunchUrl(url)) {
                  await launchUrl(url, mode: LaunchMode.externalApplication); 
                }
              }
            },
            child: const Text("Update Now", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}

// 暴露 Provider
final settingsProvider = NotifierProvider.autoDispose<SettingsNotifier, SettingsState>(() {
  return SettingsNotifier();
});