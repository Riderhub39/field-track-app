import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../services/biometric_service.dart';

// ==========================================
// 1. 状态定义 (State)
// ==========================================
class BiometricGuardState {
  final bool isLocked;
  final String cachedName;

  BiometricGuardState({
    this.isLocked = false,
    this.cachedName = "Staff",
  });

  BiometricGuardState copyWith({
    bool? isLocked,
    String? cachedName,
  }) {
    return BiometricGuardState(
      isLocked: isLocked ?? this.isLocked,
      cachedName: cachedName ?? this.cachedName,
    );
  }
}

// ==========================================
// 2. 逻辑控制器 (Controller)
// ==========================================
class BiometricGuardController extends StateNotifier<BiometricGuardState> {
  bool _isAuthenticating = false;

  BiometricGuardController() : super(BiometricGuardState()) {
    checkInitialStatus();
  }

  // 初始检查
  Future<void> checkInitialStatus() async {
    final prefs = await SharedPreferences.getInstance();
    bool isEnabled = prefs.getBool('biometric_enabled') ?? false;
    String name = prefs.getString('cached_staff_name') ?? "Staff";
    
    if (mounted) {
      state = state.copyWith(cachedName: name);
    }

    final user = FirebaseAuth.instance.currentUser;
    // 只有在开启了生物识别并且已登录的状态下才上锁
    if (isEnabled && user != null) {
      if (mounted) state = state.copyWith(isLocked: true);
      authenticate();
    }
  }

  // 处理 App 退到后台
  Future<void> handleAppPaused() async {
    if (_isAuthenticating) return;

    final prefs = await SharedPreferences.getInstance();
    bool isEnabled = prefs.getBool('biometric_enabled') ?? false;
    final user = FirebaseAuth.instance.currentUser;
    
    if (isEnabled && user != null) {
      if (mounted) state = state.copyWith(isLocked: true);
    }
  }

  // 处理 App 回到前台
  void handleAppResumed() {
    if (_isAuthenticating) return;
    if (state.isLocked) {
      authenticate();
    }
  }

  // 调起生物识别
  Future<void> authenticate() async {
    if (_isAuthenticating) return;
    _isAuthenticating = true;

    // 每次验证前刷新一下缓存的名字 (防止首页刚刚更改了名字)
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      state = state.copyWith(cachedName: prefs.getString('cached_staff_name') ?? "Staff");
    }

    try {
      bool authenticated = await BiometricService().authenticateStaff();
      if (mounted) {
        if (authenticated) {
          state = state.copyWith(isLocked: false);
        }
      }
    } catch (e) {
      debugPrint("Auth error: $e");
    } finally {
      // 增加短延迟，防止验证失败时陷入无限弹窗循环
      await Future.delayed(const Duration(milliseconds: 500));
      _isAuthenticating = false;
    }
  }

  // 处理重新登录 (登出)
  Future<void> handleRelogin() async {
    // 1. 先解锁遮罩，防止它盖住 LoginScreen
    if (mounted) state = state.copyWith(isLocked: false);
    
    // 2. 执行登出 (main.dart 中的 StreamBuilder 会自动捕获并跳转登录页)
    await FirebaseAuth.instance.signOut();
  }
}

// 暴露 Provider
final biometricGuardProvider = StateNotifierProvider<BiometricGuardController, BiometricGuardState>((ref) {
  return BiometricGuardController();
});