import 'package:ntp/ntp.dart';
import 'package:flutter/foundation.dart';

class TimeService {
  // 记录真实时间与手机本地时间的偏差
  static Duration _timeOffset = Duration.zero;
  
  // 内部状态
  static bool _isSynced = false;

  // 🟢 新增：暴露 getter，消除未使用警告。外部可以通过 TimeService.isSynced 来检查同步状态
  static bool get isSynced => _isSynced;

  /// 🟢 在 App 启动或从后台恢复时调用
  static Future<void> syncTime() async {
    try {
      // 从可靠的 NTP 服务器获取真实网络时间 (设置 5 秒超时)
      DateTime networkTime = await NTP.now(
        lookUpAddress: 'time.google.com', // 也可用 'pool.ntp.org'
        timeout: const Duration(seconds: 5),
      );
      
      // 计算：偏差值 = 网络时间 - 手机当前假时间
      _timeOffset = networkTime.difference(DateTime.now());
      _isSynced = true;
      
      debugPrint("⏱️ Time Synced! Offset: ${_timeOffset.inSeconds} seconds.");
      
      // 如果偏差超过 5 分钟，说明用户可能篡改了时间
      if (_timeOffset.inMinutes.abs() > 5) {
        debugPrint("⚠️ Warning: System time has been tampered with!");
      }
    } catch (e) {
      debugPrint("❌ NTP Sync failed, using local time as fallback: $e");
      _isSynced = false; // 确保同步失败时状态正确
    }
  }

  /// 🟢 获取绝对真实的当前时间 (防篡改)
  static DateTime get now {
    // 手机本地时间 + 偏差值 = 真实时间
    return DateTime.now().add(_timeOffset);
  }
}