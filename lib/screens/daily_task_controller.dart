import 'dart:io';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/daily_task_model.dart';

class DailyTaskController extends GetxController {
  final ImagePicker _picker = ImagePicker();
  var selectedImages = <File>[].obs;
  var isLoading = false.obs;

  // 表单控制器
  final salesNameController = TextEditingController();
  final leadsController = TextEditingController();
  final viewersController = TextEditingController();
  final commentController = TextEditingController();
  final topViewController = TextEditingController();
  final avgViewController = TextEditingController();
  final liveCountController = TextEditingController();
  
  var selectedDate = DateTime.now().obs;
  var accountType = 'Personal'.obs; // 默认值
  var isBoosted = false.obs;

  // 选择多张图片
  Future<void> pickImages() async {
    final List<XFile> images = await _picker.pickMultiImage();
    if (images.isNotEmpty) {
      selectedImages.addAll(images.map((image) => File(image.path)).toList());
    }
  }

  // 上传图片并保存任务
  Future<void> submitTask() async {
    if (salesNameController.text.isEmpty || commentController.text.isEmpty) {
      Get.snackbar("Error", "Please fill in all required fields");
      return;
    }

    try {
      isLoading.value = true;
      List<String> uploadedUrls = [];

      // 1. 上传图片到 Firebase Storage
      for (var image in selectedImages) {
        String fileName = 'tasks/${DateTime.now().millisecondsSinceEpoch}_${selectedImages.indexOf(image)}.jpg';
        TaskSnapshot snapshot = await FirebaseStorage.instance.ref(fileName).putFile(image);
        String downloadUrl = await snapshot.ref.getDownloadURL();
        uploadedUrls.add(downloadUrl);
      }

      // 2. 准备数据
      DailyTask newTask = DailyTask(
        date: selectedDate.value,
        salesName: salesNameController.text,
        accountType: accountType.value,
        liveCount: int.tryParse(liveCountController.text) ?? 0,
        leads: int.tryParse(leadsController.text) ?? 0,
        viewers: int.tryParse(viewersController.text) ?? 0,
        comment: commentController.text,
        topView: int.tryParse(topViewController.text) ?? 0,
        averageView: double.tryParse(avgViewController.text) ?? 0.0,
        isBoosted: isBoosted.value,
        imageUrls: uploadedUrls,
        userId: FirebaseAuth.instance.currentUser?.uid ?? '',
      );

      // 3. 保存到 Firestore
      await FirebaseFirestore.instance.collection('daily_tasks').add(newTask.toJson());
      
      Get.back(); // 返回上一页
      Get.snackbar("Success", "Daily task updated successfully!");
    } catch (e) {
      Get.snackbar("Error", e.toString());
    } finally {
      isLoading.value = false;
    }
  }
}