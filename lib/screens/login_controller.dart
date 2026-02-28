import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/auth_service.dart';
import '../services/biometric_service.dart';

// ==========================================
// 1. 状态定义 (State)
// ==========================================
class LoginState {
  final bool isLoading;
  final bool isObscured;
  final int failedAttempts;
  final DateTime? lockoutTime;

  // 导航触发标志位
  final bool shouldNavigateToHome;
  final bool shouldShowBiometricPrompt;
  final User? authenticatedUser;

  // 消息提示
  final String? errorMessage;
  final String? successMessage;

  LoginState({
    this.isLoading = false,
    this.isObscured = true,
    this.failedAttempts = 0,
    this.lockoutTime,
    this.shouldNavigateToHome = false,
    this.shouldShowBiometricPrompt = false,
    this.authenticatedUser,
    this.errorMessage,
    this.successMessage,
  });

  LoginState copyWith({
    bool? isLoading,
    bool? isObscured,
    int? failedAttempts,
    DateTime? lockoutTime,
    bool? shouldNavigateToHome,
    bool? shouldShowBiometricPrompt,
    User? authenticatedUser,
    String? errorMessage,
    String? successMessage,
    bool clearMessages = false,
  }) {
    return LoginState(
      isLoading: isLoading ?? this.isLoading,
      isObscured: isObscured ?? this.isObscured,
      failedAttempts: failedAttempts ?? this.failedAttempts,
      lockoutTime: lockoutTime ?? this.lockoutTime,
      shouldNavigateToHome: shouldNavigateToHome ?? this.shouldNavigateToHome,
      shouldShowBiometricPrompt: shouldShowBiometricPrompt ?? this.shouldShowBiometricPrompt,
      authenticatedUser: authenticatedUser ?? this.authenticatedUser,
      errorMessage: clearMessages ? null : (errorMessage ?? this.errorMessage),
      successMessage: clearMessages ? null : (successMessage ?? this.successMessage),
    );
  }
}

// ==========================================
// 2. 逻辑控制器 (Controller)
// ==========================================
class LoginController extends StateNotifier<LoginState> {
  static const String _keyFailedAttempts = 'auth_failed_attempts';
  static const String _keyLockoutTime = 'auth_lockout_timestamp';

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  LoginController() : super(LoginState()) {
    _loadSecurityState();
  }

  void toggleObscure() {
    if (mounted) state = state.copyWith(isObscured: !state.isObscured);
  }

  void clearMessages() {
    if (mounted) state = state.copyWith(clearMessages: true);
  }

  // --- 安全与锁定逻辑 ---

  Future<void> _loadSecurityState() async {
    final prefs = await SharedPreferences.getInstance();
    final int? lockoutTimestamp = prefs.getInt(_keyLockoutTime);
    final int savedAttempts = prefs.getInt(_keyFailedAttempts) ?? 0;

    if (lockoutTimestamp != null) {
      final lockoutEnd = DateTime.fromMillisecondsSinceEpoch(lockoutTimestamp);
      if (DateTime.now().isBefore(lockoutEnd)) {
        if (mounted) {
          state = state.copyWith(lockoutTime: lockoutEnd, failedAttempts: savedAttempts);
        }
      } else {
        await resetSecurityState();
      }
    } else {
      if (mounted) {
        state = state.copyWith(failedAttempts: savedAttempts);
      }
    }
  }

  Future<void> resetSecurityState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyFailedAttempts);
    await prefs.remove(_keyLockoutTime);
    // 为了彻底清除锁定时间，我们需要传一个新的对象，这里直接用默认值覆盖
    if (mounted) {
      state = LoginState(
        isObscured: state.isObscured, // 保留当前的密码可见性状态
      );
    }
  }

  Future<void> _recordLoginFailure() async {
    final prefs = await SharedPreferences.getInstance();
    final newAttempts = state.failedAttempts + 1;

    if (newAttempts >= 5) {
      final lockoutEnd = DateTime.now().add(const Duration(minutes: 5));
      await prefs.setInt(_keyLockoutTime, lockoutEnd.millisecondsSinceEpoch);
      await prefs.setInt(_keyFailedAttempts, newAttempts);
      if (mounted) {
        state = state.copyWith(failedAttempts: newAttempts, lockoutTime: lockoutEnd);
      }
    } else {
      await prefs.setInt(_keyFailedAttempts, newAttempts);
      if (mounted) {
        state = state.copyWith(failedAttempts: newAttempts);
      }
    }
  }

  String _normalizePhone(String input) {
    String trimmed = input.trim();
    if (trimmed.startsWith('+')) {
      return trimmed.replaceAll(RegExp(r'\s+'), '');
    }
    String cleaned = trimmed.replaceAll(RegExp(r'\D'), '');
    if (cleaned.isEmpty) return "";
    if (cleaned.startsWith('60')) {
      return "+$cleaned";
    } else if (cleaned.startsWith('0')) {
      return "+60${cleaned.substring(1)}";
    } else {
      return "+60$cleaned";
    }
  }

  // --- 登录核心逻辑 ---

  Future<void> login(String input, String password, String honeyPot) async {
    if (honeyPot.isNotEmpty) return;

    if (state.lockoutTime != null) {
      if (DateTime.now().isBefore(state.lockoutTime!)) {
        final remaining = state.lockoutTime!.difference(DateTime.now()).inMinutes;
        state = state.copyWith(
          errorMessage: "Too many attempts. Try again in ${remaining + 1} minutes.", 
          clearMessages: true
        );
        return;
      } else {
        await resetSecurityState();
      }
    }

    state = state.copyWith(isLoading: true, clearMessages: true);

    try {
      String finalEmail = input.trim();

      // 如果输入的是手机号，先去数据库查询绑定的 Email
      if (!input.contains('@') && RegExp(r'[0-9]').hasMatch(input)) {
         String formattedPhone = _normalizePhone(input);
         QuerySnapshot query = await _db.collection('users').where('personal.mobile', isEqualTo: formattedPhone).limit(1).get();
         
         if (query.docs.isEmpty) throw FirebaseAuthException(code: 'invalid-credential');
         
         final userData = query.docs.first.data() as Map<String, dynamic>;
         final personalData = userData['personal'] as Map<String, dynamic>?;
         
         if (personalData != null && personalData['email'] != null) {
           finalEmail = personalData['email'];
         } else {
           throw FirebaseAuthException(code: 'invalid-credential');
         }
      }

      UserCredential userCred = await _auth.signInWithEmailAndPassword(
        email: finalEmail, 
        password: password.trim()
      );
      
      await resetSecurityState();
      
      if (userCred.user != null) {
        // 🟢 更新设备 ID 以踢出旧设备
        await AuthService().updateDeviceIdOnLogin(userCred.user!.uid);

        // 检查账号是否被管理员禁用
        QuerySnapshot statusQuery = await _db
            .collection('users')
            .where('authUid', isEqualTo: userCred.user!.uid)
            .limit(1)
            .get();

        if (statusQuery.docs.isNotEmpty) {
          final docData = statusQuery.docs.first.data() as Map<String, dynamic>;
          if ((docData['status'] ?? 'active') == 'disabled') {
            await _auth.signOut();
            throw FirebaseAuthException(code: 'user-disabled');
          }
        }
        
        await _checkBiometricsEligibility(userCred.user!);
      }

    } on FirebaseAuthException catch (e) {
      await _recordLoginFailure();

      String message = "Login Failed";
      if (e.code == 'user-disabled') {
        message = "Account disabled by administrator.";
      } else if (['user-not-found', 'wrong-password', 'invalid-email', 'invalid-credential'].contains(e.code)) {
        message = "register.account_not_found"; // locale key
      }
      if (mounted) state = state.copyWith(isLoading: false, errorMessage: message);

    } catch (e) {
      if (mounted) state = state.copyWith(isLoading: false, errorMessage: "Connection Error.");
    }
  }

  // --- 生物识别检查 ---
  
  Future<void> _checkBiometricsEligibility(User user) async {
    final prefs = await SharedPreferences.getInstance();
    
    bool hasAsked = prefs.getBool('has_asked_biometrics') ?? false;
    bool isEnabled = prefs.getBool('biometric_enabled') ?? false;
    bool isHardwareSupported = await BiometricService().isDeviceSupported();

    if (!isHardwareSupported || isEnabled || hasAsked) {
      if (mounted) {
        state = state.copyWith(isLoading: false, shouldNavigateToHome: true);
      }
    } else {
      if (mounted) {
        state = state.copyWith(
          isLoading: false, 
          shouldShowBiometricPrompt: true, 
          authenticatedUser: user
        );
      }
    }
  }

  Future<void> declineBiometrics() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('has_asked_biometrics', true);
    if (mounted) {
      state = state.copyWith(shouldShowBiometricPrompt: false, shouldNavigateToHome: true);
    }
  }

  Future<void> enableBiometrics() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) state = state.copyWith(shouldShowBiometricPrompt: false);

    bool success = await BiometricService().authenticateStaff();
    
    if (success) {
      await prefs.setBool('biometric_enabled', true);
      await prefs.setBool('has_asked_biometrics', true);
      if (mounted) {
        state = state.copyWith(
          successMessage: 'settings.biometric_on_msg', // locale key
          shouldNavigateToHome: true
        );
      }
    } else {
      if (mounted) state = state.copyWith(shouldNavigateToHome: true);
    }
  }
}

// 暴露 Provider
final loginProvider = StateNotifierProvider.autoDispose<LoginController, LoginState>((ref) {
  return LoginController();
});