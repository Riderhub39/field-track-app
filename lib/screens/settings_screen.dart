import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:easy_localization/easy_localization.dart';

import 'package:field_track_app/screens/login_screen.dart';
import 'package:field_track_app/screens/change_password_screen.dart';
import 'package:field_track_app/screens/announcement_screen.dart';

// 🟢 引入控制器
import 'settings_controller.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(settingsProvider);

    // 🟢 监听状态改变 (退出登录 或 开启生物识别提示)
    ref.listen<SettingsState>(settingsProvider, (previous, next) {
      if (next.isLoggedOut && !(previous?.isLoggedOut ?? false)) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const LoginScreen()),
          (route) => false
        );
      }

      if (next.biometricEnabled && !(previous?.biometricEnabled ?? false)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('settings.biometric_on_msg'.tr())),
        );
      }
    });

    if (state.isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final Map<String, String> languages = {
      'en': 'English',
      'ms': 'Bahasa Melayu',
      'zh': '中文 (Chinese)',
    };

    return Scaffold(
      appBar: AppBar(
        title: Text('settings.title'.tr()),
        backgroundColor: Colors.white,
        elevation: 0,
        foregroundColor: Colors.black,
      ),
      backgroundColor: Colors.grey[50],
      body: ListView(
        children: [
          // 1. App Settings Section
          _buildSectionHeader('settings.header_app'.tr()),
          
          ListTile(
            leading: const Icon(Icons.campaign, color: Colors.orange),
            title: const Text('Announcements'), 
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AnnouncementScreen())),
          ),

          const Divider(),

          SwitchListTile(
            title: Text('settings.biometric_lock'.tr()),
            subtitle: Text('settings.biometric_desc'.tr()),
            value: state.biometricEnabled,
            onChanged: (val) => ref.read(settingsProvider.notifier).toggleBiometric(val),
            secondary: const Icon(Icons.fingerprint, color: Colors.blue),
            activeTrackColor: Colors.blue, 
            activeThumbColor: Colors.white, 
          ),
          
          const Divider(),

          SwitchListTile(
            title: Text('settings.notifications'.tr()),
            subtitle: Text('settings.notif_desc'.tr()),
            value: state.notificationsEnabled,
            onChanged: (val) => ref.read(settingsProvider.notifier).toggleNotifications(val),
            secondary: const Icon(Icons.notifications_active, color: Colors.orange),
            activeTrackColor: Colors.orange,
            activeThumbColor: Colors.white,
          ),

          const Divider(),

          ListTile(
            leading: const Icon(Icons.language, color: Colors.purple),
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

          // 2. Account Section
          _buildSectionHeader('settings.header_account'.tr()),
          ListTile(
            leading: const Icon(Icons.lock_reset, color: Colors.grey),
            title: Text('settings.change_pw'.tr()),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ChangePasswordScreen())),
          ),
          
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.red),
            title: Text('settings.logout'.tr(), style: const TextStyle(color: Colors.red)),
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
        style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.grey[600]),
      ),
    );
  }
}