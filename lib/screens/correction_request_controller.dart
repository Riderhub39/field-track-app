import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

// ==========================================
// 1. 状态定义 (State) - 保持不变
// ==========================================
class CorrectionRequestState {
  final TimeOfDay? reqIn;
  final TimeOfDay? reqOut;
  final XFile? selectedFile;
  final bool isLoading;

  // 弹窗提示
  final String? errorMessage;
  final String? successMessage;
  final bool shouldPop; // 用于最后成功后关闭页面

  CorrectionRequestState({
    this.reqIn,
    this.reqOut,
    this.selectedFile,
    this.isLoading = false,
    this.errorMessage,
    this.successMessage,
    this.shouldPop = false,
  });

  CorrectionRequestState copyWith({
    TimeOfDay? reqIn,
    TimeOfDay? reqOut,
    XFile? selectedFile,
    bool? isLoading,
    String? errorMessage,
    String? successMessage,
    bool? shouldPop,
    bool clearImage = false,
    bool clearMessages = false,
  }) {
    return CorrectionRequestState(
      reqIn: reqIn ?? this.reqIn,
      reqOut: reqOut ?? this.reqOut,
      selectedFile: clearImage ? null : (selectedFile ?? this.selectedFile),
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
// 🔴 CHANGED: 从 StateNotifier 迁移至 AutoDisposeNotifier
class CorrectionRequestNotifier extends AutoDisposeNotifier<CorrectionRequestState> {
  final ImagePicker _picker = ImagePicker();

  // 🔴 CHANGED: 使用 build 方法初始化
  @override
  CorrectionRequestState build() {
    return CorrectionRequestState();
  }

  void clearMessages() {
    state = state.copyWith(clearMessages: true);
  }

  void setReqIn(TimeOfDay time) {
    state = state.copyWith(reqIn: time);
  }

  void setReqOut(TimeOfDay time) {
    state = state.copyWith(reqOut: time);
  }

  Future<void> pickImage() async {
    try {
      final XFile? picked = await _picker.pickImage(
        source: ImageSource.gallery, 
        imageQuality: 80
      );
      if (picked != null) {
        state = state.copyWith(selectedFile: picked);
      }
    } catch (e) {
      debugPrint("Error picking image: $e");
    }
  }

  void removeImage() {
    state = state.copyWith(clearImage: true);
  }

  Future<void> submitRequest({
    required BuildContext context, // 传入 context 仅用于 TimeOfDay.format，这是纯 UI 转换逻辑
    required DateTime targetDate,
    required String? attendanceId,
    required String originalIn,
    required String originalOut,
    required String remarks,
  }) async {
    // 至少需要选择一个新时间，或者填写备注
    if (state.reqIn == null && state.reqOut == null && remarks.isEmpty) {
      state = state.copyWith(
        errorMessage: "Please modify a time or add remarks.",
        clearMessages: true
      );
      return;
    }

    state = state.copyWith(isLoading: true, clearMessages: true);

    final String requestedInStr = state.reqIn?.format(context) ?? originalIn;
    final String requestedOutStr = state.reqOut?.format(context) ?? originalOut;
    final String dateStr = DateFormat('yyyy-MM-dd').format(targetDate);

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      state = state.copyWith(isLoading: false, errorMessage: "User not logged in");
      return;
    }

    try {
      String? attachmentUrl;

      // 上传图片证据
      if (state.selectedFile != null) {
        final String fileName = '${DateTime.now().millisecondsSinceEpoch}_correction_${user.uid}.jpg';
        final Reference storageRef = FirebaseStorage.instance
            .ref()
            .child('correction_evidence')
            .child(user.uid)
            .child(fileName);
        
        await storageRef.putFile(File(state.selectedFile!.path));
        attachmentUrl = await storageRef.getDownloadURL();
      }

      // 写入独立的 'attendance_corrections' 集合
      await FirebaseFirestore.instance.collection('attendance_corrections').add({
        'uid': user.uid,
        'email': user.email,
        'type': 'attendance_correction', 
        'attendanceId': attendanceId, 
        'targetDate': dateStr,
        'originalIn': originalIn,
        'originalOut': originalOut,
        'requestedIn': requestedInStr,
        'requestedOut': requestedOutStr,
        'remarks': remarks,
        'status': 'Pending', 
        'createdAt': FieldValue.serverTimestamp(),
        'attachmentUrl': attachmentUrl,
      });

      state = state.copyWith(
        isLoading: false,
        successMessage: "Correction Request Submitted!",
        shouldPop: true,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: "Error: $e",
      );
    }
  }
}

// 🔴 CHANGED: 暴露 Provider 使用 NotifierProvider 语法
final correctionProvider = NotifierProvider.autoDispose<CorrectionRequestNotifier, CorrectionRequestState>(() {
  return CorrectionRequestNotifier();
});