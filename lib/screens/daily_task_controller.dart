import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/daily_task_model.dart';

// ==========================================
// 1. 状态定义 (State)
// ==========================================
class DailyTaskState {
  final List<File> selectedImages;
  final bool isLoading;
  final DateTime selectedDate;
  final String accountType;
  final bool isBoosted;

  // UI 事件通知标志
  final String? errorMessage;
  final String? successMessage;
  final bool shouldPop;

  DailyTaskState({
    this.selectedImages = const [],
    this.isLoading = false,
    required this.selectedDate,
    this.accountType = 'Personal',
    this.isBoosted = false,
    this.errorMessage,
    this.successMessage,
    this.shouldPop = false,
  });

  DailyTaskState copyWith({
    List<File>? selectedImages,
    bool? isLoading,
    DateTime? selectedDate,
    String? accountType,
    bool? isBoosted,
    String? errorMessage,
    String? successMessage,
    bool? shouldPop,
    bool clearMessages = false,
  }) {
    return DailyTaskState(
      selectedImages: selectedImages ?? this.selectedImages,
      isLoading: isLoading ?? this.isLoading,
      selectedDate: selectedDate ?? this.selectedDate,
      accountType: accountType ?? this.accountType,
      isBoosted: isBoosted ?? this.isBoosted,
      shouldPop: shouldPop ?? this.shouldPop,
      errorMessage: clearMessages ? null : (errorMessage ?? this.errorMessage),
      successMessage: clearMessages ? null : (successMessage ?? this.successMessage),
    );
  }
}

// ==========================================
// 2. 逻辑控制器 (Notifier)
// ==========================================
class DailyTaskNotifier extends AutoDisposeNotifier<DailyTaskState> {
  final ImagePicker _picker = ImagePicker();

  @override
  DailyTaskState build() {
    return DailyTaskState(
      selectedDate: DateTime.now(),
    );
  }

  // --- 状态更新方法 ---
  void setDate(DateTime date) {
    state = state.copyWith(selectedDate: date);
  }

  void setAccountType(String type) {
    state = state.copyWith(accountType: type);
  }

  void setBoosted(bool boosted) {
    state = state.copyWith(isBoosted: boosted);
  }

  void removeImage(int index) {
    final list = List<File>.from(state.selectedImages);
    list.removeAt(index);
    state = state.copyWith(selectedImages: list);
  }

  void clearMessages() {
    state = state.copyWith(clearMessages: true);
  }

  // --- 业务逻辑 ---
  Future<void> pickImages() async {
    final List<XFile> images = await _picker.pickMultiImage();
    if (images.isNotEmpty) {
      final newImages = images.map((image) => File(image.path)).toList();
      state = state.copyWith(selectedImages: [...state.selectedImages, ...newImages]);
    }
  }

  Future<void> submitTask({
    required String salesName,
    required String leads,
    required String viewers,
    required String comment,
    required String topView,
    required String avgView,
    required String liveCount,
  }) async {
    if (salesName.isEmpty || comment.isEmpty) {
      state = state.copyWith(errorMessage: "Please fill in all required fields");
      return;
    }

    try {
      state = state.copyWith(isLoading: true, clearMessages: true);
      List<String> uploadedUrls = [];

      // 1. 上传图片到 Firebase Storage
      for (int i = 0; i < state.selectedImages.length; i++) {
        var image = state.selectedImages[i];
        String fileName = 'tasks/${DateTime.now().millisecondsSinceEpoch}_$i.jpg';
        TaskSnapshot snapshot = await FirebaseStorage.instance.ref(fileName).putFile(image);
        String downloadUrl = await snapshot.ref.getDownloadURL();
        uploadedUrls.add(downloadUrl);
      }

      // 2. 准备数据
      DailyTask newTask = DailyTask(
        date: state.selectedDate,
        salesName: salesName,
        accountType: state.accountType,
        liveCount: int.tryParse(liveCount) ?? 0,
        leads: int.tryParse(leads) ?? 0,
        viewers: int.tryParse(viewers) ?? 0,
        comment: comment,
        topView: int.tryParse(topView) ?? 0,
        averageView: double.tryParse(avgView) ?? 0.0,
        isBoosted: state.isBoosted,
        imageUrls: uploadedUrls,
        userId: FirebaseAuth.instance.currentUser?.uid ?? '',
      );

      // 3. 保存到 Firestore
      await FirebaseFirestore.instance.collection('daily_tasks').add(newTask.toJson());
      
      // 成功后通知 UI 执行弹窗和页面返回
      state = state.copyWith(
        isLoading: false,
        successMessage: "Daily task updated successfully!",
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

// 🟢 暴露 Provider
final dailyTaskProvider = NotifierProvider.autoDispose<DailyTaskNotifier, DailyTaskState>(() {
  return DailyTaskNotifier();
});