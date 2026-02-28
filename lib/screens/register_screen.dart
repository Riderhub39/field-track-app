import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:easy_localization/easy_localization.dart';

// 🟢 引入控制器
import 'register_controller.dart';

class RegisterScreen extends ConsumerStatefulWidget {
  final bool isResetPassword;
  const RegisterScreen({super.key, this.isResetPassword = false});

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  final TextEditingController _contactController = TextEditingController(); 
  final TextEditingController _otpController = TextEditingController();
  final TextEditingController _passController = TextEditingController();
  final TextEditingController _confirmPassController = TextEditingController();
  final TextEditingController _honeyPotController = TextEditingController();

  late bool _isResetMode;

  @override
  void initState() {
    super.initState();
    _isResetMode = widget.isResetPassword;
  }

  @override
  void dispose() {
    _contactController.dispose();
    _otpController.dispose();
    _passController.dispose();
    _confirmPassController.dispose();
    _honeyPotController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(registerProvider);

    // 🟢 监听状态改变以显示弹窗或关闭页面
    ref.listen<RegisterState>(registerProvider, (previous, next) {
      if (next.errorMessage != null && next.errorMessage != previous?.errorMessage) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(next.errorMessage!.tr()), backgroundColor: Colors.red));
        ref.read(registerProvider.notifier).clearMessages();
      }

      if (next.successMessage != null && next.successMessage != previous?.successMessage) {
        // 如果是发送成功的特定消息，带上 args 翻译
        if (next.successMessage == "register.otp_sent_success") {
           ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(next.successMessage!.tr(args: [next.maskedEmail ?? ""])), backgroundColor: Colors.green));
        } else {
           ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(next.successMessage!.tr()), backgroundColor: Colors.green));
        }
        ref.read(registerProvider.notifier).clearMessages();
      }

      if (next.shouldPop && !(previous?.shouldPop ?? false)) {
        Navigator.pop(context);
      }
    });

    return Scaffold(
      appBar: AppBar(title: Text(_isResetMode ? 'register.title_reset'.tr() : 'register.title_setup'.tr())),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Opacity(opacity: 0, child: SizedBox(height: 0, child: TextField(controller: _honeyPotController))), 

                // 🟢 顶部步骤条
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _buildStepIcon(1, Icons.person_search, state.currentStep), 
                    _buildLine(),
                    _buildStepIcon(2, Icons.lock_reset, state.currentStep),
                  ],
                ),
                const SizedBox(height: 30),

                // 🟢 Step 1: 验证身份 (Contact + OTP)
                if (state.currentStep == 1) ...[
                  Text(_isResetMode ? "register.enter_email_phone_reset".tr() : "register.enter_email_phone_activate".tr(), textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  
                  // 🟢 输入框 + 获取验证码按钮
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _contactController,
                          decoration: InputDecoration(
                            labelText: 'register.contact_label'.tr(), 
                            border: const OutlineInputBorder(), 
                            prefixIcon: const Icon(Icons.account_circle),
                            hintText: "Email / 012... / +86...",
                            contentPadding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
                          ),
                          onChanged: (val) {
                            if (state.otpSent) ref.read(registerProvider.notifier).resetOtpStatus();
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        height: 56, // 与输入框高度对齐
                        child: ElevatedButton(
                          onPressed: (state.isLoading && !state.otpSent) || state.cooldownSeconds > 0 
                            ? null 
                            : () => ref.read(registerProvider.notifier).generateOtp(_contactController.text, _isResetMode, _honeyPotController.text), 
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            backgroundColor: state.cooldownSeconds > 0 ? Colors.grey : Colors.blue
                          ),
                          child: state.isLoading && !state.otpSent
                            ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) 
                            : Text(
                                state.cooldownSeconds > 0 ? "${state.cooldownSeconds}s" : (state.otpSent ? "Resend" : "Get OTP"),
                                style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)
                              ),
                        ),
                      ),
                    ],
                  ),

                  // 🟢 OTP 输入区域 (发送成功后才显示)
                  if (state.otpSent) ...[
                    const SizedBox(height: 24),
                    const Divider(),
                    const SizedBox(height: 16),
                    
                    Text("register.enter_otp".tr(), textAlign: TextAlign.center, style: TextStyle(color: Colors.grey[700])),
                    if (state.maskedEmail != null) 
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Text("(${state.maskedEmail})", textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.blue)),
                      ),
                    
                    TextFormField(
                      controller: _otpController,
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 20, letterSpacing: 5),
                      decoration: InputDecoration(
                        labelText: 'register.otp_code'.tr(), 
                        border: const OutlineInputBorder(), 
                        prefixIcon: const Icon(Icons.pin),
                        hintText: "######"
                      ),
                    ),
                    const SizedBox(height: 24),
                    
                    SizedBox(
                      height: 50,
                      child: ElevatedButton.icon(
                        onPressed: state.isLoading ? null : () => ref.read(registerProvider.notifier).verifyOtp(_otpController.text), 
                        icon: const Icon(Icons.check_circle),
                        label: Text(state.isLoading ? "Verifying..." : "Verify & Proceed"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)
                        ),
                      ),
                    ),
                  ],
                ],

                // 🟢 Step 2: 设置密码
                if (state.currentStep == 2) ...[
                   Text(_isResetMode ? "register.reset_pw".tr() : "register.set_pw".tr(), textAlign: TextAlign.center),
                   const SizedBox(height: 20),
                   TextFormField(
                    controller: _passController,
                    obscureText: true,
                    decoration: InputDecoration(labelText: 'login.password_hint'.tr(), border: const OutlineInputBorder(), prefixIcon: const Icon(Icons.lock)),
                    validator: (v) => (v != null && v.length >= 6) ? null : 'register.pw_too_short'.tr(),
                  ),
                  const SizedBox(height: 16),
                   TextFormField(
                    controller: _confirmPassController,
                    obscureText: true,
                    decoration: InputDecoration(labelText: 'register.confirm_pw'.tr(), border: const OutlineInputBorder(), prefixIcon: const Icon(Icons.lock_clock)),
                    validator: (v) => (v != _passController.text) ? 'register.pw_mismatch'.tr() : null,
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    height: 50,
                    child: ElevatedButton(
                      onPressed: state.isLoading ? null : () {
                        if (_formKey.currentState!.validate()) {
                          ref.read(registerProvider.notifier).finalizeAccount(_passController.text, _isResetMode);
                        }
                      }, 
                      child: state.isLoading ? const CircularProgressIndicator(color: Colors.white) : Text("register.btn_activate".tr())
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStepIcon(int step, IconData icon, int currentStep) {
    bool isActive = currentStep >= step;
    return Column(
      children: [
        CircleAvatar(
          backgroundColor: isActive ? Colors.blue : Colors.grey[300],
          child: Icon(icon, color: isActive ? Colors.white : Colors.grey),
        ),
      ],
    );
  }
  
  Widget _buildLine() => Container(width: 60, height: 2, color: Colors.grey[300]);
}