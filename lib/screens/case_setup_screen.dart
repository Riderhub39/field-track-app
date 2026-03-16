import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'camera_screen.dart';
import 'camera_controller.dart'; // 引入 CapturedPhoto

class CaseSetupScreen extends StatefulWidget {
  const CaseSetupScreen({super.key});

  @override
  State<CaseSetupScreen> createState() => _CaseSetupScreenState();
}

class _CaseSetupScreenState extends State<CaseSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _clientNameController = TextEditingController();

  // 🟢 用于管理预览区和上传的照片
  final List<CapturedPhoto> _pendingPhotos = [];
  final Set<CapturedPhoto> _selectedPhotos = {};
  bool _isUploading = false;

  Future<void> _openCamera() async {
    if (_formKey.currentState!.validate()) {
      // 等待相机页面返回拍好的照片列表
      final result = await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => CameraScreen(
            clientName: _clientNameController.text.trim(),
          ),
        ),
      );

      // 如果带回了照片，追加到待上传列表中
      if (result != null && result is List<CapturedPhoto> && result.isNotEmpty) {
        setState(() {
          _pendingPhotos.addAll(result);
          _selectedPhotos.addAll(result); // 默认全选新拍的照片
        });
      }
    }
  }

  // 🟢 终极上传与分配 Case No 逻辑
  Future<void> _uploadSelectedPhotos() async {
    if (_selectedPhotos.isEmpty) return;
    setState(() => _isUploading = true);

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception("User not logged in");

      // 1. 生成 C-0001-20260316 格式的 Case No
      final dateStr = DateFormat('yyyyMMdd').format(DateTime.now());
      final snap = await FirebaseFirestore.instance
          .collection('evidence_logs')
          .where('caseNo', isGreaterThanOrEqualTo: 'C-')
          .where('caseNo', isLessThan: 'C-\uf8ff')
          .orderBy('caseNo', descending: true)
          .limit(1)
          .get();

      String finalCaseNo;
      if (snap.docs.isEmpty) {
        finalCaseNo = "C-0001-$dateStr";
      } else {
        String lastCaseNo = snap.docs.first.data()['caseNo'] ?? "";
        final parts = lastCaseNo.split('-');
        int lastNum = 0;
        if (parts.length >= 2) {
          lastNum = int.tryParse(parts[1]) ?? 0;
        }
        finalCaseNo = "C-${(lastNum + 1).toString().padLeft(4, '0')}-$dateStr";
      }

      // 2. 遍历选中的照片，上传并写入数据库
      for (var photo in _selectedPhotos) {
        File file = File(photo.path);
        String fileName = file.path.split('/').last;

        Reference storageRef = FirebaseStorage.instance.ref().child('accident_evidence').child(fileName);
        await storageRef.putFile(file);
        String downloadUrl = await storageRef.getDownloadURL();

        await FirebaseFirestore.instance.collection('evidence_logs').add({
          'uid': user.uid,
          'staffName': photo.staffName,
          'caseNo': finalCaseNo,
          'clientName': _clientNameController.text.trim(),
          'photoUrl': downloadUrl,
          'location': photo.address,
          'capturedAt': FieldValue.serverTimestamp(),
          'localTime': photo.dateTimeStr,
          'fileName': fileName,
          'type': 'accident_evidence'
        });
      }

      // 3. 上传成功后，从预览列表中移除已上传的
      setState(() {
        _pendingPhotos.removeWhere((p) => _selectedPhotos.contains(p));
        _selectedPhotos.clear();
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("✅ Upload successful! Case No: $finalCaseNo"), backgroundColor: Colors.green)
        );
      }

    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("❌ Upload failed: $e"), backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  // 防手滑退出提醒
  Future<bool> _onWillPop() async {
    if (_pendingPhotos.isEmpty || _isUploading) return true;
    
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Discard Unsaved Photos?", style: TextStyle(fontWeight: FontWeight.bold)),
        content: const Text("You have photos that are not uploaded yet. If you go back, these photos will not be saved to the database. Are you sure?"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("Cancel")),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text("Discard", style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  void dispose() {
    _clientNameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldPop = await _onWillPop();
        if (shouldPop && context.mounted) {
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text("Smart Camera Setup", style: TextStyle(fontWeight: FontWeight.bold)),
          backgroundColor: Colors.blue,
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("Evidence Details", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF15438c))),
                const SizedBox(height: 8),
                const Text("Please enter the client name. You can take multiple photos, preview them, and then upload them together under a single Case No.", style: TextStyle(color: Colors.grey, fontSize: 14)),
                const SizedBox(height: 32),

                const Text("Client Name (Optional)", style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _clientNameController,
                  decoration: InputDecoration(
                    hintText: "e.g. John Doe Corp",
                    prefixIcon: const Icon(Icons.business),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    filled: true, fillColor: Colors.grey.shade50,
                  ),
                ),
                const SizedBox(height: 24),

                SizedBox(
                  width: double.infinity, height: 55,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue.shade50, foregroundColor: Colors.blue.shade700,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      elevation: 0,
                    ),
                    icon: const Icon(Icons.add_a_photo),
                    label: const Text("Take Photos", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    onPressed: _openCamera, 
                  ),
                ),
                const SizedBox(height: 32),

                // 🟢 预览区域
                if (_pendingPhotos.isNotEmpty) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text("Pending Upload (${_pendingPhotos.length})", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                      TextButton(
                        onPressed: () {
                          setState(() {
                            if (_selectedPhotos.length == _pendingPhotos.length) {
                              _selectedPhotos.clear();
                            } else {
                              _selectedPhotos.addAll(_pendingPhotos);
                            }
                          });
                        }, 
                        child: Text(_selectedPhotos.length == _pendingPhotos.length ? "Deselect All" : "Select All")
                      )
                    ],
                  ),
                  const SizedBox(height: 16),

                  // 照片网格
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                      childAspectRatio: 0.8,
                    ),
                    itemCount: _pendingPhotos.length,
                    itemBuilder: (context, index) {
                      final photo = _pendingPhotos[index];
                      final isSelected = _selectedPhotos.contains(photo);
                      return GestureDetector(
                        onTap: () {
                          setState(() {
                            isSelected ? _selectedPhotos.remove(photo) : _selectedPhotos.add(photo);
                          });
                        },
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.file(File(photo.path), fit: BoxFit.cover),
                            ),
                            // 半透明遮罩
                            if (isSelected)
                              Container(decoration: BoxDecoration(color: Colors.blue.withValues(alpha:0.3), borderRadius: BorderRadius.circular(8))),
                            // 勾选框
                            Positioned(
                              top: 4, right: 4,
                              child: Icon(isSelected ? Icons.check_circle : Icons.circle_outlined, color: isSelected ? Colors.blue : Colors.white, size: 28),
                            )
                          ],
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 32),

                  // 上传按钮
                  SizedBox(
                    width: double.infinity, height: 60,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green, foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      icon: _isUploading ? const SizedBox(width:24, height:24, child: CircularProgressIndicator(color:Colors.white, strokeWidth:2)) : const Icon(Icons.cloud_upload),
                      label: Text(_isUploading ? "Uploading..." : "Upload ${_selectedPhotos.length} Selected", style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      onPressed: (_isUploading || _selectedPhotos.isEmpty) ? null : _uploadSelectedPhotos,
                    ),
                  ),
                  const SizedBox(height: 40),
                ]
              ],
            ),
          ),
        ),
      ),
    );
  }
}