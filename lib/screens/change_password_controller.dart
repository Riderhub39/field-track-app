import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';

// ==========================================
// 1. 状态定义 (State)
// ==========================================
class ChangePasswordState {
  final bool obscureCurrent;
  final bool obscureNew;
  final bool obscureConfirm;
  final bool isLoading;

  // 弹窗提示
  final String? errorMessage;
  final String? successMessage;
  final bool shouldPop; // 用于最后成功后关闭页面

  ChangePasswordState({
    this.obscureCurrent = true,
    this.obscureNew = true,
    this.obscureConfirm = true,
    this.isLoading = false,
    this.errorMessage,
    this.successMessage,
    this.shouldPop = false,
  });

  ChangePasswordState copyWith({
    bool? obscureCurrent,
    bool? obscureNew,
    bool? obscureConfirm,
    bool? isLoading,
    String? errorMessage,
    String? successMessage,
    bool? shouldPop,
    bool clearMessages = false,
  }) {
    return ChangePasswordState(
      obscureCurrent: obscureCurrent ?? this.obscureCurrent,
      obscureNew: obscureNew ?? this.obscureNew,
      obscureConfirm: obscureConfirm ?? this.obscureConfirm,
      isLoading: isLoading ?? this.isLoading,
      shouldPop: shouldPop ?? this.shouldPop,
      errorMessage: clearMessages ? null : (errorMessage ?? this.errorMessage),
      successMessage: clearMessages ? null : (successMessage ?? this.successMessage),
    );
  }
}

// ==========================================
// 2. 逻辑控制器 (Controller)
// ==========================================
class ChangePasswordController extends StateNotifier<ChangePasswordState> {
  final FirebaseAuth _auth = FirebaseAuth.instance;

  ChangePasswordController() : super(ChangePasswordState());

  void clearMessages() {
    if (mounted) state = state.copyWith(clearMessages: true);
  }

  void toggleObscureCurrent() {
    if (mounted) state = state.copyWith(obscureCurrent: !state.obscureCurrent);
  }

  void toggleObscureNew() {
    if (mounted) state = state.copyWith(obscureNew: !state.obscureNew);
  }

  void toggleObscureConfirm() {
    if (mounted) state = state.copyWith(obscureConfirm: !state.obscureConfirm);
  }

  Future<void> submitPasswordChange({
    required String currentPassword,
    required String newPassword,
  }) async {
    state = state.copyWith(isLoading: true, clearMessages: true);
    
    final user = _auth.currentUser;

    if (user == null || user.email == null) {
      if (mounted) state = state.copyWith(isLoading: false, errorMessage: "Error: No user login.");
      return;
    }

    try {
      // 1. Re-authenticate (Required for security sensitive operations)
      AuthCredential credential = EmailAuthProvider.credential(
        email: user.email!,
        password: currentPassword.trim(),
      );
      
      await user.reauthenticateWithCredential(credential);

      // 2. Update Password
      await user.updatePassword(newPassword.trim());

      if (mounted) {
        state = state.copyWith(
          isLoading: false,
          successMessage: "change_pw.success", // locale key
          shouldPop: true,
        );
      }
    } on FirebaseAuthException catch (e) {
      String msg = 'change_pw.error_generic'; // locale key
      
      if (e.code == 'wrong-password' || e.code == 'invalid-credential') {
        msg = 'change_pw.error_wrong_curr';
      } else if (e.code == 'weak-password') {
        msg = 'register.pw_too_short'; 
      } else if (e.code == 'requires-recent-login') {
        msg = 'change_pw.error_session';
      }
      
      if (mounted) {
        state = state.copyWith(
          isLoading: false,
          errorMessage: msg,
        );
      }
    } catch (e) {
      if (mounted) {
        state = state.copyWith(
          isLoading: false,
          errorMessage: "Error: $e",
        );
      }
    }
  }
}

// 暴露 Provider
final changePasswordProvider = StateNotifierProvider.autoDispose<ChangePasswordController, ChangePasswordState>((ref) {
  return ChangePasswordController();
});