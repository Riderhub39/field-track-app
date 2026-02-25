import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/biometric_service.dart';
import '../services/auth_service.dart'; // 🟢 引入 AuthService 以便调用更新 DeviceID 的方法
import '../screens/home_screen.dart';
import 'register_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  final TextEditingController _inputController = TextEditingController();
  final TextEditingController _passController = TextEditingController();
  final TextEditingController _honeyPotController = TextEditingController();

  bool _isObscured = true;
  bool _isLoading = false;

  // Rate Limiting Variables (State)
  int _failedAttempts = 0;
  DateTime? _lockoutTime;

  // Constants for SharedPreferences keys
  static const String _keyFailedAttempts = 'auth_failed_attempts';
  static const String _keyLockoutTime = 'auth_lockout_timestamp';

  @override
  void initState() {
    super.initState();
    // App 启动时立即加载本地的安全状态
    _loadSecurityState();
  }

  @override
  void dispose() {
    _inputController.dispose();
    _passController.dispose();
    _honeyPotController.dispose();
    super.dispose();
  }

  // 加载本地存储的安全状态
  Future<void> _loadSecurityState() async {
    final prefs = await SharedPreferences.getInstance();
    
    // 读取锁定时间戳
    final int? lockoutTimestamp = prefs.getInt(_keyLockoutTime);
    // 读取失败次数
    final int savedAttempts = prefs.getInt(_keyFailedAttempts) ?? 0;

    if (lockoutTimestamp != null) {
      final lockoutEnd = DateTime.fromMillisecondsSinceEpoch(lockoutTimestamp);
      
      if (DateTime.now().isBefore(lockoutEnd)) {
        // 如果锁定时间还没过，恢复锁定状态
        setState(() {
          _lockoutTime = lockoutEnd;
          _failedAttempts = savedAttempts;
        });
      } else {
        // 如果锁定时间已过，重置状态
        await _resetSecurityState();
      }
    } else {
      // 没有锁定，但可能有失败记录
      setState(() {
        _failedAttempts = savedAttempts;
      });
    }
  }

  // 登录成功，清除所有限制
  Future<void> _resetSecurityState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyFailedAttempts);
    await prefs.remove(_keyLockoutTime);
    setState(() {
      _failedAttempts = 0;
      _lockoutTime = null;
    });
  }

  // 记录失败并判断是否锁定
  Future<void> _recordLoginFailure() async {
    final prefs = await SharedPreferences.getInstance();
    
    setState(() {
      _failedAttempts++;
    });

    await prefs.setInt(_keyFailedAttempts, _failedAttempts);

    // 如果达到阈值 (5次)
    if (_failedAttempts >= 5) {
      final lockoutEnd = DateTime.now().add(const Duration(minutes: 5));
      setState(() {
        _lockoutTime = lockoutEnd;
      });
      // 存储锁定结束的时间戳 (毫秒)
      await prefs.setInt(_keyLockoutTime, lockoutEnd.millisecondsSinceEpoch);
    }
  }

  String _normalizePhone(String input) {
    String trimmed = input.trim();
    if (trimmed.startsWith('+')) {
      return trimmed.replaceAll(RegExp(r'\s+'), '');
    }
    String cleaned = trimmed.replaceAll(RegExp(r'\D'), '');
    if (cleaned.isEmpty) return "";
    if (cleaned.startsWith('60')) {
      return "+$cleaned";
    } else if (cleaned.startsWith('0')) {
      return "+60${cleaned.substring(1)}";
    } else {
      return "+60$cleaned";
    }
  }

  Future<void> _askForBiometrics(User user) async {
    final prefs = await SharedPreferences.getInstance();
    
    bool hasAsked = prefs.getBool('has_asked_biometrics') ?? false;
    bool isEnabled = prefs.getBool('biometric_enabled') ?? false;
    bool isHardwareSupported = await BiometricService().isDeviceSupported();

    if (!isHardwareSupported || isEnabled || hasAsked) {
      _navigateToHome();
      return;
    }

    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false, 
      builder: (ctx) => AlertDialog(
        title: Text('settings.biometric_lock'.tr()), 
        content: const Text("Enable Fingerprint/Face ID for faster login next time?"), 
        actions: [
          TextButton(
            onPressed: () async {
              await prefs.setBool('has_asked_biometrics', true);
              if (ctx.mounted) Navigator.pop(ctx);
              _navigateToHome();
            },
            child: const Text("No Thanks", style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx); 
              
              bool success = await BiometricService().authenticateStaff();
              
              if (success) {
                await prefs.setBool('biometric_enabled', true);
                await prefs.setBool('has_asked_biometrics', true);
                
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('settings.biometric_on_msg'.tr()), backgroundColor: Colors.green)
                  );
                }
              }
              _navigateToHome();
            },
            child: const Text("Enable"),
          ),
        ],
      ),
    );
  }

  void _navigateToHome() {
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
      (route) => false
    );
  }

  void _handleLogin() async {
    // 1. Honeypot & Rate Limit Check
    if (_honeyPotController.text.isNotEmpty) return;
    
    // 检查是否处于锁定状态
    if (_lockoutTime != null) {
      if (DateTime.now().isBefore(_lockoutTime!)) {
        final remaining = _lockoutTime!.difference(DateTime.now()).inMinutes;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Too many attempts. Try again in ${remaining + 1} minutes."),
            backgroundColor: Colors.red,
          )
        );
        return;
      } else {
        // 超时解锁，重置本地状态
        await _resetSecurityState();
      }
    }

    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      String input = _inputController.text.trim();
      String password = _passController.text.trim();
      String finalEmail = input;

      if (!input.contains('@') && RegExp(r'[0-9]').hasMatch(input)) {
         String formattedPhone = _normalizePhone(input);
         QuerySnapshot query = await _db.collection('users').where('personal.mobile', isEqualTo: formattedPhone).limit(1).get();
         
         if (query.docs.isEmpty) throw FirebaseAuthException(code: 'invalid-credential');
         
         final userData = query.docs.first.data() as Map<String, dynamic>;
         final personalData = userData['personal'] as Map<String, dynamic>?;
         
         if (personalData != null && personalData['email'] != null) {
           finalEmail = personalData['email'];
         } else {
           throw FirebaseAuthException(code: 'invalid-credential');
         }
      }

      UserCredential userCred = await _auth.signInWithEmailAndPassword(
        email: finalEmail, 
        password: password
      );
      
      // ✅ Success: Reset counter in local storage
      await _resetSecurityState();
      
      if (userCred.user != null) {
        // 🟢 【新增】一旦 Firebase 验证成功，更新设备 ID 以踢出旧设备
        await AuthService().updateDeviceIdOnLogin(userCred.user!.uid);

        QuerySnapshot statusQuery = await _db
            .collection('users')
            .where('authUid', isEqualTo: userCred.user!.uid)
            .limit(1)
            .get();

        if (statusQuery.docs.isNotEmpty) {
          final docData = statusQuery.docs.first.data() as Map<String, dynamic>;
          if ((docData['status'] ?? 'active') == 'disabled') {
            await _auth.signOut();
            throw FirebaseAuthException(code: 'user-disabled');
          }
        }
        
        await _askForBiometrics(userCred.user!);
      }

    } on FirebaseAuthException catch (e) {
      // Record failure to local storage
      await _recordLoginFailure();

      String message = "Login Failed";
      if (e.code == 'user-disabled') {
        message = "Account disabled by administrator.";
      } else if (['user-not-found', 'wrong-password', 'invalid-email', 'invalid-credential'].contains(e.code)) {
        message = "register.account_not_found".tr(); 
      }
      
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Connection Error.")));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 计算剩余锁定时间（分钟），用于显示在按钮上
    int lockedMinutes = 0;
    if (_lockoutTime != null) {
      lockedMinutes = _lockoutTime!.difference(DateTime.now()).inMinutes + 1;
    }

    return Scaffold(
      appBar: AppBar(title: Text('login.title'.tr())), 
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              children: [
                const Icon(Icons.account_circle, size: 80, color: Colors.blue),
                const SizedBox(height: 20),
                Opacity(opacity: 0.0, child: SizedBox(height: 0, width: 0, child: TextField(controller: _honeyPotController))),
                
                TextFormField(
                  controller: _inputController,
                  keyboardType: TextInputType.emailAddress, 
                  decoration: InputDecoration(
                    labelText: 'login.email_hint'.tr(), 
                    hintText: 'Email / 012... / +86...',
                    prefixIcon: const Icon(Icons.person),
                    border: const OutlineInputBorder(),
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) return 'register.error_empty'.tr();
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                
                TextFormField(
                  controller: _passController,
                  obscureText: _isObscured,
                  decoration: InputDecoration(
                    labelText: 'login.password_hint'.tr(),
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.lock),
                    suffixIcon: IconButton(
                      icon: Icon(_isObscured ? Icons.visibility : Icons.visibility_off),
                      onPressed: () => setState(() => _isObscured = !_isObscured),
                    ),
                  ),
                  validator: (value) => (value == null || value.isEmpty) ? 'register.error_required'.tr() : null,
                ),
                const SizedBox(height: 24),
                
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    onPressed: (_isLoading || _lockoutTime != null) ? null : _handleLogin, 
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _lockoutTime != null ? Colors.grey : null
                    ),
                    child: _isLoading 
                      ? const CircularProgressIndicator(color: Colors.white) 
                      : Text(_lockoutTime != null 
                          ? "Locked (${lockedMinutes}m)" 
                          : 'login.btn_login'.tr()),
                  ),
                ),
                
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (context) => const RegisterScreen(isResetPassword: true))),
                  child: Text('login.btn_forgot'.tr()),
                ),
                TextButton(
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (context) => const RegisterScreen())),
                  child: Text('login.btn_first_time'.tr(), style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}