import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:url_launcher/url_launcher.dart';

// 🟢 引入控制器
import 'leave_application_controller.dart';

class LeaveApplicationScreen extends ConsumerStatefulWidget {
  const LeaveApplicationScreen({super.key});

  @override
  ConsumerState<LeaveApplicationScreen> createState() => _LeaveApplicationScreenState();
}

class _LeaveApplicationScreenState extends ConsumerState<LeaveApplicationScreen> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _reasonController = TextEditingController();

  final List<String> _leaveTypeKeys = [
    'leave.type_annual', 
    'leave.type_medical', 
    'leave.type_unpaid'
  ];

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  String _getLocalizedTypeFromDb(String dbValue) {
    if (dbValue == 'Annual Leave' || dbValue == '年假' || dbValue == 'Cuti Tahunan') return 'leave.type_annual'.tr();
    if (dbValue == 'Medical Leave' || dbValue == '病假' || dbValue == 'Cuti Sakit') return 'leave.type_medical'.tr();
    if (dbValue == 'Unpaid Leave' || dbValue == '无薪假' || dbValue == 'Cuti Tanpa Gaji') return 'leave.type_unpaid'.tr();
    return dbValue;
  }

  Future<void> _pickDate(BuildContext context, bool isStart, DateTime? currentStart, DateTime? currentEnd) async {
    final now = DateTime.now();
    DateTime firstDateAllowed = DateTime(2024); 
    DateTime initialDate = isStart ? (currentStart ?? now) : (currentEnd ?? (currentStart ?? now));
    
    if (initialDate.isBefore(firstDateAllowed)) initialDate = firstDateAllowed;

    DateTime? picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: firstDateAllowed, 
      lastDate: DateTime(2030),
    );

    if (picked != null) {
      if (isStart) {
        ref.read(leaveApplicationProvider.notifier).setDates(start: picked);
      } else {
        ref.read(leaveApplicationProvider.notifier).setDates(end: picked);
      }
    }
  }

  void _showAttachmentSourceDialog(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 16, left: 16, bottom: 8),
              child: Text(
                "Select File Type",
                style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey[700], fontSize: 14),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library, color: Colors.blue),
              title: const Text("Photo / Image"),
              subtitle: const Text("From Gallery or Camera", style: TextStyle(fontSize: 12)),
              onTap: () {
                Navigator.pop(ctx);
                ref.read(leaveApplicationProvider.notifier).pickImageAttachment();
              },
            ),
            ListTile(
              leading: const Icon(Icons.picture_as_pdf, color: Colors.orange),
              title: const Text("PDF Document"),
              subtitle: const Text("From Files / Local Storage", style: TextStyle(fontSize: 12)),
              onTap: () {
                Navigator.pop(ctx);
                ref.read(leaveApplicationProvider.notifier).pickFileAttachment();
              },
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(leaveApplicationProvider);

    ref.listen<LeaveApplicationState>(leaveApplicationProvider, (previous, next) {
      if (next.errorMessage != null && next.errorMessage != previous?.errorMessage) {
        String msg = next.errorMessage!;
        if (msg == 'leave.error_insufficient') {
           int days = ref.read(leaveApplicationProvider.notifier).calculateWorkingDays(next.startDate, next.endDate);
           int bal = (next.balances[next.leaveTypeKey == 'leave.type_annual' ? 'annual' : 'medical'] as int?) ?? 0;
           msg = msg.tr(args: [days.toString(), bal.toString()]);
        } else {
           msg = msg.tr();
        }
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.red));
        ref.read(leaveApplicationProvider.notifier).clearMessages();
      }

      if (next.successMessage != null && next.successMessage != previous?.successMessage) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(next.successMessage!.tr()), backgroundColor: Colors.green));
        _reasonController.clear();
        DefaultTabController.of(context).animateTo(1);
        ref.read(leaveApplicationProvider.notifier).clearMessages();
      }
    });

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text("leave.title".tr()),
          backgroundColor: Colors.blue,
          foregroundColor: Colors.white,
          bottom: TabBar(
            indicatorColor: Colors.white,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white70,
            tabs: [Tab(text: "leave.tab_apply".tr()), Tab(text: "leave.tab_history".tr())],
          ),
        ),
        body: TabBarView(children: [_buildApplyTab(context, state), _buildHistoryTab()]),
      ),
    );
  }

  Widget _buildApplyTab(BuildContext context, LeaveApplicationState state) {
    bool isImage = false;
    if (state.selectedFile != null) {
      final ext = state.selectedFile!.extension?.toLowerCase();
      isImage = ['jpg', 'jpeg', 'png'].contains(ext);
    }

    // 🟢 判断是否为同一天，如果是则允许半天假
    bool isSingleDay = false;
    if (state.startDate != null && state.endDate != null) {
      isSingleDay = state.startDate!.isAtSameMomentAs(state.endDate!);
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: _buildBalanceCard(
                    title: "leave.type_annual".tr(),
                    available: state.balances['annual'] ?? 0,
                    total: state.balances['total_annual']?.toString() ?? "-",
                    color: Colors.blue,
                    isLoaded: state.balanceLoaded,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildBalanceCard(
                    title: "leave.type_medical".tr(),
                    available: state.balances['medical'] ?? 0,
                    total: state.balances['total_medical']?.toString() ?? "-",
                    color: Colors.orange,
                    isLoaded: state.balanceLoaded,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            DropdownButtonFormField<String>(
              key: ValueKey(state.leaveTypeKey), 
              initialValue: state.leaveTypeKey,
              decoration: InputDecoration(labelText: "leave.field_type".tr(), border: const OutlineInputBorder()),
              items: _leaveTypeKeys.map((k) => DropdownMenuItem(value: k, child: Text(k.tr()))).toList(),
              onChanged: (val) {
                if (val != null) ref.read(leaveApplicationProvider.notifier).setLeaveType(val);
              },
            ),
            const SizedBox(height: 16),

            Row(
              children: [
                Expanded(child: _buildDatePicker(context, true, "leave.field_start".tr(), state.startDate, state.endDate)),
                const SizedBox(width: 10),
                Expanded(child: _buildDatePicker(context, false, "leave.field_end".tr(), state.startDate, state.endDate)),
              ],
            ),
            const SizedBox(height: 16),

            // 🟢 新增：仅在选中同日期时弹出半天选项
            if (isSingleDay)
              Padding(
                padding: const EdgeInsets.only(bottom: 16.0),
                child: DropdownButtonFormField<String>(
                  initialValue: state.leaveDuration,
                  decoration: const InputDecoration(
                    labelText: 'Duration (请假时长)',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'Full Day', child: Text('Full Day (全天)')),
                    DropdownMenuItem(value: 'Half Day (AM)', child: Text('Half Day AM (上午)')),
                    DropdownMenuItem(value: 'Half Day (PM)', child: Text('Half Day PM (下午)')),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      ref.read(leaveApplicationProvider.notifier).setLeaveDuration(value);
                    }
                  },
                ),
              ),

            if (state.startDate != null && state.endDate != null)
              Builder(
                builder: (context) {
                  // 🟢 新增：动态展示计算出的请假天数，便于用户核对
                  int workingDays = ref.read(leaveApplicationProvider.notifier).calculateWorkingDays(state.startDate, state.endDate);
                  double displayDays = workingDays.toDouble();
                  if (isSingleDay && state.leaveDuration != 'Full Day') {
                    displayDays = 0.5;
                  }

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      "leave.calculated_days".tr(args: [displayDays.toString()]), 
                      style: TextStyle(color: Colors.grey[700], fontStyle: FontStyle.italic, fontSize: 13)
                    ),
                  );
                }
              ),

            TextFormField(
              controller: _reasonController,
              maxLines: 3,
              decoration: InputDecoration(labelText: "leave.field_reason".tr(), border: const OutlineInputBorder()),
              validator: (val) => val!.isEmpty ? "leave.error_required".tr() : null,
            ),
            const SizedBox(height: 16),

            if (state.leaveTypeKey == 'leave.type_medical') ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.1),
                  border: Border.all(color: Colors.orange.withValues(alpha: 0.5)),
                  borderRadius: BorderRadius.circular(8)
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.info_outline, color: Colors.orange),
                        const SizedBox(width: 8),
                        Expanded(child: Text("leave.mc_notice".tr(), style: const TextStyle(fontSize: 12))),
                      ],
                    ),
                    const SizedBox(height: 12),
                    
                    InkWell(
                      onTap: () => _showAttachmentSourceDialog(context, ref),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          border: Border.all(color: Colors.orange),
                          borderRadius: BorderRadius.circular(8),
                          image: (isImage && state.selectedFile?.path != null) ? DecorationImage(
                            image: FileImage(File(state.selectedFile!.path!)),
                            fit: BoxFit.cover,
                            colorFilter: ColorFilter.mode(Colors.black.withValues(alpha: 0.3), BlendMode.darken)
                          ) : null
                        ),
                        child: state.selectedFile == null 
                          ? Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.upload_file, color: Colors.orange),
                                const SizedBox(width: 8),
                                Text("leave.label_upload_hint".tr(), style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.bold))
                              ],
                            )
                          : Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(isImage ? Icons.check_circle : Icons.picture_as_pdf, color: isImage ? Colors.white : Colors.orange),
                                const SizedBox(width: 8),
                                Text(
                                  "leave.label_file_selected".tr(),
                                  style: TextStyle(color: isImage ? Colors.white : Colors.orange, fontWeight: FontWeight.bold)
                                )
                              ],
                            ),
                      ),
                    ),
                    if (state.selectedFile != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(child: Text(state.selectedFile!.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Colors.grey))),
                            TextButton(
                              onPressed: () => ref.read(leaveApplicationProvider.notifier).removeAttachment(), 
                              style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0,0), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                              child: Text("leave.btn_remove".tr(), style: const TextStyle(fontSize: 11, color: Colors.red))
                            )
                          ],
                        ),
                      )
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
            
            const SizedBox(height: 24),

            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.blue, foregroundColor: Colors.white),
                onPressed: state.isLoading ? null : () {
                  if (_formKey.currentState!.validate()) {
                    ref.read(leaveApplicationProvider.notifier).submitApplication(_reasonController.text.trim());
                  }
                },
                child: state.isLoading ? const CircularProgressIndicator(color: Colors.white) : Text("leave.btn_submit".tr()),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBalanceCard({required String title, required int available, required String total, required MaterialColor color, required bool isLoaded}) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      decoration: BoxDecoration(
        color: color[50], 
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title.toUpperCase(), style: TextStyle(color: color[700], fontWeight: FontWeight.bold, fontSize: 11)),
          const SizedBox(height: 8),
          isLoaded 
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(available.toString(), style: TextStyle(fontWeight: FontWeight.bold, fontSize: 32, color: color[800])),
                  Text(" / $total", style: TextStyle(fontSize: 14, color: color[600], fontWeight: FontWeight.w500)),
                ],
              )
            : SizedBox(height: 38, child: Center(child: LinearProgressIndicator(color: color))),
          const SizedBox(height: 4),
          Text("leave.days_remaining".tr(), style: const TextStyle(color: Colors.grey, fontSize: 11)),
        ],
      ),
    );
  }

  Widget _buildDatePicker(BuildContext context, bool isStart, String label, DateTime? currentStart, DateTime? currentEnd) {
    final val = isStart ? currentStart : currentEnd;
    return InkWell(
      onTap: () => _pickDate(context, isStart, currentStart, currentEnd),
      child: InputDecorator(
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), suffixIcon: const Icon(Icons.calendar_today, size: 18)),
        child: Text(val == null ? "-" : DateFormat('dd/MM/yyyy').format(val)),
      ),
    );
  }

  // ========== 历史记录 Tab ==========
  Widget _buildHistoryTab() {
    final user = FirebaseAuth.instance.currentUser;
    if(user == null) {
      return Center(child: Text("leave.error_login".tr()));
    }

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('leaves').where('authUid', isEqualTo: user.uid).snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
          return Center(child: Text("leave.no_history".tr()));
        }

        final docs = snapshot.data!.docs;
        docs.sort((a, b) {
          Timestamp? tA = a['appliedAt']; Timestamp? tB = b['appliedAt'];
          if (tA == null || tB == null) return 0;
          return tB.compareTo(tA);
        });

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: docs.length,
          itemBuilder: (context, index) {
            final data = docs[index].data() as Map<String, dynamic>;
            final status = data['status'] ?? 'Pending';
            
            final typeDb = data['type'] ?? 'Leave';
            final typeDisplay = _getLocalizedTypeFromDb(typeDb);
            
            // 🟢 新增：读取 duration 并展示出来（如果是半天假）
            final String? durationDb = data['duration'];
            final String durationDisplay = (durationDb != null && durationDb != 'Full Day') 
                ? ' (${durationDb.replaceAll('Half Day ', '')})' // 仅显示 (AM) 或 (PM)
                : '';

            final sDate = data['startDate'] ?? '';
            final eDate = data['endDate'] ?? '';
            final days = data['days'] ?? 0;
            final reason = data['rejectionReason'];
            
            final bool hasAttachment = data['attachmentUrl'] != null;
            final bool isPdf = (data['fileType'] ?? '').toString().contains('pdf');

            String statusDisplay = status;
            
            if (status == 'Pending') {
              statusDisplay = "leave.status_pending".tr();
            } else if (status == 'Approved') {
              statusDisplay = "leave.status_approved".tr();
            } else if (status == 'Rejected') {
              statusDisplay = "leave.status_rejected".tr();
            }

            Color statusColor = status == 'Approved' ? Colors.green : (status == 'Rejected' ? Colors.red : Colors.orange);

            return Card(
              margin: const EdgeInsets.only(bottom: 12),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            // 🟢 标题处加入 AM 或 PM 的提示
                            Text("$typeDisplay$durationDisplay", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                            if (hasAttachment)
                              Padding(
                                padding: const EdgeInsets.only(left: 8.0),
                                child: InkWell(
                                  onTap: () async {
                                    final Uri url = Uri.parse(data['attachmentUrl']);
                                    if (await canLaunchUrl(url)) {
                                      await launchUrl(url, mode: LaunchMode.externalApplication);
                                    }
                                  },
                                  child: Icon(isPdf ? Icons.picture_as_pdf : Icons.image, size: 18, color: Colors.blue),
                                ),
                              )
                          ],
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(color: statusColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4), border: Border.all(color: statusColor.withValues(alpha: 0.5))),
                          child: Text(statusDisplay, style: TextStyle(color: statusColor, fontWeight: FontWeight.bold, fontSize: 12)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Icon(Icons.calendar_today, size: 14, color: Colors.grey),
                        const SizedBox(width: 4),
                        // 如果选了 0.5，这边的 days 会直接显示 0.5
                        Text("$sDate to $eDate ($days ${'leave.unit_days'.tr()})", style: const TextStyle(color: Colors.black87)),
                      ],
                    ),
                    if (status == 'Rejected' && reason != null) ...[
                      const Divider(height: 20),
                      Text("${'leave.field_rejection'.tr()}: $reason", style: const TextStyle(color: Colors.red, fontStyle: FontStyle.italic, fontSize: 13)),
                    ]
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}