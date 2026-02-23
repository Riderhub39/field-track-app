import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:file_picker/file_picker.dart'; 
import 'package:easy_localization/easy_localization.dart';

class LeaveApplicationScreen extends StatefulWidget {
  const LeaveApplicationScreen({super.key});

  @override
  State<LeaveApplicationScreen> createState() => _LeaveApplicationScreenState();
}

class _LeaveApplicationScreenState extends State<LeaveApplicationScreen> {
  final _formKey = GlobalKey<FormState>();
  bool _isLoading = false;

  String _leaveTypeKey = 'leave.type_annual'; 
  final List<String> _leaveTypeKeys = [
    'leave.type_annual', 
    'leave.type_medical', 
    'leave.type_unpaid'
  ];
  
  DateTime? _startDate;
  DateTime? _endDate;
  final TextEditingController _reasonController = TextEditingController();

  Map<String, dynamic> _balances = {'annual': 0, 'medical': 0, 'emergency': 0};
  bool _balanceLoaded = false;

  PlatformFile? _selectedFile; 

  @override
  void initState() {
    super.initState();
    _fetchBalances();
  }

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  String _getStandardEnglishType(String key) {
    switch (key) {
      case 'leave.type_annual': return 'Annual Leave';
      case 'leave.type_medical': return 'Medical Leave';
      case 'leave.type_unpaid': return 'Unpaid Leave';
      default: return 'Annual Leave';
    }
  }

  String _getLocalizedTypeFromDb(String dbValue) {
    if (dbValue == 'Annual Leave' || dbValue == '年假' || dbValue == 'Cuti Tahunan') return 'leave.type_annual'.tr();
    if (dbValue == 'Medical Leave' || dbValue == '病假' || dbValue == 'Cuti Sakit') return 'leave.type_medical'.tr();
    if (dbValue == 'Unpaid Leave' || dbValue == '无薪假' || dbValue == 'Cuti Tanpa Gaji') return 'leave.type_unpaid'.tr();
    return dbValue;
  }

  Future<void> _fetchBalances() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      Map<String, dynamic>? userData;
      final docSnap = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
      
      if (docSnap.exists) {
        userData = docSnap.data();
      } else {
        final q = await FirebaseFirestore.instance.collection('users').where('personal.email', isEqualTo: user.email).limit(1).get();
        if (q.docs.isNotEmpty) {
          userData = q.docs.first.data();
        }
      }

      if (userData != null && userData.containsKey('leave_balance')) {
        if (mounted) {
          setState(() { 
            _balances = userData!['leave_balance']; 
            _balanceLoaded = true; 
          });
        }
      }
    } catch (e) {
      debugPrint("Error fetching balance: $e");
    }
  }

  Future<void> _pickDate(bool isStart) async {
    final now = DateTime.now();
    DateTime firstDateAllowed = DateTime(2024); 
    DateTime initialDate = isStart ? (_startDate ?? now) : (_endDate ?? (_startDate ?? now));
    
    if (initialDate.isBefore(firstDateAllowed)) initialDate = firstDateAllowed;

    DateTime? picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: firstDateAllowed, 
      lastDate: DateTime(2030),
    );

    if (picked != null) {
      setState(() {
        if (isStart) {
          _startDate = picked;
          if (_endDate != null && _endDate!.isBefore(_startDate!)) {
            _endDate = null;
          }
        } else {
          _endDate = picked;
        }
      });
    }
  }

  int _calculateWorkingDays(DateTime start, DateTime end) {
    int days = 0;
    DateTime current = start;
    while (current.isBefore(end) || current.isAtSameMomentAs(end)) {
      if (current.weekday != DateTime.sunday) { 
        days++;
      }
      current = current.add(const Duration(days: 1));
    }
    return days;
  }

  Future<void> _pickAttachment() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['jpg', 'jpeg', 'png', 'pdf'], 
      );

      if (result != null) {
        setState(() => _selectedFile = result.files.first);
      }
    } catch (e) {
      debugPrint("Error picking file: $e");
    }
  }

  Future<bool> _checkForDuplicateLeave(String uid, DateTime start, DateTime end) async {
    final q = await FirebaseFirestore.instance
        .collection('leaves')
        .where('authUid', isEqualTo: uid)
        .where('status', isEqualTo: 'Approved')
        .get();

    for (var doc in q.docs) {
      final data = doc.data();
      DateTime existingStart = DateTime.parse(data['startDate']);
      DateTime existingEnd = DateTime.parse(data['endDate']);

      if (start.isBefore(existingEnd.add(const Duration(days: 1))) && end.isAfter(existingStart.subtract(const Duration(days: 1)))) {
        return true; 
      }
    }
    return false;
  }

  // 🟢 优化后的提交函数：完美处理无附件/防崩溃
  Future<void> _submitApplication() async {
    if (!_formKey.currentState!.validate()) return;
    
    if (_startDate == null || _endDate == null) {
      _showSnack("leave.error_select_dates".tr());
      return;
    }

    int days = _calculateWorkingDays(_startDate!, _endDate!);
    if (days <= 0) {
       _showSnack("leave.error_no_working_days".tr());
       return;
    }

    // 1. 余额检查 (仅针对年假)
    if (_leaveTypeKey == 'leave.type_annual') {
      int annualBal = (_balances['annual'] is int) ? _balances['annual'] : 0;
      if (annualBal < days) {
        _showSnack("leave.error_insufficient".tr(args: [days.toString(), annualBal.toString()]));
        return;
      }
    }

    // 2. 证据检查 (仅针对病假)
    if (_leaveTypeKey == 'leave.type_medical' && _selectedFile == null) {
      _showSnack("leave.error_upload_evidence".tr()); 
      return;
    }

    setState(() => _isLoading = true);

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        throw "User not authenticated";
      }

      // 3. 重复请假检查
      bool isDuplicate = await _checkForDuplicateLeave(user.uid, _startDate!, _endDate!);
      if (isDuplicate) {
        _showSnack("You already have an approved leave for these dates.");
        setState(() => _isLoading = false);
        return;
      }

      // 4. 更安全的获取用户资料
      String empCode = user.uid; 
      String empName = 'Staff';
      String empEmail = user.email ?? "no-email@system.com";

      QuerySnapshot q = await FirebaseFirestore.instance.collection('users').where('authUid', isEqualTo: user.uid).limit(1).get();
      
      if (q.docs.isNotEmpty) {
        final userDoc = q.docs.first;
        final userData = userDoc.data() as Map<String, dynamic>;
        empCode = userDoc.id; 
        empName = userData['personal']?['name'] ?? 'Staff';
        empEmail = userData['personal']?['email'] ?? empEmail;
      } else {
        throw "User profile not found in database";
      }

      // 5. 处理附件上传
      String? attachmentUrl;
      String? fileType; 

      if (_selectedFile != null && _selectedFile!.path != null) {
        final String ext = _selectedFile!.extension ?? 'file';
        final String fileName = '${DateTime.now().millisecondsSinceEpoch}_evidence.$ext';
        
        final Reference storageRef = FirebaseStorage.instance
            .ref()
            .child('leave_evidence')
            .child(user.uid)
            .child(fileName);
        
        File file = File(_selectedFile!.path!);
        await storageRef.putFile(file);
        
        attachmentUrl = await storageRef.getDownloadURL();
        fileType = ext; 
      }

      // 6. 干净的数据载荷写入
      Map<String, dynamic> leaveData = {
        'uid': empCode,
        'authUid': user.uid,
        'empName': empName,
        'email': empEmail,
        'type': _getStandardEnglishType(_leaveTypeKey),
        'startDate': DateFormat('yyyy-MM-dd').format(_startDate!),
        'endDate': DateFormat('yyyy-MM-dd').format(_endDate!),
        'days': days, 
        'reason': _reasonController.text.trim(),
        'status': 'Pending',
        'appliedAt': FieldValue.serverTimestamp(),
        'isPayrollDeductible': (_leaveTypeKey == 'leave.type_unpaid'),
      };

      // 🟢 关键修复：只有当有附件时才写入相关字段，防止无薪假引发 Null 问题
      if (attachmentUrl != null) {
        leaveData['attachmentUrl'] = attachmentUrl;
        leaveData['fileType'] = fileType;
      }

      await FirebaseFirestore.instance.collection('leaves').add(leaveData);

      if (mounted) {
        _showSnack("leave.msg_submit_success".tr());
        setState(() {
          _startDate = null; 
          _endDate = null; 
          _selectedFile = null; 
          _reasonController.clear();
        });
        DefaultTabController.of(context).animateTo(1);
      }

    } catch (e) {
      if (mounted) _showSnack("Error: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showSnack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
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
        body: TabBarView(children: [_buildApplyTab(), _buildHistoryTab()]),
      ),
    );
  }

  Widget _buildApplyTab() {
    bool isImage = false;
    if (_selectedFile != null) {
      final ext = _selectedFile!.extension?.toLowerCase();
      isImage = ['jpg', 'jpeg', 'png'].contains(ext);
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              margin: const EdgeInsets.only(bottom: 20), 
              decoration: BoxDecoration(color: Colors.blue[50], borderRadius: BorderRadius.circular(10)),
              child: Column(
                children: [
                  Text("leave.balance_label".tr().toUpperCase(), style: const TextStyle(color: Colors.blue, fontWeight: FontWeight.bold, fontSize: 12)),
                  const SizedBox(height: 5),
                  _balanceLoaded 
                    ? Text((_balances['annual'] ?? 0).toString(), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 32, color: Colors.blue))
                    : const LinearProgressIndicator(),
                  Text("leave.days_remaining".tr(), style: const TextStyle(color: Colors.grey, fontSize: 12)),
                ],
              ),
            ),

            DropdownButtonFormField<String>(
              initialValue: _leaveTypeKey,
              decoration: InputDecoration(labelText: "leave.field_type".tr(), border: const OutlineInputBorder()),
              items: _leaveTypeKeys.map((k) => DropdownMenuItem(value: k, child: Text(k.tr()))).toList(),
              onChanged: (val) => setState(() => _leaveTypeKey = val!),
            ),
            const SizedBox(height: 16),

            Row(
              children: [
                Expanded(child: _buildDatePicker(true, "leave.field_start".tr(), _startDate)),
                const SizedBox(width: 10),
                Expanded(child: _buildDatePicker(false, "leave.field_end".tr(), _endDate)),
              ],
            ),
            const SizedBox(height: 16),

            if (_startDate != null && _endDate != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text("leave.calculated_days".tr(args: [_calculateWorkingDays(_startDate!, _endDate!).toString()]), style: TextStyle(color: Colors.grey[700], fontStyle: FontStyle.italic, fontSize: 13)),
              ),

            TextFormField(
              controller: _reasonController,
              maxLines: 3,
              decoration: InputDecoration(labelText: "leave.field_reason".tr(), border: const OutlineInputBorder()),
              validator: (val) => val!.isEmpty ? "leave.error_required".tr() : null,
            ),
            const SizedBox(height: 16),

            if (_leaveTypeKey == 'leave.type_medical') ...[
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
                      onTap: _pickAttachment,
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          border: Border.all(color: Colors.orange),
                          borderRadius: BorderRadius.circular(8),
                          image: (isImage && _selectedFile?.path != null) ? DecorationImage(
                            image: FileImage(File(_selectedFile!.path!)),
                            fit: BoxFit.cover,
                            colorFilter: ColorFilter.mode(Colors.black.withValues(alpha: 0.3), BlendMode.darken)
                          ) : null
                        ),
                        child: _selectedFile == null 
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
                    if (_selectedFile != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(child: Text(_selectedFile!.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Colors.grey))),
                            TextButton(
                              onPressed: () => setState(() => _selectedFile = null), 
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
                onPressed: _isLoading ? null : _submitApplication,
                child: _isLoading ? const CircularProgressIndicator(color: Colors.white) : Text("leave.btn_submit".tr()),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHistoryTab() {
    final user = FirebaseAuth.instance.currentUser;
    if(user == null) {
      return Center(child: Text("leave.error_login".tr()));
    }

    return StreamBuilder<QuerySnapshot>(
      // 🟢 修复了这里使用 email 导致旧记录缺失的问题，改为使用 authUid 搜索
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
                            Text(typeDisplay, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                            if (hasAttachment)
                              Padding(
                                padding: const EdgeInsets.only(left: 8.0),
                                child: Icon(isPdf ? Icons.picture_as_pdf : Icons.image, size: 16, color: Colors.blue),
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

  Widget _buildDatePicker(bool isStart, String label, DateTime? val) {
    return InkWell(
      onTap: () => _pickDate(isStart),
      child: InputDecorator(
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), suffixIcon: const Icon(Icons.calendar_today, size: 18)),
        child: Text(val == null ? "-" : DateFormat('dd/MM/yyyy').format(val)),
      ),
    );
  }
}