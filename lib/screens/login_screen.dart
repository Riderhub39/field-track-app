import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:easy_localization/easy_localization.dart';

import '../screens/home_screen.dart';
import 'register_screen.dart';

// 🟢 引入控制器
import 'login_controller.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  final TextEditingController _inputController = TextEditingController();
  final TextEditingController _passController = TextEditingController();
  final TextEditingController _honeyPotController = TextEditingController();

  @override
  void dispose() {
    _inputController.dispose();
    _passController.dispose();
    _honeyPotController.dispose();
    super.dispose();
  }

  void _navigateToHome() {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
      (route) => false
    );
  }

  void _showBiometricDialog() {
    showDialog(
      context: context,
      barrierDismissible: false, 
      builder: (ctx) => AlertDialog(
        title: Text('settings.biometric_lock'.tr()), 
        content: const Text("Enable Fingerprint/Face ID for faster login next time?"), 
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              ref.read(loginProvider.notifier).declineBiometrics();
            },
            child: const Text("No Thanks", style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx); 
              ref.read(loginProvider.notifier).enableBiometrics();
            },
            child: const Text("Enable"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(loginProvider);

    // 🟢 监听 Controller 的状态事件进行界面跳转或弹窗
    ref.listen<LoginState>(loginProvider, (previous, next) {
      if (next.errorMessage != null && next.errorMessage != previous?.errorMessage) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(next.errorMessage!.tr()), backgroundColor: Colors.red));
        ref.read(loginProvider.notifier).clearMessages();
      }

      if (next.successMessage != null && next.successMessage != previous?.successMessage) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(next.successMessage!.tr()), backgroundColor: Colors.green));
        ref.read(loginProvider.notifier).clearMessages();
      }

      if (next.shouldShowBiometricPrompt && !(previous?.shouldShowBiometricPrompt ?? false)) {
        _showBiometricDialog();
      }

      if (next.shouldNavigateToHome && !(previous?.shouldNavigateToHome ?? false)) {
        _navigateToHome();
      }
    });

    // 计算按钮上显示的锁定剩余时间
    int lockedMinutes = 0;
    if (state.lockoutTime != null) {
      lockedMinutes = state.lockoutTime!.difference(DateTime.now()).inMinutes + 1;
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
                
                // 🍯 蜜罐字段 (防机器爬虫抓取)
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
                  obscureText: state.isObscured,
                  decoration: InputDecoration(
                    labelText: 'login.password_hint'.tr(),
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.lock),
                    suffixIcon: IconButton(
                      icon: Icon(state.isObscured ? Icons.visibility : Icons.visibility_off),
                      onPressed: () => ref.read(loginProvider.notifier).toggleObscure(),
                    ),
                  ),
                  validator: (value) => (value == null || value.isEmpty) ? 'register.error_required'.tr() : null,
                ),
                const SizedBox(height: 24),
                
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    onPressed: (state.isLoading || state.lockoutTime != null) ? null : () {
                      if (_formKey.currentState!.validate()) {
                        ref.read(loginProvider.notifier).login(
                          _inputController.text, 
                          _passController.text, 
                          _honeyPotController.text
                        );
                      }
                    }, 
                    style: ElevatedButton.styleFrom(
                      backgroundColor: state.lockoutTime != null ? Colors.grey : null
                    ),
                    child: state.isLoading 
                      ? const CircularProgressIndicator(color: Colors.white) 
                      : Text(state.lockoutTime != null 
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