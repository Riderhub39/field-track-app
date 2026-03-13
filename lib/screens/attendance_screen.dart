import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:camera/camera.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'; 

import '../widgets/shimmer_loading.dart';
import '../widgets/face_camera_view.dart';
import 'correction_request_screen.dart';
import 'attendance_controller.dart'; 

class AttendanceScreen extends ConsumerWidget {
  const AttendanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(attendanceProvider);

    // 🟢 统一监听器：处理 PDPA 弹窗及反馈消息
    ref.listen(attendanceProvider, (previous, next) {
      // 1. PDPA 定位授权询问
      if (next.shouldShowLocationConsent && !(previous?.shouldShowLocationConsent ?? false)) {
        _showPDPADialog(context, ref);
      }

      // 2. 成功打卡弹窗
      if (next.successMessage != null && next.successMessage != previous?.successMessage) {
        showDialog(
          context: context,
          barrierDismissible: false, 
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Row( 
              children: [
                Icon(Icons.check_circle, color: Colors.green, size: 28),
                SizedBox(width: 10),
                Text("Success!", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black87)),
              ],
            ),
            content: Text(
              next.successMessage!,
              style: const TextStyle(fontSize: 15, height: 1.4),
            ),
            actions: [
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                  backgroundColor: const Color(0xFF15438c),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: () {
                  Navigator.of(ctx).pop();
                },
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12.0),
                  child: Text("OK", style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        );
      }
      
      // 3. 错误消息提示
      if (next.errorMessage != null && next.errorMessage != previous?.errorMessage) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(next.errorMessage!), backgroundColor: Colors.red),
        );
      }
    });

    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Text("att.title".tr()),
          backgroundColor: const Color(0xFF15438c),
          foregroundColor: Colors.white,
          elevation: 0,
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 16.0),
              child: CircleAvatar(
                radius: 16,
                backgroundColor: Colors.grey.shade300,
                backgroundImage: state.appBarImage,
                child: state.appBarImage == null
                    ? const Icon(Icons.person, color: Colors.grey, size: 20)
                    : null,
              ),
            ),
          ],
        ),
        body: const TabBarView(
          physics: NeverScrollableScrollPhysics(),
          children: [
            AttendanceActionTab(),
            HistoryTab(),
            ScheduleTab(),
            SubmitTab(),
          ],
        ),
        bottomNavigationBar: Container(
          color: Colors.white,
          child: SafeArea(
            child: TabBar(
              labelColor: const Color(0xFF15438c),
              unselectedLabelColor: Colors.black,
              indicatorColor: const Color(0xFF15438c),
              indicatorSize: TabBarIndicatorSize.tab,
              tabs: [
                Tab(icon: const Icon(Icons.touch_app), text: "att.tab_clock_in".tr()),
                Tab(icon: const Icon(Icons.history), text: "att.tab_history".tr()),
                Tab(icon: const Icon(Icons.calendar_month), text: "att.tab_schedule".tr()),
                Tab(icon: const Icon(Icons.assignment_return), text: "att.tab_submit".tr()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // 🟢 模块：PDPA 定位授权询问弹窗
  void _showPDPADialog(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      barrierDismissible: false, // 强制用户做出选择
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.privacy_tip_outlined, color: Color(0xFF15438c), size: 28),
            const SizedBox(width: 10),
            // 🚀 核心修复：使用 Expanded 限制宽度并允许自动换行
            Expanded(
              child: Text(
                "att.pdpa_title".tr(), 
                style: const TextStyle(
                  fontWeight: FontWeight.bold, 
                  fontSize: 18, // 稍微调小字号，避免视觉冲击力过大
                ),
              ),
            ),
          ],
        ),
        content: Text(
          "att.pdpa_content".tr(),
          style: const TextStyle(fontSize: 14, height: 1.5),
        ),
        actions: [
          // 🟢 Ignore 按钮：点击后永久标记不再提醒
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              ref.read(attendanceProvider.notifier).completePDPAConsent(permanently: true);
            },
            child: Text("att.btn_ignore".tr(), style: const TextStyle(color: Colors.grey)),
          ),
          // 🟢 Consent 按钮：仅同意本次
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF15438c),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () {
              Navigator.pop(ctx);
              ref.read(attendanceProvider.notifier).completePDPAConsent(permanently: false);
            },
            child: Text("att.btn_consent".tr(), style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}

// ==========================================
//  Tab 1: Action Tab
// ==========================================
class AttendanceActionTab extends ConsumerStatefulWidget {
  const AttendanceActionTab({super.key});
  @override
  ConsumerState<AttendanceActionTab> createState() => _AttendanceActionTabState();
}

class _AttendanceActionTabState extends ConsumerState<AttendanceActionTab> {
  final Completer<GoogleMapController> _mapController = Completer();

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(attendanceProvider);

    if (state.isFetchingUser || state.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final now = DateTime.now();
    final displayDate = DateFormat('dd/MM/yyyy (EEE)', context.locale.languageCode).format(now);
    const whiteTextColor = Color(0xFFFFFFFF);
    const naviColor = Color(0xFF15438c);

    String actionDisplay = _getActionDisplayText(state.selectedAction);

    return SingleChildScrollView(
      child: Column(
        children: [
          Stack(
            alignment: Alignment.bottomCenter,
            children: [
              SizedBox(
                height: 180,
                width: double.infinity,
                child: state.initialPosition == null
                    ? Container(color: Colors.grey[300], child: const Center(child: CircularProgressIndicator()))
                    : GoogleMap(
                        mapType: MapType.normal,
                        initialCameraPosition: state.initialPosition!,
                        markers: state.markers,
                        myLocationEnabled: true,
                        zoomControlsEnabled: false,
                        onMapCreated: (GoogleMapController controller) {
                          if (!_mapController.isCompleted) {
                            _mapController.complete(controller);
                          }
                        },
                      ),
              ),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.only(topLeft: Radius.circular(16), topRight: Radius.circular(16)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.location_on, color: Colors.orange),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        state.currentAddress.tr(),
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            decoration: const BoxDecoration(
              color: naviColor,
              borderRadius: BorderRadius.only(
                bottomLeft: Radius.circular(24),
                bottomRight: Radius.circular(24),
              ),
            ),
            child: Column(
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const Icon(Icons.calendar_today, color: Colors.white, size: 20),
                      const SizedBox(height: 4),
                      Text(displayDate, style: const TextStyle(fontWeight: FontWeight.bold, color: whiteTextColor)),
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                Text(state.staffName, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: whiteTextColor)),
                Text(state.employeeId, style: const TextStyle(fontSize: 16, color: Colors.white)),

                const SizedBox(height: 20),
                const Divider(color: Colors.white54),
                const SizedBox(height: 15),

                Row(
                  children: [
                    Expanded(child: _buildActionTimeBox("att.label_in".tr(), state.todayInTime)),
                    const SizedBox(width: 12),
                    Expanded(child: _buildActionTimeBox("att.label_out".tr(), state.todayOutTime)),
                  ],
                ),

                const SizedBox(height: 30),

                GestureDetector(
                  onTap: state.isProcessingAction ? null : () => _showActionPicker(state),
                  child: Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: state.isProcessingAction ? Colors.grey : Colors.amber,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        if (!state.isProcessingAction)
                          BoxShadow(color: Colors.amber.withValues(alpha: 0.3), blurRadius: 10, offset: const Offset(0, 5))
                      ],
                      image: state.capturedPhoto != null
                          ? DecorationImage(image: FileImage(File(state.capturedPhoto!.path)), fit: BoxFit.cover)
                          : null,
                    ),
                    child: state.capturedPhoto == null
                        ? (state.isProcessingAction 
                            ? const Padding(padding: EdgeInsets.all(20.0), child: CircularProgressIndicator(color: Colors.white))
                            : const Icon(Icons.camera_alt_rounded, color: Colors.white, size: 40))
                        : null,
                  ),
                ),

                const SizedBox(height: 20),
                
                if (state.capturedPhoto == null && !state.isProcessingAction)
                  Text("att.hint_tap_camera".tr(), style: const TextStyle(color: Colors.white70, fontSize: 12)),

                const SizedBox(height: 20),

                SizedBox(
                  width: double.infinity,
                  height: 55,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      backgroundColor: (state.capturedPhoto != null && !state.isProcessingAction) ? whiteTextColor : Colors.grey.shade300,
                      foregroundColor: (state.capturedPhoto != null && !state.isProcessingAction) ? naviColor : Colors.grey.shade500,
                      elevation: (state.capturedPhoto != null && !state.isProcessingAction) ? 3 : 0,
                    ),
                    onPressed: state.isProcessingAction ? null : () {
                      if (state.capturedPhoto == null) {
                        showDialog(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: Row(
                              children: [
                                const Icon(Icons.camera_alt_outlined, color: Colors.orange),
                                const SizedBox(width: 10),
                                Text("att.dialog_photo_title".tr()),
                              ],
                            ),
                            content: Text("att.dialog_photo_content".tr()),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: Text("att.btn_ok".tr(), style: const TextStyle(color: Colors.blue)),
                              ),
                            ],
                          ),
                        );
                      } else {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text("att.msg_queueing".tr(args: [_getActionDisplayText(state.selectedAction)])),
                          backgroundColor: Colors.blue,
                          duration: const Duration(seconds: 2),
                        ));
                        ref.read(attendanceProvider.notifier).submitAttendance();
                      }
                    },
                    child: Text(
                      state.isProcessingAction 
                        ? "Processing..."
                        : (state.capturedPhoto != null 
                          ? "att.btn_confirm".tr(args: [actionDisplay])
                          : "att.btn_clock_attendance".tr()),
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showActionPicker(AttendanceState state) {
    if (state.lastPunchTime != null) {
      final difference = DateTime.now().difference(state.lastPunchTime!);
      if (difference.inMinutes < 5) {
        final waitMinutes = 5 - difference.inMinutes;
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.timer, color: Colors.orange),
                SizedBox(width: 10),
                Text("Action Locked"),
              ],
            ),
            content: Text("Please wait $waitMinutes more minutes before your next action to prevent duplicate records."),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("OK"))
            ],
          ),
        );
        return; 
      }
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true, 
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text("att.select_action".tr(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 20),
              
              _buildActionTile(
                title: "att.act_clock_in".tr(),
                subtitle: state.hasAnyRecord ? "att.sub_locked_submitted".tr() : "att.sub_start_shift".tr(),
                icon: Icons.login, color: Colors.green,
                isLocked: state.hasAnyRecord, 
                onTap: () => _handleAction("Clock In", state),
              ),
              const Divider(),
              _buildActionTile(
                title: "att.act_break_out".tr(),
                subtitle: state.hasClockedOut 
                    ? "Shift Ended" 
                    : ((state.lastSession == 'Break Out') ? "att.sub_locked_verified".tr() : "att.sub_lunch".tr()),
                icon: Icons.coffee, color: Colors.orange,
                isLocked: !state.hasAnyRecord || (state.lastSession == 'Break Out') || state.hasClockedOut,
                onTap: () => _handleAction("Break Out", state),
              ),
              _buildActionTile(
                title: "att.act_break_in".tr(),
                subtitle: state.hasClockedOut 
                    ? "Shift Ended" 
                    : ((state.lastSession == 'Break In') ? "att.sub_locked_verified".tr() : "att.sub_back_work".tr()),
                icon: Icons.work_history, color: Colors.blue,
                isLocked: !state.hasAnyRecord || (state.lastSession == 'Break In') || state.hasClockedOut || (state.lastSession != 'Break Out'),
                onTap: () => _handleAction("Break In", state),
              ),
              const Divider(),
              _buildActionTile(
                title: "att.act_clock_out".tr(),
                subtitle: state.hasClockedOut ? "att.sub_locked_verified".tr() : "att.sub_end_shift".tr(),
                icon: Icons.logout, color: Colors.red,
                isLocked: !state.hasAnyRecord || state.hasClockedOut,
                onTap: () => _handleAction("Clock Out", state),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildActionTile({required String title, required String subtitle, required IconData icon, required Color color, required bool isLocked, required VoidCallback onTap}) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: isLocked ? Colors.grey : color, 
        child: Icon(isLocked ? Icons.lock : icon, color: Colors.white)
      ),
      title: Text(title, style: TextStyle(color: isLocked ? Colors.grey : Colors.black, decoration: isLocked ? TextDecoration.lineThrough : null)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
      onTap: isLocked ? null : onTap,
      enabled: !isLocked,
    );
  }

  void _handleAction(String action, AttendanceState state) async {
    Navigator.pop(context); 
    final error = await ref.read(attendanceProvider.notifier).validateRestrictionsAndSetAction(action);
    
    if (!mounted) return;
    
    if (error != null) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text("Access Denied"), 
          content: Text(error),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("OK"))],
        ),
      );
      return; 
    }

    if (state.referenceFaceIdPath == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("att.err_no_face_id".tr())));
      return;
    }

    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => FaceCameraView(referencePath: state.referenceFaceIdPath))
    ); 

    if (!mounted) return;

    if (result == 'failed') {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Face mismatch. Please try again in better lighting."),
        backgroundColor: Colors.red,
        duration: Duration(seconds: 3),
      ));
      return;
    }

    if (result != null && result is XFile) {
      ref.read(attendanceProvider.notifier).setCapturedPhoto(result);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text("att.msg_photo_captured".tr(args: [_getActionDisplayText(action)])),
          backgroundColor: Colors.green));
    }
  }

  String _getActionDisplayText(String action) {
    if(action == "Clock In") return "att.act_clock_in".tr();
    if(action == "Break Out") return "att.act_break_out".tr();
    if(action == "Break In") return "att.act_break_in".tr();
    if(action == "Clock Out") return "att.act_clock_out".tr();
    return action;
  }

  Widget _buildActionTimeBox(String label, String time) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.white70)),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white24),
          ),
          child: Center(
            child: Text(time, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 18)),
          ),
        )
      ],
    );
  }
}

// ==========================================
//  Tab 2: History (保持不变)
// ==========================================
class HistoryTab extends StatefulWidget {
  const HistoryTab({super.key});
  @override
  State<HistoryTab> createState() => _HistoryTabState();
}
class _HistoryTabState extends State<HistoryTab> {
  bool _isDescending = true;
  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return const Center(child: Text("Please login"));

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 10),
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: Row(
                  children: [
                    Text("att.header_date".tr(), style: const TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(width: 4),
                    InkWell(
                      onTap: () => setState(() => _isDescending = !_isDescending),
                      child: Padding(
                        padding: const EdgeInsets.all(4.0),
                        child: Icon(_isDescending ? Icons.arrow_downward : Icons.arrow_upward, size: 16, color: const Color(0xFF15438c)),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(flex: 4, child: Text("att.header_address".tr(), style: const TextStyle(fontWeight: FontWeight.bold))),
              Expanded(flex: 2, child: Text("att.header_status".tr(), style: const TextStyle(fontWeight: FontWeight.bold), textAlign: TextAlign.right)),
            ],
          ),
        ),
        const Divider(height: 1),
        
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance.collection('attendance')
                .where('uid', isEqualTo: user.uid)
                .orderBy('timestamp', descending: _isDescending)
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) return const ShimmerLoadingList();
              
              final docs = (snapshot.data?.docs ?? []).where((d) {
                final data = d.data() as Map<String, dynamic>;
                final address = data['address']?.toString() ?? '';
                if (address.contains("Admin Manual") || address.contains("Admin Override") || address.contains("System Auto Clock Out")) return false;
                return true;
              }).toList();

              if (docs.isEmpty) return Center(child: Text("att.no_history".tr(), style: const TextStyle(color: Colors.grey)));

              return ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: docs.length,
                separatorBuilder: (ctx, i) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final data = docs[index].data() as Map<String, dynamic>;
                  final ts = (data['timestamp'] as Timestamp).toDate();
                  
                  String displayTime = DateFormat('HH:mm:ss', context.locale.languageCode).format(ts);
                  String displayDate = DateFormat('dd-MM-yyyy', context.locale.languageCode).format(ts);
                  String status = data['verificationStatus'] ?? 'Pending';
                  bool isArchived = status == 'Archived';

                  return Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isArchived ? Colors.grey.shade50 : Colors.white, 
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 3,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(displayDate, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: isArchived ? Colors.grey : Colors.black54)),
                              Text(displayTime, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: isArchived ? Colors.grey : Colors.black87, decoration: isArchived ? TextDecoration.lineThrough : null)), 
                            ],
                          ),
                        ),
                        Expanded(
                          flex: 4,
                          child: Text(
                            data['address'] ?? "Unknown",
                            style: TextStyle(fontSize: 12, color: isArchived ? Colors.grey : const Color(0xFF15438c)),
                            maxLines: 5, overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: _buildStatusIcon(status),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildStatusIcon(String status) {
    if (status == 'Verified' || status == 'Corrected' || status == 'Approved') return const Icon(Icons.check_circle, color: Colors.green, size: 20);
    if (status == 'Rejected') return const Icon(Icons.cancel, color: Colors.red, size: 20);
    if (status == 'Archived') return const Icon(Icons.history, color: Colors.grey, size: 20); 
    return const Icon(Icons.task_alt, color: Colors.black54, size: 20); 
  }
}

// ==========================================
//  Tab 3: Schedule Tab (保持不变)
// ==========================================
class ScheduleTab extends ConsumerStatefulWidget {
  const ScheduleTab({super.key});
  @override
  ConsumerState<ScheduleTab> createState() => _ScheduleTabState();
}
class _ScheduleTabState extends ConsumerState<ScheduleTab> {
  DateTime _currentStartDate = DateTime.now();

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _currentStartDate = now.subtract(Duration(days: now.weekday - 1));
  }

  void _changeWeek(int weeks) {
    setState(() => _currentStartDate = _currentStartDate.add(Duration(days: 7 * weeks)));
  }

  String _formatDuration(Duration d) {
    int h = d.inMinutes ~/ 60;
    int m = d.inMinutes % 60;
    return "${h}h ${m}m";
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(attendanceProvider);
    if (state.isFetchingUser) return const Center(child: CircularProgressIndicator());
    if (state.myEmpCode.isEmpty) return Center(child: Text("att.err_profile_not_linked".tr()));

    final user = FirebaseAuth.instance.currentUser;
    final endDate = _currentStartDate.add(const Duration(days: 6));
    final startStr = DateFormat('yyyy-MM-dd').format(_currentStartDate);
    final endStr = DateFormat('yyyy-MM-dd').format(endDate);
    
    final displayRange = "${DateFormat('dd MMM', context.locale.languageCode).format(_currentStartDate)} - ${DateFormat('dd MMM', context.locale.languageCode).format(endDate)}";

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
          color: Colors.white,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(icon: const Icon(Icons.arrow_back, color: Colors.grey), onPressed: () => _changeWeek(-1)),
              Text(displayRange, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF15438c))),
              IconButton(icon: const Icon(Icons.arrow_forward, color: Colors.grey), onPressed: () => _changeWeek(1)),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance.collection('schedules')
                .where('userId', isEqualTo: state.myEmpCode)
                .where('date', isGreaterThanOrEqualTo: startStr)
                .where('date', isLessThanOrEqualTo: endStr)
                .orderBy('date')
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) return const ShimmerLoadingList();
              final scheduleDocs = snapshot.data?.docs ?? [];
              if (scheduleDocs.isEmpty) return Center(child: Text("att.no_shifts".tr(), style: const TextStyle(color: Colors.grey)));
              
              return ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: scheduleDocs.length,
                itemBuilder: (context, index) {
                  final scheduleData = scheduleDocs[index].data() as Map<String, dynamic>;
                  final dateStr = scheduleData['date'] as String;

                  DateTime? schedStart = scheduleData['start'] != null ? (scheduleData['start'] as Timestamp).toDate() : null;
                  DateTime? schedEnd = scheduleData['end'] != null ? (scheduleData['end'] as Timestamp).toDate() : null;

                  return StreamBuilder<QuerySnapshot>(
                    stream: FirebaseFirestore.instance.collection('attendance')
                        .where('uid', isEqualTo: user?.uid)
                        .where('date', isEqualTo: dateStr)
                        .snapshots(),
                    builder: (context, attSnapshot) {
                      String timeIn = "--:--";
                      String timeOut = "--:--";
                      String status = "Absent";
                      Color statusColor = Colors.grey;
                      
                      String lateStr = "0h 0m";
                      String underStr = "0h 0m";
                      String otStr = "0h 0m";
                      
                      bool isAbsent = false;
                      final now = DateTime.now();
                      final scheduleDate = DateTime.parse(dateStr);
                      final today = DateTime(now.year, now.month, now.day);
                      final checkDate = DateTime(scheduleDate.year, scheduleDate.month, scheduleDate.day);
                      
                      if (checkDate.isBefore(today)) {
                         isAbsent = true; 
                      }

                      if (attSnapshot.hasData && attSnapshot.data!.docs.isNotEmpty) {
                        final verifiedDocs = attSnapshot.data!.docs.where((d) {
                          final data = d.data() as Map<String, dynamic>;
                          return data['verificationStatus'] == 'Verified' || data['verificationStatus'] == 'Corrected';
                        }).toList();
                        
                        if (verifiedDocs.isNotEmpty) {
                           isAbsent = false; 
                        }

                        QueryDocumentSnapshot? clockInDoc;
                        try { clockInDoc = verifiedDocs.firstWhere((d) => (d.data() as Map<String,dynamic>)['session'] == 'Clock In'); } catch (_) {}

                        QueryDocumentSnapshot? clockOutDoc;
                        try { clockOutDoc = verifiedDocs.lastWhere((d) => (d.data() as Map<String,dynamic>)['session'] == 'Clock Out'); } catch (_) {}

                        QueryDocumentSnapshot? breakOutDoc;
                        try { breakOutDoc = verifiedDocs.lastWhere((d) => (d.data() as Map<String,dynamic>)['session'] == 'Break Out'); } catch (_) {}

                        if (clockInDoc != null) {
                           final data = clockInDoc.data() as Map<String, dynamic>;
                           final ts = (data['timestamp'] as Timestamp).toDate();
                           
                           timeIn = DateFormat('HH:mm').format(ts);
                           if (schedStart != null && ts.isAfter(schedStart)) {
                             lateStr = _formatDuration(ts.difference(schedStart));
                           }
                           status = "Working";
                           statusColor = Colors.blue;
                        }

                        if (clockOutDoc != null) {
                           final data = clockOutDoc.data() as Map<String, dynamic>;
                           final ts = (data['timestamp'] as Timestamp).toDate();
                           timeOut = DateFormat('HH:mm').format(ts);
                           status = "Present";
                           statusColor = Colors.green;
                           
                           if (schedEnd != null) {
                             if (ts.isAfter(schedEnd)) {
                               otStr = _formatDuration(ts.difference(schedEnd));
                             } else if (ts.isBefore(schedEnd)) {
                               underStr = _formatDuration(schedEnd.difference(ts));
                             }
                           }
                        } else if (breakOutDoc != null) {
                           final data = breakOutDoc.data() as Map<String, dynamic>;
                           final ts = (data['timestamp'] as Timestamp).toDate();
                           timeOut = DateFormat('HH:mm').format(ts);
                        }
                      }

                      return _buildScheduleCard(scheduleData, timeIn, timeOut, status, statusColor, lateStr, underStr, otStr, isAbsent, context);
                    }
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
  
  Widget _buildScheduleCard(Map<String, dynamic> scheduleData, String inTime, String outTime, String status, Color color, String late, String under, String ot, bool isAbsent, BuildContext context) {
    final dateObj = DateTime.parse(scheduleData['date']);
    final weekDay = DateFormat('EEEE', context.locale.languageCode).format(dateObj);
    final fmtDate = DateFormat('dd/MM/yyyy', context.locale.languageCode).format(dateObj);
    
    String shiftStart = scheduleData['start'] != null ? DateFormat('HH:mm').format((scheduleData['start'] as Timestamp).toDate().toLocal()) : "--:--";
    String shiftEnd = scheduleData['end'] != null ? DateFormat('HH:mm').format((scheduleData['end'] as Timestamp).toDate().toLocal()) : "--:--";

    return Card(
      elevation: 2,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text("${'att.label_shift'.tr()} ($shiftStart - $shiftEnd)", style: const TextStyle(color: Color(0xFF15438c), fontWeight: FontWeight.bold, fontSize: 15)),
                Text("$weekDay ($fmtDate)", style: const TextStyle(color: Colors.blueGrey, fontSize: 13)),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 5,
                  child: Row(
                    children: [
                      Expanded(child: _buildTimeBox("att.label_in".tr(), inTime)),
                      const SizedBox(width: 10),
                      Expanded(child: _buildTimeBox("att.label_out".tr(), outTime)),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  flex: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (status != "Absent" && !isAbsent) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4)),
                          child: Text(status, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.bold)),
                        ),
                        const SizedBox(height: 8),
                      ],
                      _buildStatRow("Late", late, late == "0h 0m" ? Colors.black : Colors.red),
                      const SizedBox(height: 4),
                      _buildStatRow("Under", under, under == "0h 0m" ? Colors.black : Colors.red),
                      const SizedBox(height: 4),
                      _buildStatRow("OT", ot, Colors.blue),
                    ],
                  ),
                )
              ],
            ),
            if (isAbsent)
               Container(
                 margin: const EdgeInsets.only(top: 10),
                 padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
                 decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(4), border: Border.all(color: Colors.red.shade200)),
                 child: const Text("ABSENT", style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 14, letterSpacing: 1.0)),
               )
          ],
        ),
      ),
    );
  }

  Widget _buildTimeBox(String label, String time) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(color: const Color(0xFFE3F2FD), borderRadius: BorderRadius.circular(8)),
          child: Center(child: Text(time, style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF15438c), fontSize: 15))),
        )
      ],
    );
  }

  Widget _buildStatRow(String label, String value, Color valueColor) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Text("$label: ", style: const TextStyle(fontSize: 11, color: Colors.black)),
        Text(value, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: valueColor)),
      ],
    );
  }
}

// ==========================================
//  Tab 4: Submit Tab (保持不变)
// ==========================================
class SubmitTab extends ConsumerStatefulWidget {
  const SubmitTab({super.key});
  @override
  ConsumerState<SubmitTab> createState() => _SubmitTabState();
}
class _SubmitTabState extends ConsumerState<SubmitTab> {
  DateTime _currentStartDate = DateTime.now();

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _currentStartDate = now.subtract(Duration(days: now.weekday - 1));
  }

  void _changeWeek(int weeks) {
    setState(() => _currentStartDate = _currentStartDate.add(Duration(days: 7 * weeks)));
  }

  String _formatDuration(Duration d) {
    return "${d.inMinutes ~/ 60}h ${d.inMinutes % 60}m";
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(attendanceProvider);
    if (state.isFetchingUser) return const Center(child: CircularProgressIndicator());
    if (state.myEmpCode.isEmpty) return Center(child: Text("att.err_profile_not_linked".tr()));

    final user = FirebaseAuth.instance.currentUser;
    final now = DateTime.now();
    
    final originalEndDate = _currentStartDate.add(const Duration(days: 6));
    final endOfToday = DateTime(now.year, now.month, now.day, 23, 59, 59);
    DateTime effectiveEndDate = originalEndDate.isAfter(endOfToday) ? endOfToday : originalEndDate;
    
    final startStr = DateFormat('yyyy-MM-dd').format(_currentStartDate);
    final endStr = DateFormat('yyyy-MM-dd').format(effectiveEndDate);
    
    final displayRange = "${DateFormat('dd MMM', context.locale.languageCode).format(_currentStartDate)} - ${DateFormat('dd MMM', context.locale.languageCode).format(originalEndDate)}";
    bool isFutureWeek = _currentStartDate.isAfter(endOfToday);

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
          color: Colors.white,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(icon: const Icon(Icons.arrow_back, color: Colors.grey), onPressed: () => _changeWeek(-1)),
              Text(displayRange, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF15438c))),
              IconButton(icon: const Icon(Icons.arrow_forward, color: Colors.grey), onPressed: () => _changeWeek(1)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8.0),
          child: Text("att.hint_correction".tr(), style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ),
        
        Expanded(
          child: isFutureWeek 
            ? Center(child: Text("att.no_shifts".tr(), style: const TextStyle(color: Colors.grey))) 
            : StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance.collection('schedules')
                .where('userId', isEqualTo: state.myEmpCode)
                .where('date', isGreaterThanOrEqualTo: startStr)
                .where('date', isLessThanOrEqualTo: endStr) 
                .orderBy('date')
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) return const ShimmerLoadingList();
              final scheduleDocs = snapshot.data?.docs ?? [];
              if (scheduleDocs.isEmpty) return Center(child: Text("att.no_shifts".tr(), style: const TextStyle(color: Colors.grey)));
              
              return ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: scheduleDocs.length,
                itemBuilder: (context, index) {
                  final scheduleData = scheduleDocs[index].data() as Map<String, dynamic>;
                  final dateStr = scheduleData['date'] as String;
                  
                  DateTime? schedStart = scheduleData['start'] != null ? (scheduleData['start'] as Timestamp).toDate() : null;
                  DateTime? schedEnd = scheduleData['end'] != null ? (scheduleData['end'] as Timestamp).toDate() : null;
                  
                  String? attendanceId; 

                  return StreamBuilder<QuerySnapshot>(
                    stream: FirebaseFirestore.instance.collection('attendance')
                        .where('uid', isEqualTo: user?.uid)
                        .where('date', isEqualTo: dateStr)
                        .snapshots(),
                    builder: (context, attSnapshot) {
                      String timeIn = "--:--";
                      String timeOut = "--:--";
                      
                      String lateStr = "0h 0m";
                      String underStr = "0h 0m";
                      String otStr = "0h 0m";
                      
                      bool isAbsent = false;
                      final checkDate = DateTime.parse(dateStr);
                      final today = DateTime(now.year, now.month, now.day);
                      
                      if (checkDate.isBefore(today)) {
                         isAbsent = true; 
                      }

                      if (attSnapshot.hasData && attSnapshot.data!.docs.isNotEmpty) {
                        attendanceId = attSnapshot.data!.docs.first.id;
                        final verifiedDocs = attSnapshot.data!.docs.where((d) {
                          final data = d.data() as Map<String, dynamic>;
                          return data['verificationStatus'] == 'Verified' || data['verificationStatus'] == 'Corrected';
                        }).toList();
                        
                        if (verifiedDocs.isNotEmpty) {
                           isAbsent = false; 
                        }

                        QueryDocumentSnapshot? clockInDoc;
                        try { clockInDoc = verifiedDocs.firstWhere((d) => (d.data() as Map<String,dynamic>)['session'] == 'Clock In'); } catch (_) {}

                        QueryDocumentSnapshot? clockOutDoc;
                        try { clockOutDoc = verifiedDocs.lastWhere((d) => (d.data() as Map<String,dynamic>)['session'] == 'Clock Out'); } catch (_) {}

                        QueryDocumentSnapshot? breakOutDoc;
                        try { breakOutDoc = verifiedDocs.lastWhere((d) => (d.data() as Map<String,dynamic>)['session'] == 'Break Out'); } catch (_) {}

                        if (clockInDoc != null) {
                           final ts = ((clockInDoc.data() as Map<String, dynamic>)['timestamp'] as Timestamp).toDate();
                           timeIn = DateFormat('HH:mm').format(ts);
                           if (schedStart != null && ts.isAfter(schedStart)) {
                             lateStr = _formatDuration(ts.difference(schedStart));
                           }
                        }
                        if (clockOutDoc != null) {
                           final ts = ((clockOutDoc.data() as Map<String, dynamic>)['timestamp'] as Timestamp).toDate();
                           timeOut = DateFormat('HH:mm').format(ts);
                           if (schedEnd != null) {
                             if (ts.isAfter(schedEnd)) {
                               otStr = _formatDuration(ts.difference(schedEnd));
                             } else if (ts.isBefore(schedEnd)) {
                               underStr = _formatDuration(schedEnd.difference(ts));
                             }
                           }
                        } else if (breakOutDoc != null) {
                           timeOut = DateFormat('HH:mm').format(((breakOutDoc.data() as Map<String, dynamic>)['timestamp'] as Timestamp).toDate());
                        }
                      }

                      return _buildSubmitCard(scheduleData, attendanceId, timeIn, timeOut, lateStr, underStr, otStr, isAbsent, context);
                    }
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildSubmitCard(Map<String, dynamic> scheduleData, String? attendanceId, String inTime, String outTime, String late, String under, String ot, bool isAbsent, BuildContext context) {
    final dateObj = DateTime.parse(scheduleData['date']);
    final weekDay = DateFormat('EEEE', context.locale.languageCode).format(dateObj);
    final fmtDate = DateFormat('dd/MM/yyyy', context.locale.languageCode).format(dateObj);
    
    String shiftStart = scheduleData['start'] != null ? DateFormat('HH:mm').format((scheduleData['start'] as Timestamp).toDate().toLocal()) : "--:--";
    String shiftEnd = scheduleData['end'] != null ? DateFormat('HH:mm').format((scheduleData['end'] as Timestamp).toDate().toLocal()) : "--:--";

    return GestureDetector(
      onTap: () {
        Navigator.push(context, MaterialPageRoute(builder: (_) => CorrectionRequestScreen(
          date: dateObj, attendanceId: attendanceId, originalIn: inTime, originalOut: outTime
        )));
      },
      child: Card(
        elevation: 2,
        margin: const EdgeInsets.only(bottom: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: Colors.blue.withValues(alpha:0.3))),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text("${'att.label_shift'.tr()} ($shiftStart - $shiftEnd)", style: const TextStyle(color: Color(0xFF15438c), fontWeight: FontWeight.bold, fontSize: 15)), 
                  Text("$weekDay ($fmtDate)", style: const TextStyle(color: Colors.blueGrey, fontSize: 13)),
                ],
              ),
              const SizedBox(height: 12),
              
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 5,
                    child: Row(
                      children: [
                        Expanded(child: _buildTimeBox("att.label_in".tr(), inTime)),
                        const SizedBox(width: 10),
                        Expanded(child: _buildTimeBox("att.label_out".tr(), outTime)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    flex: 3,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        const Icon(Icons.edit_note, color: Colors.blue, size: 24),
                        const SizedBox(height: 8),
                        _buildStatRow("Late", late, late == "0h 0m" ? Colors.black : Colors.red),
                        const SizedBox(height: 4),
                        _buildStatRow("Under", under, under == "0h 0m" ? Colors.black : Colors.red),
                        const SizedBox(height: 4),
                        _buildStatRow("OT", ot, Colors.blue),
                      ],
                    ),
                  )
                ],
              ),
              if (isAbsent)
               Container(
                 margin: const EdgeInsets.only(top: 10),
                 padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
                 decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(4), border: Border.all(color: Colors.red.shade200)),
                 child: const Text("ABSENT", style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 14, letterSpacing: 1.0)),
               )
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTimeBox(String label, String time) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(color: const Color(0xFFE3F2FD), borderRadius: BorderRadius.circular(8)),
          child: Center(child: Text(time, style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF15438c), fontSize: 15))),
        )
      ],
    );
  }

  Widget _buildStatRow(String label, String value, Color valueColor) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Text("$label: ", style: const TextStyle(fontSize: 11, color: Colors.black)),
        Text(value, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: valueColor)),
      ],
    );
  }
}