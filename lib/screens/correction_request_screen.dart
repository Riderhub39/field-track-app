import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

// 🟢 引入控制器
import 'correction_request_controller.dart';

class CorrectionRequestScreen extends ConsumerStatefulWidget {
  final DateTime date;
  final String? attendanceId; 
  final String originalIn;
  final String originalOut;

  const CorrectionRequestScreen({
    super.key,
    required this.date,
    this.attendanceId,
    required this.originalIn,
    required this.originalOut,
  });

  @override
  ConsumerState<CorrectionRequestScreen> createState() => _CorrectionRequestScreenState();
}

class _CorrectionRequestScreenState extends ConsumerState<CorrectionRequestScreen> {
  final TextEditingController _remarksCtrl = TextEditingController();

  @override
  void dispose() {
    _remarksCtrl.dispose();
    super.dispose();
  }

  Future<void> _selectTime(bool isIn) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
    );
    if (picked != null) {
      if (isIn) {
        ref.read(correctionProvider.notifier).setReqIn(picked);
      } else {
        ref.read(correctionProvider.notifier).setReqOut(picked);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(correctionProvider);
    final dateHeader = DateFormat('dd/MM/yyyy (EEEE)').format(widget.date);

    // 🟢 监听 Controller 的消息与页面导航状态
    ref.listen<CorrectionRequestState>(correctionProvider, (previous, next) {
      if (next.errorMessage != null && next.errorMessage != previous?.errorMessage) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(next.errorMessage!), backgroundColor: Colors.red));
        ref.read(correctionProvider.notifier).clearMessages();
      }

      if (next.successMessage != null && next.successMessage != previous?.successMessage) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(next.successMessage!), backgroundColor: Colors.green));
        ref.read(correctionProvider.notifier).clearMessages();
      }

      if (next.shouldPop && !(previous?.shouldPop ?? false)) {
        Navigator.pop(context);
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: Text("Correct: $dateHeader", style: const TextStyle(fontSize: 16)),
        backgroundColor: const Color(0xFF15438c), 
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 1. 显示原始数据
            const Text("Original Record", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.grey)),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(15),
              decoration: BoxDecoration(color: Colors.grey[200], borderRadius: BorderRadius.circular(8)),
              child: Column(
                children: [
                  _buildRow("Time In", widget.originalIn),
                  const Divider(height: 20),
                  _buildRow("Time Out", widget.originalOut),
                ],
              ),
            ),
            
            const SizedBox(height: 30),

            // 2. 请求修改的数据
            const Text("Correction Request", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.blue)),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(child: _buildTimePicker(context, "New Time In", state.reqIn, true)),
                const SizedBox(width: 20),
                Expanded(child: _buildTimePicker(context, "New Time Out", state.reqOut, false)),
              ],
            ),

            const SizedBox(height: 20),

            // 3. 备注
            const Text("Reason / Remarks", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
            const SizedBox(height: 5),
            TextField(
              controller: _remarksCtrl,
              decoration: InputDecoration(
                hintText: "Why do you need this correction?",
                filled: true,
                fillColor: Colors.grey[100],
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
              ),
              maxLines: 2,
            ),

            const SizedBox(height: 20),

            // 4. 附件/证据
            const Text("Proof (Optional)", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
            const SizedBox(height: 8),
            
            GestureDetector(
              onTap: () => ref.read(correctionProvider.notifier).pickImage(),
              child: Container(
                width: double.infinity,
                height: 120,
                decoration: BoxDecoration(
                  color: Colors.grey[100], 
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey[300]!, style: BorderStyle.solid),
                  image: state.selectedFile != null 
                    ? DecorationImage(
                        image: FileImage(File(state.selectedFile!.path)), 
                        fit: BoxFit.cover
                      ) 
                    : null
                ),
                child: state.selectedFile == null 
                  ? const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.add_a_photo, size: 30, color: Colors.grey),
                        SizedBox(height: 4),
                        Text("Upload photo/screenshot", style: TextStyle(color: Colors.grey, fontSize: 12))
                      ],
                    )
                  : Stack(
                      children: [
                        Positioned(
                          top: 5, right: 5,
                          child: GestureDetector(
                            onTap: () => ref.read(correctionProvider.notifier).removeImage(),
                            child: Container(
                              padding: const EdgeInsets.all(4),
                              decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
                              child: const Icon(Icons.close, color: Colors.white, size: 16),
                            ),
                          ),
                        )
                      ],
                    ),
              ),
            ),

            const SizedBox(height: 40),

            // 5. 提交按钮
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: state.isLoading ? null : () {
                  ref.read(correctionProvider.notifier).submitRequest(
                    context: context,
                    targetDate: widget.date,
                    attendanceId: widget.attendanceId,
                    originalIn: widget.originalIn,
                    originalOut: widget.originalOut,
                    remarks: _remarksCtrl.text.trim(),
                  );
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00C853), 
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: state.isLoading 
                  ? const CircularProgressIndicator(color: Colors.white) 
                  : const Text("SUBMIT REQUEST", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.black54)),
        Text(value, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black87, fontSize: 16)),
      ],
    );
  }

  Widget _buildTimePicker(BuildContext context, String label, TimeOfDay? time, bool isIn) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.black54)),
        const SizedBox(height: 5),
        GestureDetector(
          onTap: () => _selectTime(isIn),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white, 
              border: Border.all(color: Colors.grey[300]!),
              borderRadius: BorderRadius.circular(8)
            ),
            child: Center(
              child: Text(
                time?.format(context) ?? "Select",
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: time != null ? Colors.blue[800] : Colors.grey
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}