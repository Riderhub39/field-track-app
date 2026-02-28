import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

// ==========================================
// 1. 状态定义 (State)
// ==========================================
class ProfileState {
  final bool isLoading;
  final String? docId;
  final Map<String, dynamic> rawData;
  final String status;
  final bool hasPendingRequest;
  
  // 提示消息
  final String? successMessage;
  final String? errorMessage;

  bool get isEditable => status == 'editable';

  ProfileState({
    this.isLoading = true,
    this.docId,
    this.rawData = const {},
    this.status = 'active',
    this.hasPendingRequest = false,
    this.successMessage,
    this.errorMessage,
  });

  ProfileState copyWith({
    bool? isLoading,
    String? docId,
    Map<String, dynamic>? rawData,
    String? status,
    bool? hasPendingRequest,
    String? successMessage,
    String? errorMessage,
    bool clearMessages = false,
  }) {
    return ProfileState(
      isLoading: isLoading ?? this.isLoading,
      docId: docId ?? this.docId,
      rawData: rawData ?? this.rawData,
      status: status ?? this.status,
      hasPendingRequest: hasPendingRequest ?? this.hasPendingRequest,
      successMessage: clearMessages ? null : (successMessage ?? this.successMessage),
      errorMessage: clearMessages ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

// ==========================================
// 2. 逻辑控制器 (Controller)
// ==========================================
class ProfileController extends StateNotifier<ProfileState> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  StreamSubscription<DocumentSnapshot>? _userSubscription;
  StreamSubscription<QuerySnapshot>? _requestSubscription;

  // 全局的输入框控制器池，避免内存泄漏，并且在编辑时保持状态
  final Map<String, TextEditingController> _controllers = {};

  ProfileController() : super(ProfileState()) {
    _initRealtimeListeners();
  }

  @override
  void dispose() {
    _userSubscription?.cancel();
    _requestSubscription?.cancel();
    for (var controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void clearMessages() {
    if (mounted) state = state.copyWith(clearMessages: true);
  }

  void _initRealtimeListeners() async {
    final user = _auth.currentUser;
    if (user == null) {
      if (mounted) state = state.copyWith(isLoading: false, errorMessage: "Not logged in");
      return;
    }

    try {
      final querySnapshot = await _db
          .collection('users')
          .where('authUid', isEqualTo: user.uid)
          .limit(1)
          .get();

      if (querySnapshot.docs.isEmpty) {
        if (mounted) state = state.copyWith(isLoading: false);
        return;
      }

      final docId = querySnapshot.docs.first.id;

      // 监听用户信息变更 (用于 Admin 开启编辑权限后实时响应)
      _userSubscription = _db
          .collection('users')
          .doc(docId)
          .snapshots()
          .listen((snapshot) {
        if (snapshot.exists && mounted) {
          final data = snapshot.data() as Map<String, dynamic>;
          state = state.copyWith(
            docId: docId,
            rawData: data,
            status: data['status'] ?? 'active',
            isLoading: false,
          );
        }
      });

      // 监听是否存在待处理的编辑申请
      _requestSubscription = _db
          .collection('edit_requests')
          .where('userId', isEqualTo: docId)
          .where('status', isEqualTo: 'pending')
          .snapshots()
          .listen((snapshot) {
        if (mounted) {
          state = state.copyWith(hasPendingRequest: snapshot.docs.isNotEmpty);
        }
      });
    } catch (e) {
      if (mounted) {
        state = state.copyWith(
          isLoading: false,
          errorMessage: "Failed to load profile: $e"
        );
      }
    }
  }

  // 获取深层嵌套的 Map 值
  String getValue(List<String> keys) {
    dynamic current = state.rawData;
    for (String key in keys) {
      if (current is Map && current[key] != null) {
        current = current[key];
      } else {
        return '-';
      }
    }
    return current.toString();
  }

  // 从缓存池获取或创建 TextEditingController
  TextEditingController getController(String key, String initialValue) {
    if (!_controllers.containsKey(key)) {
      String text = initialValue == '-' ? '' : initialValue;
      _controllers[key] = TextEditingController(text: text);
    }
    return _controllers[key]!;
  }

  Future<void> saveProfile() async {
    if (state.docId == null) return;
    
    state = state.copyWith(isLoading: true, clearMessages: true);

    try {
      Map<String, dynamic> updates = {};
      _controllers.forEach((key, controller) {
        // 如果输入为空，最好不要覆盖原有结构，可以存空字符串
        updates[key] = controller.text.trim();
      });

      updates['meta.lastMobileUpdate'] = FieldValue.serverTimestamp();

      await _db.collection('users').doc(state.docId).update(updates);

      if (mounted) {
        state = state.copyWith(
          successMessage: "profile.save_success", // locale key
          isLoading: false
        );
      }
    } catch (e) {
      if (mounted) {
        state = state.copyWith(
          errorMessage: "profile.save_failed", // 可以考虑合并 $e，但在 UI 层做更稳
          isLoading: false
        );
      }
    }
  }

  Future<void> submitEditRequest(String reason) async {
    if (state.docId == null) return;

    try {
      await _db.collection('edit_requests').add({
        'userId': state.docId,
        'empName': getValue(['personal', 'name']),
        'empCode': getValue(['personal', 'empCode']),
        'request': reason,
        'status': 'pending',
        'date': FieldValue.serverTimestamp(),
      });
      
      if (mounted) {
        state = state.copyWith(successMessage: "profile.request_sent");
      }
    } catch (e) {
      if (mounted) {
        state = state.copyWith(errorMessage: "profile.request_failed");
      }
    }
  }
}

// 暴露 Provider
final profileProvider = StateNotifierProvider.autoDispose<ProfileController, ProfileState>((ref) {
  return ProfileController();
});