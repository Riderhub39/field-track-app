import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

// 🟢 定义一个 StreamProvider 来监听公告集合
final announcementsProvider = StreamProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
  return FirebaseFirestore.instance
      .collection('announcements')
      .orderBy('createdAt', descending: true)
      .snapshots()
      .map((snapshot) {
        // 将 QuerySnapshot 转换为 List<Map<String, dynamic>> 方便 UI 使用
        // 🟢 修复：去掉了不必要的 as Map<String, dynamic>
        return snapshot.docs.map((doc) => doc.data()).toList();
      });
});