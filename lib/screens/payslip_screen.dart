import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:open_filex/open_filex.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:http/http.dart' as http;

// 🟢 导入生物识别服务
import '../services/biometric_service.dart';

class PayslipScreen extends StatefulWidget {
  const PayslipScreen({super.key});

  @override
  State<PayslipScreen> createState() => _PayslipScreenState();
}

class _PayslipScreenState extends State<PayslipScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  bool _isGenerating = false;
  String _loadingText = "Processing...";

  // --- Salary Advance Form Controllers ---
  final TextEditingController _amountCtrl = TextEditingController();
  final TextEditingController _reasonCtrl = TextEditingController();
  bool _agreedToDeduction = false;

  @override
  void dispose() {
    _amountCtrl.dispose();
    _reasonCtrl.dispose();
    super.dispose();
  }

  // 🟢 核心功能：打开敏感文档前的生物识别验证
  Future<void> _openSecuredDocument(Function onAuthenticated) async {
    bool success = await BiometricService().authenticateStaff();
    
    if (success) {
      onAuthenticated(); // 验证成功，执行打开操作
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Authentication required to view sensitive documents."),
            backgroundColor: Colors.red,
          )
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = _auth.currentUser;

    if (user == null) {
      return Scaffold(
        appBar: AppBar(title: const Text("Payslip & Advance")),
        body: const Center(child: Text("Please login first")),
      );
    }

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: Colors.grey[100],
        appBar: AppBar(
          title: Text("home.payslip".tr()), 
          backgroundColor: Colors.white,
          elevation: 0.5,
          foregroundColor: Colors.black,
          bottom: const TabBar(
            labelColor: Colors.blue,
            unselectedLabelColor: Colors.grey,
            indicatorColor: Colors.blue,
            tabs: [
              Tab(icon: Icon(Icons.folder_shared), text: "My Documents"),
              Tab(icon: Icon(Icons.request_quote), text: "Request Advance"),
            ],
          ),
        ),
        body: Stack(
          children: [
            FutureBuilder<QuerySnapshot>(
              future: FirebaseFirestore.instance
                  .collection('users')
                  .where('authUid', isEqualTo: user.uid)
                  .limit(1)
                  .get(),
              builder: (context, userSnap) {
                if (userSnap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (!userSnap.hasData || userSnap.data!.docs.isEmpty) {
                  return const Center(child: Text("Profile not linked. Contact Admin."));
                }

                final profileDoc = userSnap.data!.docs.first;
                final profileId = profileDoc.id;
                final userData = profileDoc.data() as Map<String, dynamic>;

                return TabBarView(
                  children: [
                    // --- TAB 1: PAYSLIPS & ADVANCE RECORDS ---
                    _buildDocumentsTab(profileId, user.uid),

                    // --- TAB 2: REQUEST FORM ---
                    _buildAdvanceRequestTab(profileId, userData, user.uid),
                  ],
                );
              },
            ),

            // Loading Overlay 
            if (_isGenerating)
              Container(
                color: Colors.black45,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(color: Colors.white),
                      const SizedBox(height: 16),
                      Text(_loadingText, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold))
                    ],
                  ),
                ),
              )
          ],
        ),
      ),
    );
  }

  // ===========================================================================
  // TAB 1: DOCUMENTS (PAYSLIPS + RECORDS)
  // ===========================================================================

  Widget _buildDocumentsTab(String profileId, String authUid) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Section 1: Payslips
          const Text("Monthly Payslips", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 10),
          StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('payslips')
                .where('uid', isEqualTo: profileId)
                .where('status', isEqualTo: 'Published')
                .snapshots(),
            builder: (context, snapshot) {
              if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Center(child: Text("No payslips found.", style: TextStyle(color: Colors.grey))),
                );
              }

              final rawDocs = snapshot.data!.docs;
              
              // 🟢 核心防护：基于月份去重，只保留同一月份最新的记录（以防 Web 端迁移旧数据时的残留）
              final Map<String, Map<String, dynamic>> uniquePayslips = {};
              
              for (var doc in rawDocs) {
                final data = doc.data() as Map<String, dynamic>;
                final month = data['month']?.toString() ?? 'Unknown';
                
                if (!uniquePayslips.containsKey(month)) {
                  uniquePayslips[month] = data;
                } else {
                  // 如果有重复的月份，比较 createdAt 时间，保留最新的
                  final currentTs = uniquePayslips[month]!['createdAt'] as Timestamp?;
                  final newTs = data['createdAt'] as Timestamp?;
                  
                  if (currentTs != null && newTs != null && newTs.compareTo(currentTs) > 0) {
                     uniquePayslips[month] = data;
                  }
                }
              }

              final docsList = uniquePayslips.values.toList();

              // 按照月份倒序排列 (最新月份在上)
              docsList.sort((a, b) {
                final mA = a['month'] ?? '';
                final mB = b['month'] ?? '';
                return mB.compareTo(mA);
              });

              if (docsList.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Center(child: Text("No payslips found.", style: TextStyle(color: Colors.grey))),
                );
              }

              return ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: docsList.length,
                itemBuilder: (context, index) {
                  return _buildPayslipCard(docsList[index]);
                },
              );
            },
          ),

          const SizedBox(height: 30),

          // Section 2: Salary Advance Records
          const Text("Salary Advance Records", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 10),
          StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('salary_advances')
                .where('authUid', isEqualTo: authUid)
                .orderBy('appliedAt', descending: true)
                .snapshots(),
            builder: (context, snapshot) {
              if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Center(child: Text("No advance requests found.", style: TextStyle(color: Colors.grey))),
                );
              }

              return ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: snapshot.data!.docs.length,
                itemBuilder: (context, index) {
                  final data = snapshot.data!.docs[index].data() as Map<String, dynamic>;
                  return _buildAdvanceRecordCard(data);
                },
              );
            },
          )
        ],
      ),
    );
  }

  // --- CARDS ---

  Widget _buildPayslipCard(Map<String, dynamic> data) {
    final dateObj = DateTime.tryParse("${data['month']}-01");
    final monthStr = dateObj != null ? DateFormat('MMMM yyyy').format(dateObj) : data['month'];
    final netPay = (data['net'] ?? 0).toDouble();

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: Colors.grey.shade300)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        // 🟢 加入生物识别验证
        onTap: () => _openSecuredDocument(() => _generateAndOpenPayslipPdf(data)), 
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Colors.blue[50], borderRadius: BorderRadius.circular(10)),
                child: const Icon(Icons.receipt_long, color: Colors.blue),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(monthStr, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 4),
                    Text("Net Pay: RM ${netPay.toStringAsFixed(2)}", style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
              const Icon(Icons.lock_outline, color: Colors.grey, size: 20), // 提示需解锁
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAdvanceRecordCard(Map<String, dynamic> data) {
    final amount = (data['amount'] ?? 0).toDouble();
    final status = data['status'] ?? 'Pending';
    final dateStr = data['appliedAt'] != null 
        ? DateFormat('dd MMM yyyy').format((data['appliedAt'] as Timestamp).toDate()) 
        : '-';
    
    Color statusColor = Colors.orange;
    if (status == 'Approved') statusColor = Colors.green;
    if (status == 'Rejected') statusColor = Colors.red;

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: Colors.grey.shade300)),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: Colors.purple.shade50, borderRadius: BorderRadius.circular(8)),
          child: const Icon(Icons.account_balance_wallet, color: Colors.purple),
        ),
        title: Text("RM ${amount.toStringAsFixed(2)}", style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(dateStr, style: const TextStyle(fontSize: 12)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(color: statusColor.withValues(alpha:0.1), borderRadius: BorderRadius.circular(6)),
              child: Text(status, style: TextStyle(color: statusColor, fontSize: 12, fontWeight: FontWeight.bold)),
            ),
            if (data['pdfUrl'] != null) ...[
              const SizedBox(width: 8),
              // 🟢 加入生物识别验证来查看借据 PDF
              IconButton(
                icon: const Icon(Icons.picture_as_pdf, color: Colors.redAccent),
                onPressed: () => _openSecuredDocument(() => _downloadAndOpenIouPdf(data['pdfUrl'], data['appliedAt'])),
              )
            ]
          ],
        ),
      ),
    );
  }

  // ===========================================================================
  // TAB 2: REQUEST ADVANCE FORM
  // ===========================================================================

  Widget _buildAdvanceRequestTab(String profileId, Map<String, dynamic> userData, String authUid) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Card(
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: Colors.grey.shade300)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("Request Salary Advance", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
              const SizedBox(height: 8),
              const Text("Submit an I.O.U request. If approved, this amount will be deducted from your next payslip. A formal PDF will be generated.", style: TextStyle(color: Colors.grey, fontSize: 13)),
              const SizedBox(height: 20),
              
              TextField(
                controller: _amountCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: "Amount",
                  prefixText: "RM ",
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
              const SizedBox(height: 16),

              TextField(
                controller: _reasonCtrl,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: "Reason",
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
              const SizedBox(height: 16),

              Container(
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange.shade200)
                ),
                child: CheckboxListTile(
                  value: _agreedToDeduction,
                  onChanged: (val) => setState(() => _agreedToDeduction = val ?? false),
                  title: const Text(
                    "I formally agree that this requested amount will be fully deducted from my upcoming salary.",
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.black87),
                  ),
                  controlAffinity: ListTileControlAffinity.leading,
                  activeColor: Colors.orange,
                ),
              ),
              const SizedBox(height: 20),

              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.blue, foregroundColor: Colors.white),
                  onPressed: () => _submitAdvanceRequest(profileId, userData, authUid),
                  icon: const Icon(Icons.gavel, size: 18),
                  label: const Text("Generate I.O.U & Submit", style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              )
            ],
          ),
        ),
      ),
    );
  }

  // --- LOGIC: Submit Advance Request ---
  Future<void> _submitAdvanceRequest(String profileId, Map<String, dynamic> userData, String authUid) async {
    final amountText = _amountCtrl.text.trim();
    final reason = _reasonCtrl.text.trim();

    if (amountText.isEmpty || double.tryParse(amountText) == null || double.parse(amountText) <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Please enter a valid amount.")));
      return;
    }
    if (reason.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Please provide a reason.")));
      return;
    }
    if (!_agreedToDeduction) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("You must agree to the deduction terms.")));
      return;
    }

    setState(() { _isGenerating = true; _loadingText = "Generating Agreement PDF..."; });
    
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

      setState(() => _loadingText = "Uploading Document...");
      final fileName = 'iou_${authUid}_${dateNow.millisecondsSinceEpoch}.pdf';
      final storageRef = FirebaseStorage.instance.ref().child('salary_advances').child(fileName);
      
      final uploadTask = storageRef.putData(pdfBytes, SettableMetadata(contentType: 'application/pdf'));
      final snapshot = await uploadTask;
      final downloadUrl = await snapshot.ref.getDownloadURL();

      setState(() => _loadingText = "Submitting Request...");
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
        setState(() {
          _isGenerating = false;
          _amountCtrl.clear();
          _reasonCtrl.clear();
          _agreedToDeduction = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Advance request submitted successfully!"), backgroundColor: Colors.green));
        // Switch back to tab 1 automatically to see the pending record
        DefaultTabController.of(context).animateTo(0);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isGenerating = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Failed to submit: $e"), backgroundColor: Colors.red));
      }
    }
  }

  // ===========================================================================
  // PDF HELPERS (Download IOU & Generate Payslip)
  // ===========================================================================

  // 🟢 下载并打开 I.O.U 借据
  Future<void> _downloadAndOpenIouPdf(String url, dynamic timestamp) async {
    setState(() { _isGenerating = true; _loadingText = "Decrypting Document..."; });
    try {
      final response = await http.get(Uri.parse(url));
      final output = await getTemporaryDirectory();
      
      final timeSuffix = timestamp != null ? (timestamp as Timestamp).seconds.toString() : 'temp';
      final file = File("${output.path}/IOU_$timeSuffix.pdf");
      
      await file.writeAsBytes(response.bodyBytes);
      if (mounted) {
        setState(() => _isGenerating = false);
        await OpenFilex.open(file.path);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isGenerating = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Failed to open document: $e")));
      }
    }
  }

  // 🟢 在本地排版并打开薪资单
  Future<void> _generateAndOpenPayslipPdf(Map<String, dynamic> data) async {
    setState(() { _isGenerating = true; _loadingText = "Decrypting Payslip..."; });

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
        setState(() => _isGenerating = false);
        await OpenFilex.open(file.path);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isGenerating = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Failed to generate PDF: $e")));
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