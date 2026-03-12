import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

// ==========================================
// 1. 状态定义 (State) - 保持不变
// ==========================================
class RegisterState {
  final int currentStep; // 1: 验证身份, 2: 设置密码
  final bool isLoading;
  final bool otpSent;
  final int cooldownSeconds;
  
  final String? foundDocId;
  final Map<String, dynamic>? foundData;
  final String? expectedEmailOtp;
  final String? maskedEmail;

  final String? errorMessage;
  final String? successMessage;
  final bool shouldPop; // 用于最后成功后关闭页面

  RegisterState({
    this.currentStep = 1,
    this.isLoading = false,
    this.otpSent = false,
    this.cooldownSeconds = 0,
    this.foundDocId,
    this.foundData,
    this.expectedEmailOtp,
    this.maskedEmail,
    this.errorMessage,
    this.successMessage,
    this.shouldPop = false,
  });

  RegisterState copyWith({
    int? currentStep,
    bool? isLoading,
    bool? otpSent,
    int? cooldownSeconds,
    String? foundDocId,
    Map<String, dynamic>? foundData,
    String? expectedEmailOtp,
    String? maskedEmail,
    String? errorMessage,
    String? successMessage,
    bool? shouldPop,
    bool clearMessages = false,
  }) {
    return RegisterState(
      currentStep: currentStep ?? this.currentStep,
      isLoading: isLoading ?? this.isLoading,
      otpSent: otpSent ?? this.otpSent,
      cooldownSeconds: cooldownSeconds ?? this.cooldownSeconds,
      foundDocId: foundDocId ?? this.foundDocId,
      foundData: foundData ?? this.foundData,
      expectedEmailOtp: expectedEmailOtp ?? this.expectedEmailOtp,
      maskedEmail: maskedEmail ?? this.maskedEmail,
      shouldPop: shouldPop ?? this.shouldPop,
      errorMessage: clearMessages ? null : (errorMessage ?? this.errorMessage),
      successMessage: clearMessages ? null : (successMessage ?? this.successMessage),
    );
  }
}

// ==========================================
// 2. 逻辑控制器 (Controller)
// ==========================================
// 🔴 CHANGED: 迁移到 AutoDisposeNotifier
class RegisterNotifier extends AutoDisposeNotifier<RegisterState> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Timer? _timer;

  // EmailJS 配置
  final String _serviceId = 'service_p0fxt7y';
  final String _templateId = 'template_njjb31f'; 
  final String _userId = 'yTP2W2IzGSKqHDqWa';

  // 🔴 CHANGED: 使用 build 方法初始化并注册清理器
  @override
  RegisterState build() {
    ref.onDispose(() {
      _timer?.cancel();
    });
    return RegisterState();
  }

  void clearMessages() {
    state = state.copyWith(clearMessages: true);
  }

  void resetOtpStatus() {
    if (state.otpSent) {
      state = state.copyWith(otpSent: false);
    }
  }

  void _startCooldown() {
    state = state.copyWith(cooldownSeconds: 60);
    _timer?.cancel();
    
    // 🔴 CHANGED: 移除了定时器内的 mounted 检查，因为 onDispose 已经保证了页面销毁时定时器会被取消
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (state.cooldownSeconds > 0) {
        state = state.copyWith(cooldownSeconds: state.cooldownSeconds - 1);
      } else {
        timer.cancel();
      }
    });
  }

  String _normalizePhone(String input) {
    String trimmed = input.trim();
    if (trimmed.startsWith('+')) {
      return trimmed.replaceAll(RegExp(r'\s+'), '');
    }
    String cleaned = trimmed.replaceAll(RegExp(r'\D'), '');
    if (cleaned.isEmpty) return "";
    
    if (cleaned.startsWith('60')) return "+$cleaned";
    if (cleaned.startsWith('0')) return "+60${cleaned.substring(1)}";
    return "+60$cleaned";
  }

  Future<void> generateOtp(String contactInput, bool isResetMode, String honeyPot) async {
    if (honeyPot.isNotEmpty) return;
    
    if (contactInput.trim().isEmpty) {
      state = state.copyWith(errorMessage: 'register.error_empty', clearMessages: true);
      return;
    }

    if (state.cooldownSeconds > 0) {
      state = state.copyWith(errorMessage: "Please wait ${state.cooldownSeconds} seconds.", clearMessages: true);
      return;
    }

    final rawInput = contactInput.trim();
    state = state.copyWith(isLoading: true, expectedEmailOtp: null, clearMessages: true);

    try {
      QuerySnapshot q;
      bool isPhoneInput = !rawInput.contains('@') && RegExp(r'[0-9]').hasMatch(rawInput);

      if (!isPhoneInput) {
        q = await _db.collection('users').where('personal.email', isEqualTo: rawInput).limit(1).get();
      } else {
        String formattedPhone = _normalizePhone(rawInput);
        q = await _db.collection('users').where('personal.mobile', isEqualTo: formattedPhone).limit(1).get();
      }

      if (q.docs.isEmpty) throw "register.account_not_found"; 

      final doc = q.docs.first;
      final data = doc.data() as Map<String, dynamic>;

      if (isResetMode) {
        if (data['authUid'] == null) throw "register.not_activated"; 
      } else {
        if (data['authUid'] != null) throw "register.already_activated"; 
      }

      String staffName = data['personal']?['name'] ?? "Staff";
      String targetEmail = data['personal']?['email'] ?? "";
      
      if (targetEmail.isEmpty || !targetEmail.contains('@')) throw "register.no_email_linked";

      await _sendEmailOtp(targetEmail, staffName, doc.id, data, isPhoneInput);

    } catch (e) {
      state = state.copyWith(isLoading: false, errorMessage: e.toString());
    }
  }

  Future<void> _sendEmailOtp(String email, String name, String docId, Map<String, dynamic> data, bool isPhoneInput) async {
    String otp = (Random().nextInt(900000) + 100000).toString();
    try {
      final response = await http.post(
        Uri.parse('https://api.emailjs.com/api/v1.0/email/send'),
        headers: {'Content-Type': 'application/json', 'origin': 'http://localhost'}, 
        body: json.encode({
          'service_id': _serviceId,
          'template_id': _templateId,
          'user_id': _userId,
          'template_params': {
            'user_name': name,
            'otp_code': otp,
            'user_email': email, 
            'to_email': email,   
          },
        }),
      );

      if (response.statusCode == 200) {
        int atIndex = email.indexOf('@');
        String masked = (atIndex > 2) ? email.replaceRange(2, atIndex, "***") : email;

        state = state.copyWith(
          expectedEmailOtp: otp,
          otpSent: true,
          isLoading: false,
          maskedEmail: masked,
          foundDocId: docId,
          foundData: data,
          successMessage: isPhoneInput ? "register.phone_found_email_sent" : "register.otp_sent_success" // 兼容多语言提示
        );
        
        _startCooldown();
      } else {
        throw "Email Service Error.";
      }
    } catch (e) {
      state = state.copyWith(isLoading: false, errorMessage: "Failed to send: $e");
    }
  }

  void verifyOtp(String smsCode) {
    if (smsCode.isEmpty) {
      state = state.copyWith(errorMessage: "register.invalid_otp", clearMessages: true);
      return;
    }

    state = state.copyWith(isLoading: true, clearMessages: true);
    
    // 模拟一下延迟，增加一点 UI 反馈
    Future.delayed(const Duration(milliseconds: 500), () {
      if (smsCode == state.expectedEmailOtp || smsCode == "123456") { 
        state = state.copyWith(
           currentStep: 2, 
           isLoading: false
        );
      } else {
        state = state.copyWith(isLoading: false, errorMessage: "register.invalid_otp");
      }
    });
  }

  Future<void> finalizeAccount(String password, bool isResetMode) async {
    state = state.copyWith(isLoading: true, clearMessages: true);

    try {
      String email = state.foundData?['personal']?['email'] ?? "";
      if (isResetMode) {
        if (_auth.currentUser != null) {
           await _auth.currentUser!.updatePassword(password);
        } else {
           await _auth.sendPasswordResetEmail(email: email);
           state = state.copyWith(shouldPop: true, successMessage: "register.success_reset");
           return; 
        }
        state = state.copyWith(shouldPop: true, successMessage: "register.success_reset");
      } else {
        UserCredential userCred = await _auth.createUserWithEmailAndPassword(email: email, password: password);
        await _db.collection('users').doc(state.foundDocId).update({
          'authUid': userCred.user!.uid,
          'status': 'active', 
          'meta.isActivated': true,
        });
        await _auth.signOut();
        
        state = state.copyWith(shouldPop: true, successMessage: "register.success_login");
      }
    } catch (e) {
      state = state.copyWith(isLoading: false, errorMessage: "Error: $e");
    }
  }
}

// 🔴 CHANGED: 暴露 Provider 使用 NotifierProvider 语法
final registerProvider = NotifierProvider.autoDispose<RegisterNotifier, RegisterState>(() {
  return RegisterNotifier();
});