import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:camera/camera.dart';
import 'package:shared_preferences/shared_preferences.dart'; 
import 'package:flutter_riverpod/flutter_riverpod.dart'; // 🟢 1. 引入 Riverpod

import '../widgets/custom_profile_camera.dart';
import 'camera_screen.dart';
import 'attendance_screen.dart';
import 'settings_screen.dart';
import 'profile_screen.dart';
import 'leave_application_screen.dart';
import 'payslip_screen.dart';
import 'login_screen.dart'; 

import '../services/tracking_service.dart'; // 包含 trackingProvider 和 TrackingNotifier
import '../services/notification_service.dart';
import '../services/biometric_service.dart'; 

// 🟢 2. 将 StatefulWidget 改为 ConsumerStatefulWidget
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

// 🟢 3. 将 State 改为 ConsumerState
class _HomeScreenState extends ConsumerState<HomeScreen> {
  String _staffName = "Staff";
  String? _faceIdPhotoPath;

  StreamSubscription? _announcementSubscription;
  StreamSubscription? _userStatusSubscription; 

  @override
  void initState() {
    super.initState();
    _listenToUserStatus();

    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      NotificationService().startListeningToUserUpdates(user.uid);
    }
    
    _listenForAnnouncements(); 

    Future.delayed(const Duration(seconds: 1), _checkBiometricSetup);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAndResumeTracking();
    });
  }

  @override
  void dispose() {
    _announcementSubscription?.cancel();
    _userStatusSubscription?.cancel(); 
    super.dispose();
  }

  void _listenToUserStatus() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    _userStatusSubscription = FirebaseFirestore.instance
        .collection('users')
        .where('authUid', isEqualTo: user.uid)
        .limit(1)
        .snapshots()
        .listen((snapshot) async {
      
      if (snapshot.docs.isNotEmpty) {
        final data = snapshot.docs.first.data();

        final status = data['status'] ?? 'active';
        if (status == 'disabled' || status == 'inactive') {
          _forceLogout(status);
          return;
        }

        if (mounted) {
          setState(() {
            final personal = data['personal'] as Map<String, dynamic>?;
            if (personal != null) {
              if (personal['shortName'] != null && personal['shortName'].toString().isNotEmpty) {
                _staffName = personal['shortName'];
              } else if (personal['name'] != null) {
                _staffName = personal['name'];
              }
              _cacheUserName(_staffName);
            }

            if (data['faceIdPhoto'] != null) {
              _faceIdPhotoPath = data['faceIdPhoto'];
            }
          });
        }
      } else {
        _forceLogout('not_found');
      }
    }, onError: (error) {
      debugPrint("Error listening to user status: $error");
    });
  }

  Future<void> _forceLogout(String reason) async {
    _userStatusSubscription?.cancel(); 
    
    // 🟢 4. 使用 Riverpod 的 ref 读取并停止追踪
    try {
      ref.read(trackingProvider.notifier).stopTracking(); 
    } catch (e) {
      debugPrint("Error stopping tracking on force logout: $e");
    }
    
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();

    await FirebaseAuth.instance.signOut();

    if (!mounted) return;

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
          reason == 'disabled' 
            ? "Your account has been disabled by the administrator."
            : "Your account credentials have been reset or removed. Please contact HR or log in again.",
          style: const TextStyle(fontSize: 15),
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            onPressed: () {
              Navigator.of(ctx).pop();
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

  void _listenForAnnouncements() {
    _announcementSubscription = FirebaseFirestore.instance
        .collection('announcements')
        .orderBy('createdAt', descending: true)
        .limit(1)
        .snapshots()
        .listen((snapshot) async {
      if (snapshot.docs.isEmpty) return;

      final data = snapshot.docs.first.data();
      final String message = data['message'] ?? '';
      final Timestamp? createdAt = data['createdAt'];
      
      if (createdAt == null || message.isEmpty) return;

      final prefs = await SharedPreferences.getInstance();
      final lastShownTime = prefs.getInt('last_announcement_time') ?? 0;
      
      if (createdAt.millisecondsSinceEpoch > lastShownTime) {
        
        await prefs.setInt('last_announcement_time', createdAt.millisecondsSinceEpoch);
        
        if (mounted) {
          showDialog(
            context: context,
            builder: (context) => AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
              title: Row(
                children: [
                  const Icon(Icons.campaign, color: Colors.orange),
                  const SizedBox(width: 10),
                  Text('announcement.title'.tr()), 
                ],
              ),
              content: SingleChildScrollView(
                child: Text(
                  message, 
                  style: const TextStyle(fontSize: 15),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text("OK"),
                ),
              ],
            ),
          );
        }
      }
    });
  }

  Future<void> _checkBiometricSetup() async {
    final prefs = await SharedPreferences.getInstance();

    bool hasAsked = prefs.getBool('has_asked_biometrics') ?? false; 
    bool isEnabled = prefs.getBool('biometric_enabled') ?? false;   

    if (hasAsked || isEnabled) return;

    bool isHardwareSupported = await BiometricService().isDeviceSupported();
    if (!isHardwareSupported) return; 

    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text('settings.biometric_lock'.tr()),
        content: Text('login.ask_biometric_desc'.tr()), 
        actions: [
          TextButton(
            onPressed: () async {
              await prefs.setBool('has_asked_biometrics', true);
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: Text('login.btn_later'.tr(), style: const TextStyle(color: Colors.grey)),
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
            },
            child: Text('login.btn_enable'.tr()),
          ),
        ],
      ),
    );
  }

  void _checkAndResumeTracking() {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      // 🟢 5. 使用 Riverpod ref 恢复追踪
      ref.read(trackingProvider.notifier).resumeTrackingSession(user.uid);
    }
  }

  Future<void> _cacheUserName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('cached_staff_name', name);
  }

  Future<void> _openCustomCamera() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final XFile? photo = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const CustomProfileCamera()),
    );

    if (photo == null) return;

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('home.msg_uploading'.tr()))
      );
    }

    try {
      final String fileName = 'face_id_${user.uid}.jpg';
      final Reference storageRef = FirebaseStorage.instance
          .ref()
          .child('user_faces')
          .child(fileName);

      await storageRef.putFile(File(photo.path));
      final String downloadUrl = await storageRef.getDownloadURL();

      final q = await FirebaseFirestore.instance
          .collection('users')
          .where('authUid', isEqualTo: user.uid)
          .limit(1)
          .get();

      if (q.docs.isNotEmpty) {
        await q.docs.first.reference.update({
          'faceIdPhoto': downloadUrl,
          'hasFaceId': true,
          'lastFaceUpdate': FieldValue.serverTimestamp(),
        });

        if (mounted) {
          setState(() {
            _faceIdPhotoPath = downloadUrl;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('profile.save_success'.tr()),
              backgroundColor: Colors.green,
            )
          );
        }
      }
    } catch (e) {
      debugPrint("Error updating photo: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("${'home.msg_upload_fail'.tr()}: $e"), backgroundColor: Colors.red)
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ImageProvider? profileImage;
    if (_faceIdPhotoPath != null && _faceIdPhotoPath!.isNotEmpty) {
      if (_faceIdPhotoPath!.startsWith('http')) {
        profileImage = NetworkImage(_faceIdPhotoPath!);
      } else {
        final file = File(_faceIdPhotoPath!);
        if (file.existsSync()) {
          profileImage = FileImage(file);
        }
      }
    }

    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(
        title: Text('home.app_title'.tr()),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: GestureDetector(
              onTap: _openCustomCamera,
              child: Container(
                margin: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withValues(alpha:0.1), blurRadius: 4)
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
            child: Row(
              children: [
                const SizedBox(width: 15),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('home.welcome'.tr(), style: const TextStyle(color: Colors.white70)),
                    Text(
                      _staffName,
                      style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)
                    ),
                  ],
                ),
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
              children: [
                _buildMenuCard(
                  context,
                  'home.att_center'.tr(),
                  Icons.access_time_filled,
                  Colors.orange,
                  isEnabled: true,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => const AttendanceScreen())
                    );
                  },
                ),

                _buildMenuCard(
                  context,
                  'home.apply_leave'.tr(),
                  Icons.calendar_month_outlined,
                  Colors.green,
                  isEnabled: true,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => const LeaveApplicationScreen())
                    );
                  },
                ),

                _buildMenuCard(
                  context,
                  'home.smart_cam'.tr(),
                  Icons.camera_alt_outlined,
                  Colors.blue,
                  isEnabled: true,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => const CameraScreen())
                    );
                  },
                ),

                _buildMenuCard(
                  context,
                  'home.payslip'.tr(),
                  Icons.receipt_long,
                  Colors.pink,
                  isEnabled: true,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => const PayslipScreen())
                    );
                  },
                ),

                _buildMenuCard(
                  context,
                  'home.profile'.tr(),
                  Icons.person,
                  Colors.purple,
                  isEnabled: true,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => const ProfileScreen())
                    );
                  },
                ),

              ],
            ),
          ),
        ],
      ),
    );
  }

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
              color: Colors.grey.withValues(alpha:0.1),
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
                    color: isEnabled ? color.withValues(alpha:0.1) : Colors.grey.withValues(alpha:0.3),
                    shape: BoxShape.circle
                  ),
                  child: Icon(icon, color: isEnabled ? color : Colors.grey, size: 35),
                ),
                const SizedBox(height: 15),
                Center(
                  child: Text(
                    title,
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