import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:easy_localization/easy_localization.dart';
import '../widgets/shimmer_loading.dart';

// 🟢 引入控制器
import 'payslip_controller.dart';

class PayslipScreen extends ConsumerStatefulWidget {
  const PayslipScreen({super.key});

  @override
  ConsumerState<PayslipScreen> createState() => _PayslipScreenState();
}

class _PayslipScreenState extends ConsumerState<PayslipScreen> {
  final TextEditingController _amountCtrl = TextEditingController();
  final TextEditingController _reasonCtrl = TextEditingController();
  bool _agreedToDeduction = false;

  @override
  void dispose() {
    _amountCtrl.dispose();
    _reasonCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      return Scaffold(
        appBar: AppBar(title: const Text("Payslip & Advance")),
        body: const Center(child: Text("Please login first")),
      );
    }

    final state = ref.watch(payslipProvider);

    // 🟢 监听状态改变以显示弹窗或切换 Tab
    ref.listen<PayslipState>(payslipProvider, (previous, next) {
      if (next.errorMessage != null && next.errorMessage != previous?.errorMessage) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(next.errorMessage!), backgroundColor: Colors.red));
        ref.read(payslipProvider.notifier).clearMessages();
      }

      if (next.successMessage != null && next.successMessage != previous?.successMessage) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(next.successMessage!), backgroundColor: Colors.green));
        // 清空表单
        _amountCtrl.clear();
        _reasonCtrl.clear();
        setState(() => _agreedToDeduction = false);
        ref.read(payslipProvider.notifier).clearMessages();
      }

      if (next.shouldSwitchToDocumentsTab && !(previous?.shouldSwitchToDocumentsTab ?? false)) {
        DefaultTabController.of(context).animateTo(0);
        ref.read(payslipProvider.notifier).clearTabSwitch();
      }
    });

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
                  return const ShimmerLoadingList(itemHeight: 80);
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
                    _buildAdvanceRequestTab(profileId, userData, user.uid, state.isGenerating),
                  ],
                );
              },
            ),

            // Loading Overlay 
            if (state.isGenerating)
              Container(
                color: Colors.black45,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(color: Colors.white),
                      const SizedBox(height: 16),
                      Text(state.loadingText, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold))
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
              
              // 基于月份去重，只保留同一月份最新的记录
              final Map<String, Map<String, dynamic>> uniquePayslips = {};
              
              for (var doc in rawDocs) {
                final data = doc.data() as Map<String, dynamic>;
                final month = data['month']?.toString() ?? 'Unknown';
                
                if (!uniquePayslips.containsKey(month)) {
                  uniquePayslips[month] = data;
                } else {
                  final currentTs = uniquePayslips[month]!['createdAt'] as Timestamp?;
                  final newTs = data['createdAt'] as Timestamp?;
                  
                  if (currentTs != null && newTs != null && newTs.compareTo(currentTs) > 0) {
                     uniquePayslips[month] = data;
                  }
                }
              }

              final docsList = uniquePayslips.values.toList();
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
        onTap: () {
          ref.read(payslipProvider.notifier).openSecuredDocument(() => 
            ref.read(payslipProvider.notifier).generateAndOpenPayslipPdf(data)
          );
        }, 
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
              IconButton(
                icon: const Icon(Icons.picture_as_pdf, color: Colors.redAccent),
                onPressed: () {
                  ref.read(payslipProvider.notifier).openSecuredDocument(() => 
                    ref.read(payslipProvider.notifier).downloadAndOpenIouPdf(data['pdfUrl'], data['appliedAt'])
                  );
                },
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

  Widget _buildAdvanceRequestTab(String profileId, Map<String, dynamic> userData, String authUid, bool isGenerating) {
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
                  onPressed: isGenerating ? null : () {
                    ref.read(payslipProvider.notifier).submitAdvanceRequest(
                      amountText: _amountCtrl.text,
                      reason: _reasonCtrl.text,
                      agreedToDeduction: _agreedToDeduction,
                      profileId: profileId,
                      userData: userData,
                      authUid: authUid,
                    );
                  },
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
}