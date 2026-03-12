// home_screen.dart

import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:url_launcher/url_launcher.dart';

import '../widgets/custom_profile_camera.dart';
import 'camera_screen.dart';
import 'attendance_screen.dart';
import 'settings_screen.dart';
import 'profile_screen.dart';
import 'leave_application_screen.dart';
import 'payslip_screen.dart';
import 'login_screen.dart'; 
import 'home_controller.dart'; 

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  // ========== UI Action Helpers ==========

  void _showAutoUpdateDialog(BuildContext context, WidgetRef ref, String latestVersion, String releaseNotes, String apkUrl, bool forceUpdate) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: !forceUpdate,
        child: AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
          title: Row(
            children: [
              const Icon(Icons.new_releases, color: Colors.blue, size: 28),
              const SizedBox(width: 10),
              Text("Version $latestVersion", style: const TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("A new version is available!", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 12),
              const Text("What's New:", style: TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 4),
              Text(releaseNotes, style: const TextStyle(fontSize: 14)),
            ],
          ),
          actions: [
            if (!forceUpdate)
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  ref.read(homeProvider.notifier).dismissUpdatePrompt();
                }, 
                child: const Text("Later", style: TextStyle(color: Colors.grey)),
              ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
              onPressed: () async {
                try {
                  final Uri url = Uri.parse(apkUrl);
                  await launchUrl(url, mode: LaunchMode.externalApplication);
                } catch (e) {
                  debugPrint("Launch URL Failed: $e");
                }
                if (!forceUpdate) {
                  if (context.mounted) Navigator.pop(ctx);
                  ref.read(homeProvider.notifier).dismissUpdatePrompt();
                }
              },
              child: const Text("Update Now", style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }
  
  void _showLogoutDialog(BuildContext context, String reason, WidgetRef ref) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        title: const Row(
          children: [
            Icon(Icons.security, color: Colors.red),
            SizedBox(width: 10),
            Text("Access Denied", style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        content: Text(
          reason == 'kicked_out'
            ? "Your account was logged in from another device."
            : (reason == 'disabled' 
                ? "Your account has been disabled by the administrator."
                : "Your account credentials have been reset or removed."),
          style: const TextStyle(fontSize: 15),
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              Navigator.of(ctx).pop();
              ref.read(homeProvider.notifier).resetLogoutDialog();
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (context) => const LoginScreen()),
                (route) => false,
              );
            },
            child: const Text("OK", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showAnnouncementDialog(BuildContext context, Map<String, dynamic> data, WidgetRef ref) {
    final String title = data['title'] ?? 'settings.announcement_title'.tr(); 
    final String message = data['message'] ?? '';
    final String? attachmentUrl = data['attachmentUrl']; 

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        title: Row(
          children: [
            const Icon(Icons.campaign, color: Colors.orange),
            const SizedBox(width: 10),
            Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16), overflow: TextOverflow.ellipsis)), 
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(message, style: const TextStyle(fontSize: 15)),
              if (attachmentUrl != null && attachmentUrl.isNotEmpty) ...[
                const SizedBox(height: 15),
                const Divider(),
                const SizedBox(height: 5),
                InkWell(
                  onTap: () async {
                    try {
                      final Uri url = Uri.parse(attachmentUrl);
                      await launchUrl(url, mode: LaunchMode.externalApplication);
                    } catch (e) { debugPrint(e.toString()); }
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                    decoration: BoxDecoration(
                      color: Colors.blue.withValues(alpha:0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.blue.withValues(alpha:0.3))
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.attach_file, color: Colors.blue, size: 18),
                        SizedBox(width: 8),
                        Text("View Attachment", style: TextStyle(color: Colors.blue, fontWeight: FontWeight.bold, fontSize: 13)),
                      ],
                    ),
                  ),
                )
              ]
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              ref.read(homeProvider.notifier).resetAnnouncementDialog();
            },
            child: const Text("OK", style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showBiometricDialog(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text('settings.biometric_lock'.tr()),
        content: Text('login.ask_biometric_desc'.tr()), 
        actions: [
          TextButton(
            onPressed: () {
              ref.read(homeProvider.notifier).setBiometricLater();
              Navigator.pop(ctx);
            },
            child: Text('login.btn_later'.tr(), style: const TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx); 
              ref.read(homeProvider.notifier).enableBiometric();
            },
            child: Text('login.btn_enable'.tr()),
          ),
        ],
      ),
    );
  }

  Future<void> _openCustomCamera(BuildContext context, WidgetRef ref) async {
    final XFile? photo = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const CustomProfileCamera()),
    );
    if (!context.mounted) return;
    if (photo != null) {
      ref.read(homeProvider.notifier).uploadProfilePhoto(photo);
    }
  }

  ImageProvider? _getProfileImage(String? path) {
    if (path == null || path.isEmpty) return null;
    if (path.startsWith('http')) return NetworkImage(path);
    final file = File(path);
    if (file.existsSync()) return FileImage(file);
    return null;
  }

  // ========== Widget Build ==========

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(homeProvider);

    ref.listen<HomeState>(homeProvider, (previous, next) {
      if (next.shouldShowUpdatePrompt && !(previous?.shouldShowUpdatePrompt ?? false)) {
        _showAutoUpdateDialog(context, ref, next.updateLatestVersion ?? '', next.updateReleaseNotes ?? '', next.updateApkUrl ?? '', next.forceUpdate);
      }
      if (next.shouldShowLogoutDialog && !(previous?.shouldShowLogoutDialog ?? false)) {
        _showLogoutDialog(context, next.logoutReason, ref);
      }
      if (next.shouldShowAnnouncement && !(previous?.shouldShowAnnouncement ?? false)) {
         _showAnnouncementDialog(context, next.announcementData!, ref);
      }
      if (next.shouldShowBiometricPrompt && !(previous?.shouldShowBiometricPrompt ?? false)) {
        _showBiometricDialog(context, ref);
      }
      if (next.errorMessage != null && next.errorMessage != previous?.errorMessage) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(next.errorMessage!.tr()), backgroundColor: Colors.red));
        ref.read(homeProvider.notifier).clearMessages();
      }
      if (next.successMessage != null && next.successMessage != previous?.successMessage) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(next.successMessage!.tr()), backgroundColor: Colors.green));
        ref.read(homeProvider.notifier).clearMessages();
      }
    });

    final profileImage = _getProfileImage(state.faceIdPhotoPath);

    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(
        title: Text('home.app_title'.tr()),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0, 
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: GestureDetector(
              onTap: () => _openCustomCamera(context, ref),
              child: Container(
                margin: const EdgeInsets.all(8),
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)),
                child: CircleAvatar(
                  radius: 18,
                  backgroundColor: Colors.blue.shade700,
                  backgroundImage: profileImage,
                  child: profileImage == null ? const Icon(Icons.add_a_photo, size: 20, color: Colors.white) : null,
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: const BoxDecoration(
              color: Colors.blue,
              borderRadius: BorderRadius.only(bottomLeft: Radius.circular(30), bottomRight: Radius.circular(30)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('home.welcome'.tr(), style: const TextStyle(color: Colors.white70)),
                Text(state.staffName, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 10),
            child: Text('home.menu_main'.tr(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ),
          Expanded(
            child: GridView.count(
              crossAxisCount: 2,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              crossAxisSpacing: 20,
              mainAxisSpacing: 20,
              childAspectRatio: 1.1,
              children: [
                _buildMenuCard(context, 'home.att_center'.tr(), Icons.access_time_filled, Colors.orange, onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AttendanceScreen()))),
                _buildMenuCard(context, 'home.apply_leave'.tr(), Icons.calendar_month_outlined, Colors.green, onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LeaveApplicationScreen()))),
                _buildMenuCard(context, 'home.smart_cam'.tr(), Icons.camera_alt_outlined, Colors.blue, onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CameraScreen()))),
                _buildMenuCard(context, 'home.payslip'.tr(), Icons.receipt_long, Colors.pink, onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PayslipScreen()))),
                _buildMenuCard(context, 'home.profile'.tr(), Icons.person, Colors.purple, onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ProfileScreen()))),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMenuCard(BuildContext context, String title, IconData icon, Color color, {required VoidCallback onTap, bool isEnabled = true}) {
    return InkWell(
      onTap: isEnabled ? onTap : null,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        decoration: BoxDecoration(
          color: isEnabled ? Colors.white : Colors.grey[200],
          borderRadius: BorderRadius.circular(20),
          boxShadow: isEnabled ? [BoxShadow(color: Colors.grey.withValues(alpha:0.1), blurRadius: 10, spreadRadius: 2, offset: const Offset(0, 5))] : [],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(15),
              decoration: BoxDecoration(color: isEnabled ? color.withValues(alpha:0.1) : Colors.grey.withValues(alpha:0.3), shape: BoxShape.circle),
              child: Icon(icon, color: isEnabled ? color : Colors.grey, size: 35),
            ),
            const SizedBox(height: 15),
            Text(title, textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: isEnabled ? Colors.black : Colors.grey)),
          ],
        ),
      ),
    );
  }
}