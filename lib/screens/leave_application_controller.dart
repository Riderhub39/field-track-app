import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:file_picker/file_picker.dart'; 
import 'package:easy_localization/easy_localization.dart';

// ==========================================
// 1. 状态定义 (State)
// ==========================================
class LeaveApplicationState {
  final bool isLoading;
  final bool balanceLoaded;
  final Map<String, dynamic> balances;
  
  // 表单数据
  final String leaveTypeKey;
  final DateTime? startDate;
  final DateTime? endDate;
  final PlatformFile? selectedFile;
  
  // UI 事件通知
  final String? errorMessage;
  final String? successMessage;

  LeaveApplicationState({
    this.isLoading = false,
    this.balanceLoaded = false,
    this.balances = const {
      'annual': 0, 
      'medical': 0, 
      'total_annual': 0, 
      'total_medical': 0 
    },
    this.leaveTypeKey = 'leave.type_annual',
    this.startDate,
    this.endDate,
    this.selectedFile,
    this.errorMessage,
    this.successMessage,
  });

  LeaveApplicationState copyWith({
    bool? isLoading,
    bool? balanceLoaded,
    Map<String, dynamic>? balances,
    String? leaveTypeKey,
    DateTime? startDate,
    DateTime? endDate,
    PlatformFile? selectedFile,
    String? errorMessage,
    String? successMessage,
    bool clearDates = false,
    bool clearFile = false,
    bool clearMessages = false,
  }) {
    return LeaveApplicationState(
      isLoading: isLoading ?? this.isLoading,
      balanceLoaded: balanceLoaded ?? this.balanceLoaded,
      balances: balances ?? this.balances,
      leaveTypeKey: leaveTypeKey ?? this.leaveTypeKey,
      startDate: clearDates ? null : (startDate ?? this.startDate),
      endDate: clearDates ? null : (endDate ?? this.endDate),
      selectedFile: clearFile ? null : (selectedFile ?? this.selectedFile),
      errorMessage: clearMessages ? null : (errorMessage ?? this.errorMessage),
      successMessage: clearMessages ? null : (successMessage ?? this.successMessage),
    );
  }
}

// ==========================================
// 2. 逻辑控制器 (Controller)
// ==========================================
class LeaveApplicationController extends StateNotifier<LeaveApplicationState> {
  LeaveApplicationController() : super(LeaveApplicationState()) {
    fetchBalances();
  }

  void clearMessages() {
    if (mounted) state = state.copyWith(clearMessages: true);
  }

  void setLeaveType(String typeKey) {
    if (mounted) state = state.copyWith(leaveTypeKey: typeKey);
  }

  void setDates({DateTime? start, DateTime? end}) {
    if (!mounted) return;
    DateTime? newStart = start ?? state.startDate;
    DateTime? newEnd = end ?? state.endDate;

    // 逻辑保护：如果结束时间早于开始时间，重置结束时间
    if (newStart != null && newEnd != null && newEnd.isBefore(newStart)) {
      newEnd = null;
    }
    state = state.copyWith(startDate: newStart, endDate: newEnd);
  }

  Future<void> pickAttachment() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['jpg', 'jpeg', 'png', 'pdf'], 
      );

      if (result != null && mounted) {
        state = state.copyWith(selectedFile: result.files.first);
      }
    } catch (e) {
      debugPrint("Error picking file: $e");
    }
  }

  void removeAttachment() {
    if (mounted) state = state.copyWith(clearFile: true);
  }

  int calculateWorkingDays(DateTime? start, DateTime? end) {
    if (start == null || end == null) return 0;
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

  Future<void> fetchBalances() async {
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
          state = state.copyWith(
            balances: {
              ...state.balances,
              ...userData['leave_balance']
            },
            balanceLoaded: true,
          );
        }
      } else {
        if (mounted) state = state.copyWith(balanceLoaded: true);
      }
    } catch (e) {
      debugPrint("Error fetching balance: $e");
      if (mounted) state = state.copyWith(balanceLoaded: true); // 避免卡在loading
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

  String _getStandardEnglishType(String key) {
    switch (key) {
      case 'leave.type_annual': return 'Annual Leave';
      case 'leave.type_medical': return 'Medical Leave';
      case 'leave.type_unpaid': return 'Unpaid Leave';
      default: return 'Annual Leave';
    }
  }

  Future<void> submitApplication(String reasonText) async {
    if (state.startDate == null || state.endDate == null) {
      state = state.copyWith(errorMessage: "leave.error_select_dates", clearMessages: true);
      return;
    }

    int days = calculateWorkingDays(state.startDate, state.endDate);
    if (days <= 0) {
       state = state.copyWith(errorMessage: "leave.error_no_working_days", clearMessages: true);
       return;
    }

    if (state.leaveTypeKey == 'leave.type_annual') {
      int annualBal = (state.balances['annual'] is int) ? state.balances['annual'] : 0;
      if (annualBal < days) {
        state = state.copyWith(errorMessage: "leave.error_insufficient", clearMessages: true); // 会在 UI 层使用 args 翻译
        return;
      }
    } else if (state.leaveTypeKey == 'leave.type_medical') {
      int medicalBal = (state.balances['medical'] is int) ? state.balances['medical'] : 0;
      if (medicalBal < days) {
        state = state.copyWith(errorMessage: "leave.error_insufficient", clearMessages: true);
        return;
      }
    }

    if (state.leaveTypeKey == 'leave.type_medical' && state.selectedFile == null) {
      state = state.copyWith(errorMessage: "leave.error_upload_evidence", clearMessages: true);
      return;
    }

    state = state.copyWith(isLoading: true, clearMessages: true);

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw "User not authenticated";

      bool isDuplicate = await _checkForDuplicateLeave(user.uid, state.startDate!, state.endDate!);
      if (isDuplicate) {
        state = state.copyWith(isLoading: false, errorMessage: "You already have an approved leave for these dates.");
        return;
      }

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
      }

      String? attachmentUrl;
      String? fileType; 

      if (state.selectedFile != null && state.selectedFile!.path != null) {
        final String ext = state.selectedFile!.extension ?? 'file';
        final String fileName = '${DateTime.now().millisecondsSinceEpoch}_evidence.$ext';
        
        final Reference storageRef = FirebaseStorage.instance
            .ref()
            .child('leave_evidence')
            .child(user.uid)
            .child(fileName);
        
        File file = File(state.selectedFile!.path!);
        await storageRef.putFile(file);
        
        attachmentUrl = await storageRef.getDownloadURL();
        fileType = ext; 
      }

      Map<String, dynamic> leaveData = {
        'uid': empCode,
        'authUid': user.uid,
        'empName': empName,
        'email': empEmail,
        'type': _getStandardEnglishType(state.leaveTypeKey),
        'startDate': DateFormat('yyyy-MM-dd').format(state.startDate!),
        'endDate': DateFormat('yyyy-MM-dd').format(state.endDate!),
        'days': days, 
        'reason': reasonText,
        'status': 'Pending',
        'appliedAt': FieldValue.serverTimestamp(),
        'isPayrollDeductible': (state.leaveTypeKey == 'leave.type_unpaid'),
      };

      if (attachmentUrl != null) {
        leaveData['attachmentUrl'] = attachmentUrl;
        leaveData['fileType'] = fileType;
      }

      await FirebaseFirestore.instance.collection('leaves').add(leaveData);

      if (mounted) {
        state = state.copyWith(
          isLoading: false,
          successMessage: "leave.msg_submit_success",
          clearDates: true,
          clearFile: true,
        );
      }
    } catch (e) {
      if (mounted) state = state.copyWith(isLoading: false, errorMessage: "Error: $e");
    }
  }
}

// 暴露 Provider
final leaveApplicationProvider = StateNotifierProvider.autoDispose<LeaveApplicationController, LeaveApplicationState>((ref) {
  return LeaveApplicationController();
});