import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:easy_localization/easy_localization.dart';

// 🟢 引入控制器
import 'change_password_controller.dart';

class ChangePasswordScreen extends ConsumerStatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  ConsumerState<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends ConsumerState<ChangePasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  
  // Controllers
  final TextEditingController _currentController = TextEditingController();
  final TextEditingController _newController = TextEditingController();
  final TextEditingController _confirmController = TextEditingController();

  @override
  void dispose() {
    _currentController.dispose();
    _newController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Widget _buildPasswordField({
    required String label,
    required TextEditingController controller,
    required bool isObscure,
    required VoidCallback onToggle,
    String? Function(String?)? validator,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.blueGrey, fontSize: 13)),
        const SizedBox(height: 8),
        TextFormField(
          controller: controller,
          obscureText: isObscure,
          decoration: InputDecoration(
            hintText: label, 
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            suffixIcon: IconButton(
              icon: Icon(isObscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
              onPressed: onToggle,
            ),
          ),
          validator: validator,
        ),
        const SizedBox(height: 20),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(changePasswordProvider);

    // 🟢 监听状态改变以显示弹窗或关闭页面
    ref.listen<ChangePasswordState>(changePasswordProvider, (previous, next) {
      if (next.errorMessage != null && next.errorMessage != previous?.errorMessage) {
        // 如果是国际化的 key 就翻译，否则直接显示 Error 内容
        String msg = next.errorMessage!.contains('Error') ? next.errorMessage! : next.errorMessage!.tr();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.red));
        ref.read(changePasswordProvider.notifier).clearMessages();
      }

      if (next.successMessage != null && next.successMessage != previous?.successMessage) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(next.successMessage!.tr()), backgroundColor: Colors.green));
        ref.read(changePasswordProvider.notifier).clearMessages();
      }

      if (next.shouldPop && !(previous?.shouldPop ?? false)) {
        Navigator.pop(context);
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: Text('settings.change_pw'.tr()),
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.blue.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.lock_reset, size: 64, color: Colors.blue),
                ),
              ),
              const SizedBox(height: 30),

              Text(
                'change_pw.subtitle'.tr(), 
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)
              ),
              Text(
                'change_pw.desc'.tr(),
                style: const TextStyle(color: Colors.grey, fontSize: 14),
              ),
              const SizedBox(height: 30),

              // 1. Current Password
              _buildPasswordField(
                label: 'change_pw.current_label'.tr(),
                controller: _currentController,
                isObscure: state.obscureCurrent,
                onToggle: () => ref.read(changePasswordProvider.notifier).toggleObscureCurrent(),
                validator: (val) => (val == null || val.isEmpty) ? 'leave.error_required'.tr() : null,
              ),

              // 2. New Password
              _buildPasswordField(
                label: 'change_pw.new_label'.tr(),
                controller: _newController,
                isObscure: state.obscureNew,
                onToggle: () => ref.read(changePasswordProvider.notifier).toggleObscureNew(),
                validator: (val) {
                  if (val == null || val.length < 6) return 'register.pw_too_short'.tr();
                  if (val == _currentController.text) return 'change_pw.error_same'.tr();
                  return null;
                },
              ),

              // 3. Confirm Password
              _buildPasswordField(
                label: 'change_pw.confirm_label'.tr(),
                controller: _confirmController,
                isObscure: state.obscureConfirm,
                onToggle: () => ref.read(changePasswordProvider.notifier).toggleObscureConfirm(),
                validator: (val) {
                  if (val != _newController.text) return 'register.pw_mismatch'.tr();
                  return null;
                },
              ),

              const SizedBox(height: 20),

              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: state.isLoading ? null : () {
                    if (_formKey.currentState!.validate()) {
                      ref.read(changePasswordProvider.notifier).submitPasswordChange(
                        currentPassword: _currentController.text,
                        newPassword: _newController.text,
                      );
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: state.isLoading 
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : Text('change_pw.btn_submit'.tr(), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}