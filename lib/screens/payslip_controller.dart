import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:open_filex/open_filex.dart';
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;

import '../services/biometric_service.dart';

// ==========================================
// 1. 状态定义 (State)
// ==========================================
class PayslipState {
  final bool isGenerating;
  final String loadingText;
  
  // 弹窗提示
  final String? errorMessage;
  final String? successMessage;
  final bool shouldSwitchToDocumentsTab; // 用于提交成功后切回第一个 Tab

  PayslipState({
    this.isGenerating = false,
    this.loadingText = "Processing...",
    this.errorMessage,
    this.successMessage,
    this.shouldSwitchToDocumentsTab = false,
  });

  PayslipState copyWith({
    bool? isGenerating,
    String? loadingText,
    String? errorMessage,
    String? successMessage,
    bool? shouldSwitchToDocumentsTab,
    bool clearMessages = false,
    bool clearTabSwitch = false,
  }) {
    return PayslipState(
      isGenerating: isGenerating ?? this.isGenerating,
      loadingText: loadingText ?? this.loadingText,
      errorMessage: clearMessages ? null : (errorMessage ?? this.errorMessage),
      successMessage: clearMessages ? null : (successMessage ?? this.successMessage),
      shouldSwitchToDocumentsTab: clearTabSwitch ? false : (shouldSwitchToDocumentsTab ?? this.shouldSwitchToDocumentsTab),
    );
  }
}

// ==========================================
// 2. 逻辑控制器 (Controller)
// ==========================================
class PayslipController extends StateNotifier<PayslipState> {
  PayslipController() : super(PayslipState());

  void clearMessages() {
    if (mounted) state = state.copyWith(clearMessages: true);
  }

  void clearTabSwitch() {
    if (mounted) state = state.copyWith(clearTabSwitch: true);
  }

  // 🟢 核心功能：打开敏感文档前的生物识别验证
  Future<void> openSecuredDocument(Future<void> Function() onAuthenticated) async {
    bool success = await BiometricService().authenticateStaff();
    
    if (success) {
      await onAuthenticated();
    } else {
      if (mounted) {
        state = state.copyWith(
          errorMessage: "Authentication required to view sensitive documents.",
          clearMessages: true
        );
      }
    }
  }

  // --- LOGIC: Submit Advance Request ---
  Future<void> submitAdvanceRequest({
    required String amountText,
    required String reason,
    required bool agreedToDeduction,
    required String profileId,
    required Map<String, dynamic> userData,
    required String authUid,
  }) async {
    if (amountText.isEmpty || double.tryParse(amountText) == null || double.parse(amountText) <= 0) {
      state = state.copyWith(errorMessage: "Please enter a valid amount.", clearMessages: true);
      return;
    }
    if (reason.isEmpty) {
      state = state.copyWith(errorMessage: "Please provide a reason.", clearMessages: true);
      return;
    }
    if (!agreedToDeduction) {
      state = state.copyWith(errorMessage: "You must agree to the deduction terms.", clearMessages: true);
      return;
    }

    state = state.copyWith(isGenerating: true, loadingText: "Generating Agreement PDF...");
    
    final double amount = double.parse(amountText);
    final staffName = userData['personal']?['name'] ?? 'Unknown Staff';
    final icNo = userData['personal']?['icNumber'] ?? 'N/A';
    final staffCode = userData['empCode'] ?? 'N/A';

    try {
      final pdf = pw.Document();
      final dateNow = DateTime.now();
      final dateFormatted = DateFormat('dd MMMM yyyy').format(dateNow);

      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(40),
          build: (pw.Context context) {
            return pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Center(child: pw.Text("SALARY ADVANCE AGREEMENT (I.O.U)", style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold))),
                pw.SizedBox(height: 30),
                pw.Text("Date: $dateFormatted"),
                pw.SizedBox(height: 20),
                pw.Text("EMPLOYEE DETAILS", style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                pw.Divider(),
                pw.Text("Name: $staffName"),
                pw.Text("Employee ID: $staffCode"),
                pw.Text("IC Number: $icNo"),
                pw.SizedBox(height: 20),
                pw.Text("ADVANCE DETAILS", style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                pw.Divider(),
                pw.Text("Requested Amount: RM ${amount.toStringAsFixed(2)}"),
                pw.Text("Reason: $reason"),
                pw.SizedBox(height: 30),
                pw.Text("AGREEMENT", style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                pw.Divider(),
                pw.Text(
                  "I, $staffName (IC: $icNo), hereby acknowledge the request of a salary advance amounting to RM ${amount.toStringAsFixed(2)}.\n\n"
                  "I authorize the company to fully deduct this amount from my upcoming salary/payroll. "
                  "In the event of my resignation or termination prior to the deduction, I agree that this amount will be deducted from my final pay or I will reimburse the company immediately.",
                  style: const pw.TextStyle(lineSpacing: 1.5),
                ),
                pw.SizedBox(height: 50),
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.center,
                      children: [
                        pw.Text("___________________________"),
                        pw.SizedBox(height: 5),
                        pw.Text("Employee E-Signature / Confirmation"),
                        pw.Text("Confirmed via App on $dateFormatted", style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey)),
                      ]
                    ),
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.center,
                      children: [
                        pw.Text("___________________________"),
                        pw.SizedBox(height: 5),
                        pw.Text("Management Approval"),
                      ]
                    )
                  ]
                )
              ]
            );
          }
        )
      );

      final pdfBytes = await pdf.save();

      state = state.copyWith(loadingText: "Uploading Document...");
      final fileName = 'iou_${authUid}_${dateNow.millisecondsSinceEpoch}.pdf';
      final storageRef = FirebaseStorage.instance.ref().child('salary_advances').child(fileName);
      
      final uploadTask = storageRef.putData(pdfBytes, SettableMetadata(contentType: 'application/pdf'));
      final snapshot = await uploadTask;
      final downloadUrl = await snapshot.ref.getDownloadURL();

      state = state.copyWith(loadingText: "Submitting Request...");
      await FirebaseFirestore.instance.collection('salary_advances').add({
        'uid': profileId,
        'authUid': authUid,
        'empName': staffName,
        'empCode': staffCode,
        'amount': amount,
        'reason': reason,
        'status': 'Pending',
        'pdfUrl': downloadUrl,
        'appliedAt': FieldValue.serverTimestamp(),
      });

      if (mounted) {
        state = state.copyWith(
          isGenerating: false,
          successMessage: "Advance request submitted successfully!",
          shouldSwitchToDocumentsTab: true,
          clearMessages: true,
        );
      }
    } catch (e) {
      if (mounted) {
        state = state.copyWith(
          isGenerating: false,
          errorMessage: "Failed to submit: $e",
          clearMessages: true,
        );
      }
    }
  }

  // ===========================================================================
  // PDF HELPERS (Download IOU & Generate Payslip)
  // ===========================================================================

  Future<void> downloadAndOpenIouPdf(String url, dynamic timestamp) async {
    state = state.copyWith(isGenerating: true, loadingText: "Decrypting Document...");
    try {
      final response = await http.get(Uri.parse(url));
      final output = await getTemporaryDirectory();
      
      final timeSuffix = timestamp != null ? (timestamp as Timestamp).seconds.toString() : 'temp';
      final file = File("${output.path}/IOU_$timeSuffix.pdf");
      
      await file.writeAsBytes(response.bodyBytes);
      if (mounted) {
        state = state.copyWith(isGenerating: false);
        await OpenFilex.open(file.path);
      }
    } catch (e) {
      if (mounted) {
        state = state.copyWith(
          isGenerating: false,
          errorMessage: "Failed to open document: $e",
          clearMessages: true,
        );
      }
    }
  }

  Future<void> generateAndOpenPayslipPdf(Map<String, dynamic> data) async {
    state = state.copyWith(isGenerating: true, loadingText: "Decrypting Payslip...");

    try {
      final pdf = pw.Document();

      final basic = (data['basic'] ?? 0).toDouble();
      final earnings = data['earnings'] as Map<String, dynamic>? ?? {};
      final deductions = data['deductions'] as Map<String, dynamic>? ?? {};
      
      final gross = (data['gross'] ?? 0).toDouble();
      final net = (data['net'] ?? 0).toDouble();
      final totalDed = (deductions['total'] ?? 0).toDouble();

      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(32),
          build: (pw.Context context) {
            return pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Header(
                  level: 0,
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text("RH RIDER HUB MOTOR (M) SDN. BHD.", style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 18)),
                      pw.SizedBox(height: 4),
                      pw.Text("NO.26&28, JALAN MERU IMPIAN B3, CASA KAYANGAN @ PUSAT PERNIAGAAN MERU IMPIAN,\nBANDAR MERU RAYA, 30020 IPOH, Perak", style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
                      pw.SizedBox(height: 10),
                      pw.Align(
                        alignment: pw.Alignment.centerRight,
                        child: pw.Text("Payment Date: ${data['paymentDate'] ?? '-'}", style: const pw.TextStyle(fontSize: 10)),
                      ),
                    ],
                  ),
                ),
                pw.SizedBox(height: 20),
                pw.Row(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Expanded(
                      child: pw.Column(
                        children: [
                          _buildPdfRow("Employee Name", data['staffName']),
                          _buildPdfRow("Department", data['department']),
                          _buildPdfRow("Employee Code", data['staffCode']),
                        ],
                      ),
                    ),
                    pw.SizedBox(width: 20),
                    pw.Expanded(
                      child: pw.Column(
                        children: [
                          _buildPdfRow("IC Number", data['icNo']),
                          _buildPdfRow("EPF Number", data['epfNo']),
                          _buildPdfRow("Pay Period", data['period']),
                        ],
                      ),
                    ),
                  ],
                ),
                pw.SizedBox(height: 20),
                pw.Container(
                  decoration: const pw.BoxDecoration(border: pw.Border(top: pw.BorderSide(), bottom: pw.BorderSide())),
                  padding: const pw.EdgeInsets.symmetric(vertical: 5),
                  child: pw.Row(
                    children: [
                      pw.Expanded(flex: 3, child: pw.Text("EARNINGS", style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10))),
                      pw.Expanded(flex: 1, child: pw.Text("AMOUNT", textAlign: pw.TextAlign.right, style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10))),
                      pw.SizedBox(width: 20),
                      pw.Expanded(flex: 3, child: pw.Text("DEDUCTIONS", style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10))),
                      pw.Expanded(flex: 1, child: pw.Text("AMOUNT", textAlign: pw.TextAlign.right, style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10))),
                    ],
                  ),
                ),
                pw.SizedBox(height: 5),
                pw.Row(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Expanded(
                      child: pw.Column(
                        children: [
                          _buildLineItem("BASIC PAY", basic),
                          if ((earnings['commission'] ?? 0) > 0) _buildLineItem("COMMISSION", (earnings['commission']).toDouble()),
                          if ((earnings['ot'] ?? 0) > 0) _buildLineItem("OVERTIME", (earnings['ot']).toDouble()),
                          if ((earnings['allowance'] ?? 0) > 0) _buildLineItem("ALLOWANCE", (earnings['allowance']).toDouble()),
                        ],
                      ),
                    ),
                    pw.SizedBox(width: 20),
                    pw.Expanded(
                      child: pw.Column(
                        children: [
                          _buildLineItem("EPF (Employee)", (deductions['epf'] ?? 0).toDouble()),
                          _buildLineItem("SOCSO (Employee)", (deductions['socso'] ?? 0).toDouble()),
                          _buildLineItem("EIS (Employee)", (deductions['eis'] ?? 0).toDouble()),
                          if ((deductions['late'] ?? 0) > 0) _buildLineItem("LATE DEDUCTION", (deductions['late']).toDouble(), isDeduction: true),
                          if ((deductions['advance'] ?? 0) > 0) _buildLineItem("SALARY ADVANCE", (deductions['advance']).toDouble(), isDeduction: true),
                        ],
                      ),
                    ),
                  ],
                ),
                pw.SizedBox(height: 10),
                pw.Divider(),
                pw.Row(
                  children: [
                    pw.Expanded(
                      child: pw.Row(
                        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                        children: [
                          pw.Text("Total Earnings", style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10)),
                          pw.Text(gross.toStringAsFixed(2), style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10)),
                        ],
                      )
                    ),
                    pw.SizedBox(width: 20),
                    pw.Expanded(
                      child: pw.Row(
                        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                        children: [
                          pw.Text("Total Deductions", style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10)),
                          pw.Text(totalDed.toStringAsFixed(2), style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10)),
                        ],
                      )
                    ),
                  ],
                ),
                pw.SizedBox(height: 20),
                pw.Container(
                  padding: const pw.EdgeInsets.all(10),
                  decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey300)),
                  child: pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: [
                          _buildEmployerRow("Employer EPF", data['employer_epf']),
                          _buildEmployerRow("Employer SOCSO", data['employer_socso']),
                        ],
                      ),
                      pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.end,
                        children: [
                          pw.Text("NET PAY", style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
                          pw.Text("RM ${net.toStringAsFixed(2)}", style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 18, color: PdfColors.black)),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      );

      final output = await getTemporaryDirectory();
      final file = File("${output.path}/Payslip_${data['month']}.pdf");
      await file.writeAsBytes(await pdf.save());

      if (mounted) {
        state = state.copyWith(isGenerating: false);
        await OpenFilex.open(file.path);
      }
    } catch (e) {
      if (mounted) {
        state = state.copyWith(
          isGenerating: false,
          errorMessage: "Failed to generate PDF: $e",
          clearMessages: true,
        );
      }
    }
  }

  // --- PDF Build Helpers ---
  pw.Widget _buildPdfRow(String label, dynamic value) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 2),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(label, style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
          pw.Text(value?.toString() ?? "-", style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
        ],
      ),
    );
  }

  pw.Widget _buildLineItem(String label, double amount, {bool isDeduction = false}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 4),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(label, style: pw.TextStyle(fontSize: 9, color: isDeduction ? PdfColors.red : PdfColors.black)),
          pw.Text(amount.toStringAsFixed(2), style: pw.TextStyle(fontSize: 9, color: isDeduction ? PdfColors.red : PdfColors.black)),
        ],
      ),
    );
  }

  pw.Widget _buildEmployerRow(String label, dynamic val) {
    final amount = (val ?? 0).toDouble();
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 2),
      child: pw.Text("$label : ${amount.toStringAsFixed(2)}", style: const pw.TextStyle(fontSize: 8)),
    );
  }
}

// 暴露 Provider
final payslipProvider = StateNotifierProvider.autoDispose<PayslipController, PayslipState>((ref) {
  return PayslipController();
});