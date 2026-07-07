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
        // 🟢 FIXED: Translate authUid to the actual document
        final query = await _db.collection('users').where('authUid', isEqualTo: user.uid).limit(1).get();
        if (query.docs.isNotEmpty) {
          return query.docs.first.data();
        }
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
    try {
      final snapshot = await _db.collection('users').where('username', isEqualTo: username.trim()).limit(1).get();
      if (snapshot.docs.isNotEmpty) return snapshot.docs.first.get('phone') as String;
      return null;
    } catch (e) {
      return null;
    }
  }

  Future<User?> registerWithUsername(String username, String password) async {
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

  Future<void> updateDeviceIdOnLogin(String authUid) async {
    try {
      String deviceId = await _getDeviceId();
      await FileLogger.log("🚨 [AUTH] 当前设备ID: $deviceId");
      
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('local_session_device_id', deviceId);
      
      // 🟢 FIXED: Query by authUid to find the correct document, then update
      final query = await _db.collection('users').where('authUid', isEqualTo: authUid).limit(1).get();
      if (query.docs.isNotEmpty) {
        await query.docs.first.reference.update({'currentDeviceId': deviceId});
      } else {
        await FileLogger.log("🚨 [AUTH] 找不到对应的用户文档来更新设备ID");
      }
    } catch (e) {
      await FileLogger.log("🚨 [AUTH] 更新设备ID失败: $e");
    }
  }

  static const bool _isSyncing = false;

  Stream<bool> listenForDeviceKickOut(String authUid) async* {
    if (_isSyncing) yield false; 

    final prefs = await SharedPreferences.getInstance();
    String? localDeviceId = prefs.getString('local_session_device_id');
    
    if (localDeviceId == null) {
       await FileLogger.log("🚨 [AUTH] 本地 ID 为空，等待后续同步...");
       yield false; 
       return;
    }
    
    // 🟢 FIXED: Use where('authUid') to listen to the specific user's document changes
    yield* _db.collection('users').where('authUid', isEqualTo: authUid).limit(1).snapshots().map((snapshot) {
      if (snapshot.docs.isEmpty) return false;
      
      final doc = snapshot.docs.first;
      String? remoteDeviceId = doc.data()['currentDeviceId'];
      
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
        builder: (ctx) => PopScope(
          canPop: false, 
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