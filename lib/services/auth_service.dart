import 'dart:async';
import 'dart:io';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart'; 
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/file_logger.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;



  Future<Map<String, dynamic>?> getCurrentUserData() async {
    try {
      User? user = _auth.currentUser;
      if (user != null) {
        DocumentSnapshot doc = await _db.collection('users').doc(user.uid).get();
        return doc.data() as Map<String, dynamic>?;
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  Future<User?> loginWithUsername(String username, String password) async {
    try {
      String email = "${username.trim()}@fieldtrack.com";
      UserCredential result = await _auth.signInWithEmailAndPassword(email: email, password: password);
      if (result.user != null) {
        await FileLogger.log("🚨 [AUTH] 登录成功: ${result.user!.uid}");
        await updateDeviceIdOnLogin(result.user!.uid);
      }
      return result.user;
    } catch (e) {
      await FileLogger.log("🚨 [AUTH] 登录失败: $e");
      return null;
    }
  }

  Future<String?> getPhoneNumber(String username) async {
    // 省略部分无关代码，保持原样...
    try {
      final snapshot = await _db.collection('users').where('username', isEqualTo: username.trim()).limit(1).get();
      if (snapshot.docs.isNotEmpty) return snapshot.docs.first.get('phone') as String;
      return null;
    } catch (e) {
      return null;
    }
  }

  Future<User?> registerWithUsername(String username, String password) async {
    // 保持原样...
    try {
      String email = "${username.trim()}@fieldtrack.com";
      UserCredential result = await _auth.createUserWithEmailAndPassword(email: email, password: password);
      return result.user;
    } catch (e) {
      return null;
    }
  }

  Future<void> signOut() async => await _auth.signOut();

  // =========================================================
  // 🟢 单设备登录限制逻辑 (Single Device Login)
  // =========================================================

  Future<String> _getDeviceId() async {
    final DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
    String deviceId = 'unknown_device';
    try {
      if (Platform.isAndroid) {
        AndroidDeviceInfo androidInfo = await deviceInfo.androidInfo;
        
        // 🟢 兼容方案：使用 brand + model + id 的组合，提高稳定性
        // 这样即使系统升级导致 id 变化，品牌和型号依然能保证标识的唯一性
        deviceId = "${androidInfo.brand}_${androidInfo.model}_${androidInfo.id}";
        
      } else if (Platform.isIOS) {
        IosDeviceInfo iosInfo = await deviceInfo.iosInfo;
        deviceId = iosInfo.identifierForVendor ?? 'unknown_ios_device'; 
      }
    } catch (e) {
      debugPrint("🚨 [AUTH DEBUG] 获取设备 ID 失败: $e");
    }
    return deviceId;
  }

  Future<void> updateDeviceIdOnLogin(String uid) async {
    try {
      String deviceId = await _getDeviceId();
      await FileLogger.log("🚨 [AUTH] 当前设备ID: $deviceId");
      
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('local_session_device_id', deviceId);
      
      await _db.collection('users').doc(uid).set({'currentDeviceId': deviceId}, SetOptions(merge: true));
    } catch (e) {
      await FileLogger.log("🚨 [AUTH] 更新设备ID失败: $e");
    }
  }

 static const bool _isSyncing = false;

  Stream<bool> listenForDeviceKickOut(String uid) async* {
    if (_isSyncing) yield false; // 如果正在同步，暂时不判定

    final prefs = await SharedPreferences.getInstance();
    String? localDeviceId = prefs.getString('local_session_device_id');
    
    // 如果本地还没 ID，说明还没完成首次同步，此时 yield false 并退出，不要触发任何逻辑
    if (localDeviceId == null) {
       await FileLogger.log("🚨 [AUTH] 本地 ID 为空，等待后续同步...");
       yield false; 
       return;
    }
    
    yield* _db.collection('users').doc(uid).snapshots().map((snapshot) {
      if (!snapshot.exists) return false;
      
      String? remoteDeviceId = snapshot.data()?['currentDeviceId'];
      
      // 🟢 关键：只有在非缓存状态下才进行 ID 比对！
      // 离线缓存经常含有旧数据，这在重启时极易造成误判
      if (snapshot.metadata.isFromCache) return false;

      if (remoteDeviceId != null && remoteDeviceId != localDeviceId) {
          FileLogger.log("🚨 [AUTH] ❌ ID 不匹配！本地: $localDeviceId, 云端: $remoteDeviceId");
          return true; 
      }
      return false; 
    });
  }

  Future<void> forceLogout(BuildContext context) async {
    await FileLogger.log("🚨 [AUTH] 执行 forceLogout (弹出被踢对话框)");
    
    await signOut();
    
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('biometric_enabled'); 
    await prefs.remove('local_session_device_id'); 
    await prefs.remove('cached_staff_name'); 
    
    if (context.mounted) {
      showDialog(
        context: context,
        barrierDismissible: false, 
        builder: (ctx) => PopScope( // ✅ 替换掉 WillPopScope
          canPop: false,           // ✅ canPop: false 等同于原先的 onWillPop: () async => false
          child: AlertDialog(
            title: const Text("Session Expired"),
            content: const Text("Your account has been logged in on another device or session expired."),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false); 
                },
                child: const Text("OK"),
              ),
            ],
          ),
        ),
      );
    }
  }
}