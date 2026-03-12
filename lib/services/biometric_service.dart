import 'package:local_auth/local_auth.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
class BiometricService {
  final LocalAuthentication _auth = LocalAuthentication();

  // 🟢 1. 新增：仅检查设备是否支持（不弹出验证框）
  Future<bool> isDeviceSupported() async {
    try {
      final bool canCheckBiometrics = await _auth.canCheckBiometrics;
      final bool isDeviceSupported = await _auth.isDeviceSupported();
      return canCheckBiometrics && isDeviceSupported;
    } catch (e) {
      return false;
    }
  }

  // 2. 原有验证逻辑
  Future<bool> authenticateStaff() async {
    try {
      // Check support again just in case
      if (!await isDeviceSupported()) return false;

      // Trigger UI
      return await _auth.authenticate(
        localizedReason: 'Please verify your identity',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: true,
        ),
      );
    } on PlatformException catch (e) {
      debugPrint("Biometric Error: $e");
      return false;
    }
  }
}