import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/notification_service.dart';

// ==========================================
// 1. 状态定义 (State) - 保持不变
// ==========================================
class SettingsState {
  final bool isLoading;
  final bool notificationsEnabled;
  final bool biometricEnabled;
  final bool isLoggedOut;

  SettingsState({
    this.isLoading = true,
    this.notificationsEnabled = true,
    this.biometricEnabled = false,
    this.isLoggedOut = false,
  });

  SettingsState copyWith({
    bool? isLoading,
    bool? notificationsEnabled,
    bool? biometricEnabled,
    bool? isLoggedOut,
  }) {
    return SettingsState(
      isLoading: isLoading ?? this.isLoading,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      biometricEnabled: biometricEnabled ?? this.biometricEnabled,
      isLoggedOut: isLoggedOut ?? this.isLoggedOut,
    );
  }
}

// ==========================================
// 2. 逻辑控制器 (Controller)
// ==========================================
// 🔴 CHANGED: 从 StateNotifier 迁移至 AutoDisposeNotifier
class SettingsNotifier extends AutoDisposeNotifier<SettingsState> {
  
  // 🔴 CHANGED: 使用 build 方法初始化
  @override
  SettingsState build() {
    // 异步加载设置数据
    _loadSettings();
    return SettingsState(isLoading: true);
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    
    // 🔴 CHANGED: 移除了 mounted 检查，直接修改 state
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
}

// 🔴 CHANGED: 暴露 Provider 使用 NotifierProvider 语法
final settingsProvider = NotifierProvider.autoDispose<SettingsNotifier, SettingsState>(() {
  return SettingsNotifier();
});