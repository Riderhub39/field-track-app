import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class FileLogger {
  static Future<void> log(String message) async {
    debugPrint(message); 
    if (kReleaseMode) {
      try {
        // 🟢 修改点：使用 getExternalStorageDirectory() 获取外部公共存储路径
        // 注意：在 Android 上，这通常是 /storage/emulated/0/Android/data/你的包名/files/
        final directory = await getExternalStorageDirectory();
        
        if (directory != null) {
          final file = File('${directory.path}/debug_log.txt');
          await file.writeAsString('${DateTime.now().toIso8601String()}: $message\n', mode: FileMode.append);
        }
      } catch (e) {
        debugPrint("File logging failed: $e");
      }
    }
  }
}