import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:easy_localization/easy_localization.dart';

import 'package:field_track_app/screens/login_screen.dart';
import 'package:field_track_app/screens/change_password_screen.dart';

// 🟢 引入控制器
import 'settings_controller.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(settingsProvider);

    // 🟢 监听状态改变 (退出登录、消息提示 或 开启生物识别提示)
    ref.listen<SettingsState>(settingsProvider, (previous, next) {
      
      // 监听退出登录
      if (next.isLoggedOut && !(previous?.isLoggedOut ?? false)) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const LoginScreen()),
          (route) => false
        );
      }

      // 监听生物识别开启
      if (next.biometricEnabled && !(previous?.biometricEnabled ?? false)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('settings.biometric_on_msg'.tr())),
        );
      }

      // 🚀 监听更新检查的消息提示 (成功/失败)
      if (next.successMessage != null && next.successMessage != previous?.successMessage) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(next.successMessage!), backgroundColor: Colors.green),
        );
      }
      if (next.errorMessage != null && next.errorMessage != previous?.errorMessage) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(next.errorMessage!), backgroundColor: Colors.red),
        );
      }
    });

    final Map<String, String> languages = {
      'en': 'English',
      'zh': '中文',
      'ms': 'Bahasa Melayu',
    };

    return Scaffold(
      appBar: AppBar(
        title: Text('settings.title'.tr()),
        centerTitle: true,
      ),
      body: ListView(
        children: [
          // ==============================
          // 1. General Section
          // ==============================
          _buildSectionHeader('settings.header_general'.tr()),
          
          // --- 语言设置 ---
          ListTile(
            leading: const Icon(Icons.language, color: Colors.blue),
            title: Text('settings.language'.tr()),
            trailing: DropdownButton<String>(
              value: context.locale.languageCode,
              underline: Container(),
              items: languages.entries.map((entry) {
                return DropdownMenuItem(value: entry.key, child: Text(entry.value));
              }).toList(),
              onChanged: (langCode) async {
                if (langCode != null) {
                  await context.setLocale(Locale(langCode));
                }
              },
            ),
          ),

          // --- 开启/关闭 通知 ---
          SwitchListTile(
            secondary: const Icon(Icons.notifications, color: Colors.orange),
            title: Text('settings.notifications'.tr()),
            value: state.notificationsEnabled,
            onChanged: (bool value) {
              ref.read(settingsProvider.notifier).toggleNotifications(value);
            },
          ),

          // --- 开启/关闭 生物识别 ---
          SwitchListTile(
            secondary: const Icon(Icons.fingerprint, color: Colors.green),
            title: Text('settings.biometric'.tr()),
            value: state.biometricEnabled,
            onChanged: (bool value) {
              ref.read(settingsProvider.notifier).toggleBiometric(value);
            },
          ),

          // 🚀 新增：检查更新 ---
          ListTile(
            leading: const Icon(Icons.system_update_alt, color: Colors.blue),
            title: const Text('Check for Updates'), 
            subtitle: const Text('Ensure you have the latest version'),
            trailing: state.isLoading 
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.chevron_right),
            onTap: state.isLoading ? null : () {
              ref.read(settingsProvider.notifier).checkForUpdate(context);
            },
          ),

          // ==============================
          // 2. Account Section
          // ==============================
          _buildSectionHeader('settings.header_account'.tr()),
          
          ListTile(
            leading: const Icon(Icons.lock_reset, color: Colors.grey),
            title: Text('settings.change_pw'.tr()),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ChangePasswordScreen())),
          ),
          
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.red),
            title: Text('settings.logout'.tr(), style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
            onTap: () => ref.read(settingsProvider.notifier).logout(),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: Colors.grey,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}