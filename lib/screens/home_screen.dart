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

// 🟢 引入控制器
import 'home_controller.dart'; 

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  // ========== UI Action Helpers ==========

  // 🟢 自动弹出的更新提示框
  void _showAutoUpdateDialog(BuildContext context, WidgetRef ref, String latestVersion, String releaseNotes, String apkUrl, bool forceUpdate) {
    showDialog(
      context: context,
      barrierDismissible: false, // 强制用户必须做出选择，不能点击背景关闭
      builder: (ctx) => PopScope(
        canPop: !forceUpdate,    // 只有非强制更新时才允许返回键关闭
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
            // 如果不是强制更新，显示 "Later" 按钮
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
                // 🟢 优化: 增加 try-catch 防止无浏览器设备导致崩溃
                try {
                  final Uri url = Uri.parse(apkUrl);
                  if (await canLaunchUrl(url)) {
                    await launchUrl(url, mode: LaunchMode.externalApplication);
                  } else {
                    debugPrint("Could not launch $apkUrl");
                  }
                } catch (e) {
                  debugPrint("Error launching URL: $e");
                }
                
                // 跨越 async 间隙后，使用 ctx 前必须检查 mounted
                if (!ctx.mounted) return;

                // 只有非强更时才允许关闭弹窗 (强更时保留弹窗，防止用户切回App继续使用)
                if (!forceUpdate) {
                  Navigator.pop(ctx);
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
                : "Your account credentials have been reset or removed. Please contact HR or log in again."),
          style: const TextStyle(fontSize: 15),
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red, 
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))
            ),
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
            Expanded(
              child: Text(
                title, 
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                overflow: TextOverflow.ellipsis,
              )
            ), 
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
                    // 🟢 优化: 增加 try-catch 保护
                    try {
                      final Uri url = Uri.parse(attachmentUrl);
                      if (await canLaunchUrl(url)) {
                        await launchUrl(url, mode: LaunchMode.externalApplication);
                      }
                    } catch (e) {
                      debugPrint("Error opening attachment: $e");
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                    decoration: BoxDecoration(
                      color: Colors.blue.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.blue.withValues(alpha: 0.3))
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('home.msg_uploading'.tr())));
      ref.read(homeProvider.notifier).uploadProfilePhoto(photo);
    }
  }

  // 🟢 提取的图像获取方法，使 build 更干净
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

    // 🟢 统一的弹窗/Toast 事件监听中心
    ref.listen<HomeState>(homeProvider, (previous, next) {
      // 版本更新
      if (next.shouldShowUpdatePrompt && !(previous?.shouldShowUpdatePrompt ?? false)) {
        _showAutoUpdateDialog(
          context, ref, next.updateLatestVersion ?? '', 
          next.updateReleaseNotes ?? '', next.updateApkUrl ?? '', next.forceUpdate
        );
      }
      // 踢下线或禁用
      if (next.shouldShowLogoutDialog && !(previous?.shouldShowLogoutDialog ?? false)) {
        _showLogoutDialog(context, next.logoutReason, ref);
      }
      // 系统公告
      if (next.shouldShowAnnouncement && !(previous?.shouldShowAnnouncement ?? false)) {
         _showAnnouncementDialog(context, next.announcementData!, ref);
      }
      // 生物识别
      if (next.shouldShowBiometricPrompt && !(previous?.shouldShowBiometricPrompt ?? false)) {
        _showBiometricDialog(context, ref);
      }
      // 提示信息
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
        elevation: 0, // 去除阴影，让 AppBar 和下方的 Header 完美融合
        scrolledUnderElevation: 0, 
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: GestureDetector(
              onTap: () => _openCustomCamera(context, ref),
              child: Container(
                margin: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 4)
                  ]
                ),
                child: CircleAvatar(
                  radius: 18,
                  backgroundColor: Colors.blue.shade700,
                  backgroundImage: profileImage,
                  child: profileImage == null
                      ? const Icon(Icons.add_a_photo, size: 20, color: Colors.white)
                      : null,
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'settings.title'.tr(),
            onPressed: () {
              Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()));
            },
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 顶部信息卡片
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: const BoxDecoration(
              color: Colors.blue,
              borderRadius: BorderRadius.only(
                bottomLeft: Radius.circular(30),
                bottomRight: Radius.circular(30),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('home.welcome'.tr(), style: const TextStyle(color: Colors.white70)),
                Text(
                  state.staffName,
                  style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)
                ),
              ],
            ),
          ),

          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 10),
            child: Text('home.menu_main'.tr(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ),

          // 主菜单网格
          Expanded(
            child: GridView.count(
              crossAxisCount: 2,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              crossAxisSpacing: 20,
              mainAxisSpacing: 20,
              childAspectRatio: 1.1, // 🟢 优化：加入比例，防止小屏幕文字溢出
              children: [
                _buildMenuCard(
                  context,
                  'home.att_center'.tr(),
                  Icons.access_time_filled,
                  Colors.orange,
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AttendanceScreen())),
                ),
                _buildMenuCard(
                  context,
                  'home.apply_leave'.tr(),
                  Icons.calendar_month_outlined,
                  Colors.green,
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LeaveApplicationScreen())),
                ),
                _buildMenuCard(
                  context,
                  'home.smart_cam'.tr(),
                  Icons.camera_alt_outlined,
                  Colors.blue,
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CameraScreen())),
                ),
                _buildMenuCard(
                  context,
                  'home.payslip'.tr(),
                  Icons.receipt_long,
                  Colors.pink,
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PayslipScreen())),
                ),
                _buildMenuCard(
                  context,
                  'home.profile'.tr(),
                  Icons.person,
                  Colors.purple,
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ProfileScreen())),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // 🟢 抽取方法构建 Menu 模块，保持代码整洁
  Widget _buildMenuCard(BuildContext context, String title, IconData icon, Color color, {required VoidCallback onTap, bool isEnabled = true}) {
    return InkWell(
      onTap: isEnabled ? onTap : () {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('home.soon'.tr()),
            duration: const Duration(seconds: 1),
            behavior: SnackBarBehavior.floating,
          ),
        );
      },
      borderRadius: BorderRadius.circular(20),
      child: Container(
        decoration: BoxDecoration(
          color: isEnabled ? Colors.white : Colors.grey[200],
          borderRadius: BorderRadius.circular(20),
          boxShadow: isEnabled ? [
            BoxShadow(
              color: Colors.grey.withValues(alpha: 0.1),
              blurRadius: 10,
              spreadRadius: 2,
              offset: const Offset(0, 5),
            ),
          ] : [],
        ),
        child: Stack(
          children: [
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(15),
                  decoration: BoxDecoration(
                    color: isEnabled ? color.withValues(alpha: 0.1) : Colors.grey.withValues(alpha: 0.3),
                    shape: BoxShape.circle
                  ),
                  child: Icon(icon, color: isEnabled ? color : Colors.grey, size: 35),
                ),
                const SizedBox(height: 15),
                Center(
                  child: Text(
                    title,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      color: isEnabled ? Colors.black : Colors.grey
                    )
                  ),
                ),
              ],
            ),
            if (!isEnabled)
              Positioned(
                top: 10,
                right: 10,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.grey[400],
                    borderRadius: BorderRadius.circular(10)
                  ),
                  child: Text(
                    'home.soon'.tr(),
                    style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold)
                  ),
                ),
              )
          ],
        ),
      ),
    );
  }
}