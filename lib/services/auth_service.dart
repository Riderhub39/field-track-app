import 'dart:async';
import 'dart:io';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart'; 
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  // 1. Get current user data (Needed for Home Screen)
  Future<Map<String, dynamic>?> getCurrentUserData() async {
    try {
      User? user = _auth.currentUser;
      if (user != null) {
        DocumentSnapshot doc = await _db
            .collection('users')
            .doc(user.uid)
            .get();
        return doc.data() as Map<String, dynamic>?;
      }
      return null;
    } catch (e) {
      debugPrint("Error fetching user data: $e");
      return null;
    }
  }

  // 2. Login with Username
  Future<User?> loginWithUsername(String username, String password) async {
    try {
      String email = "${username.trim()}@fieldtrack.com";
      UserCredential result = await _auth.signInWithEmailAndPassword(
        email: email, 
        password: password
      );
      
      // 🟢 登录成功后，自动更新当前设备 ID 到数据库
      if (result.user != null) {
        await updateDeviceIdOnLogin(result.user!.uid);
      }
      
      return result.user;
    } catch (e) {
      debugPrint("Login Error: ${e.toString()}");
      return null;
    }
  }

  // 3. Get Phone Number for WhatsApp Support
  Future<String?> getPhoneNumber(String username) async {
    try {
      final snapshot = await _db
          .collection('users')
          .where('username', isEqualTo: username.trim())
          .limit(1)
          .get();

      if (snapshot.docs.isNotEmpty) {
        return snapshot.docs.first.get('phone') as String;
      }
      return null;
    } catch (e) {
      debugPrint("Error fetching phone: $e");
      return null;
    }
  }

  // 4. Register with Username
  Future<User?> registerWithUsername(String username, String password) async {
    try {
      String email = "${username.trim()}@fieldtrack.com";
      UserCredential result = await _auth.createUserWithEmailAndPassword(
        email: email, 
        password: password
      );
      return result.user;
    } catch (e) {
      debugPrint("Registration Error: ${e.toString()}");
      return null;
    }
  }

  // 5. Sign Out
  Future<void> signOut() async => await _auth.signOut();

  // =========================================================
  // 🟢 单设备登录限制逻辑 (Single Device Login)
  // =========================================================

  // 获取当前硬件设备的唯一 ID
  Future<String> _getDeviceId() async {
    final DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
    String deviceId = 'unknown_device';

    try {
      if (Platform.isAndroid) {
        AndroidDeviceInfo androidInfo = await deviceInfo.androidInfo;
        deviceId = androidInfo.id; 
      } else if (Platform.isIOS) {
        IosDeviceInfo iosInfo = await deviceInfo.iosInfo;
        deviceId = iosInfo.identifierForVendor ?? 'unknown_ios_device'; 
      }
    } catch (e) {
      debugPrint("Failed to get device ID: $e");
    }
    return deviceId;
  }

  // 更新设备 ID 到用户的 Firestore 文档中
  Future<void> updateDeviceIdOnLogin(String uid) async {
    try {
      String deviceId = await _getDeviceId();
      
      // 兼容两种不同的 UID 绑定方式 (authUid 字段或直接使用 doc id)
      final querySnapshot = await _db.collection('users').where('authUid', isEqualTo: uid).limit(1).get();
      
      if (querySnapshot.docs.isNotEmpty) {
        await querySnapshot.docs.first.reference.update({
          'currentDeviceId': deviceId,
          'lastLoginTime': FieldValue.serverTimestamp(),
        });
      } else {
        await _db.collection('users').doc(uid).set({
          'currentDeviceId': deviceId,
          'lastLoginTime': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }
      debugPrint("📱 Device ID updated: $deviceId");
    } catch (e) {
      debugPrint("Error updating device ID: $e");
    }
  }

  // 持续监听设备 ID 是否发生变化
  Stream<bool> listenForDeviceKickOut(String uid) async* {
    String currentDeviceId = await _getDeviceId();
    
    yield* _db.collection('users').where('authUid', isEqualTo: uid).snapshots().map((snapshot) {
      if (snapshot.docs.isNotEmpty) {
        final data = snapshot.docs.first.data();
        String? remoteDeviceId = data['currentDeviceId'];
        
        // 如果云端的设备 ID 和当前设备的 ID 不一致，说明账号在别处登录了
        if (remoteDeviceId != null && remoteDeviceId != currentDeviceId) {
          debugPrint("⚠️ Account logged in on another device!");
          return true; // 返回 true 触发踢出逻辑
        }
      }
      return false; 
    });
  }

  // 执行强制登出并弹窗提示
  Future<void> forceLogout(BuildContext context) async {
    await signOut();
    
    // 清除生物识别等本地敏感缓存
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('biometricEnabled'); 
    
    if (context.mounted) {
      showDialog(
        context: context,
        barrierDismissible: false, 
        builder: (ctx) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.orange),
              SizedBox(width: 10),
              Text("Session Expired"),
            ],
          ),
          content: const Text("Your account has been logged in on another device.\nYou have been logged out for security reasons."),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                // 清理所有路由栈并跳转回登录页，请确保 '/' 是你的登录路由
                Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false); 
              },
              child: const Text("OK"),
            ),
          ],
        ),
      );
    }
  }
}