import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:flutter/foundation.dart';

class LocalDbService {
  static final LocalDbService _instance = LocalDbService._internal();
  factory LocalDbService() => _instance;
  LocalDbService._internal();

  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDb();
    return _database!;
  }

  Future<Database> _initDb() async {
    String path = join(await getDatabasesPath(), 'tracking_cache.db');
    return await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE location_cache (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            latitude REAL,
            longitude REAL,
            timestamp TEXT,
            isUploaded INTEGER DEFAULT 0
          )
        ''');
      },
    );
  }

  // 🟢 插入新的坐标点
  Future<void> insertLocation(double lat, double lng) async {
    try {
      final db = await database;
      await db.insert('location_cache', {
        'latitude': lat,
        'longitude': lng,
        'timestamp': DateTime.now().toIso8601String(),
        'isUploaded': 0,
      });
      debugPrint("📍 GPS 点已存入本地缓存");
    } catch (e) {
      debugPrint("❌ 本地存储失败: $e");
    }
  }

  // 获取所有未上传的点
  Future<List<Map<String, dynamic>>> getUnuploadedLocations() async {
    final db = await database;
    return await db.query('location_cache', where: 'isUploaded = ?', whereArgs: [0]);
  }

  // 批量标记为已上传（为了节省空间，我们通常直接删除已上传的点）
  Future<void> clearUploaded(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await database;
    await db.delete('location_cache', where: 'id IN (${ids.join(',')})');
    debugPrint("🧹 已清理已上传的本地缓存点: ${ids.length}个");
  }
}