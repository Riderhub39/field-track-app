import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:easy_localization/easy_localization.dart';

// 🟢 引入 Provider
import 'announcement_provider.dart';

class AnnouncementScreen extends ConsumerWidget {
  const AnnouncementScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 🟢 监听 StreamProvider 的异步状态
    final announcementsAsyncValue = ref.watch(announcementsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text("Announcements"), // Add "announcement.title".tr() if needed
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0,
      ),
      backgroundColor: Colors.grey[50],
      body: announcementsAsyncValue.when(
        // 加载中状态
        loading: () => const Center(child: CircularProgressIndicator()),
        
        // 出错状态
        error: (error, stackTrace) => Center(
          child: Text('Error loading announcements: $error', style: const TextStyle(color: Colors.red)),
        ),
        
        // 数据成功返回
        data: (announcements) {
          if (announcements.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.campaign_outlined, size: 64, color: Colors.grey[300]),
                  const SizedBox(height: 16),
                  const Text("No announcements yet", style: TextStyle(color: Colors.grey)),
                ],
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: announcements.length,
            separatorBuilder: (context, index) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final data = announcements[index];
              final String message = data['message'] ?? '';
              final Timestamp? timestamp = data['createdAt'];
              
              final String dateStr = timestamp != null 
                  ? DateFormat('dd MMM yyyy, hh:mm a', context.locale.languageCode).format(timestamp.toDate()) 
                  : '';

              return Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: Colors.grey.shade200),
                ),
                color: Colors.white,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: Colors.orange.withValues(alpha: 0.1),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.campaign, color: Colors.orange, size: 16),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            dateStr,
                            style: TextStyle(fontSize: 12, color: Colors.grey[600], fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        message,
                        style: const TextStyle(fontSize: 15, height: 1.5, color: Colors.black87),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}