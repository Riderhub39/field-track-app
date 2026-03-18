import 'package:cloud_firestore/cloud_firestore.dart';

class DailyTask {
  final String? id;
  final DateTime date;
  final String salesName;
  final String accountType; // personal / company
  final int liveCount;
  final int leads;
  final int viewers;
  final String comment;
  final int topView;
  final double averageView;
  final bool isBoosted;
  final List<String> imageUrls;
  final String userId;

  DailyTask({
    this.id,
    required this.date,
    required this.salesName,
    required this.accountType,
    required this.liveCount,
    required this.leads,
    required this.viewers,
    required this.comment,
    required this.topView,
    required this.averageView,
    required this.isBoosted,
    required this.imageUrls,
    required this.userId,
  });

  Map<String, dynamic> toJson() => {
        'date': Timestamp.fromDate(date),
        'salesName': salesName,
        'accountType': accountType,
        'liveCount': liveCount,
        'leads': leads,
        'viewers': viewers,
        'comment': comment,
        'topView': topView,
        'averageView': averageView,
        'isBoosted': isBoosted,
        'imageUrls': imageUrls,
        'userId': userId,
        'createdAt': FieldValue.serverTimestamp(),
      };
}