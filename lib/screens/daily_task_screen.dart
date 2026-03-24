import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// 🟢 引入重构后的 Provider
import 'daily_task_controller.dart';

class DailyTaskScreen extends ConsumerStatefulWidget {
  const DailyTaskScreen({super.key});

  @override
  ConsumerState<DailyTaskScreen> createState() => _DailyTaskScreenState();
}

class _DailyTaskScreenState extends ConsumerState<DailyTaskScreen> {
  // 🟢 将 TextEditingController 移至 State 中管理，这是 Flutter 推荐的做法
  final _salesNameController = TextEditingController();
  final _leadsController = TextEditingController();
  final _viewersController = TextEditingController();
  final _commentController = TextEditingController();
  final _topViewController = TextEditingController();
  final _avgViewController = TextEditingController();
  final _liveCountController = TextEditingController();

  @override
  void dispose() {
    _salesNameController.dispose();
    _leadsController.dispose();
    _viewersController.dispose();
    _commentController.dispose();
    _topViewController.dispose();
    _avgViewController.dispose();
    _liveCountController.dispose();
    super.dispose();
  }

  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Error'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showSuccessDialog(String message) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Success', style: TextStyle(color: Colors.green)),
        content: Text(message),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx); // Close dialog
              Navigator.pop(context); // Close screen
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 🟢 监听状态
    final state = ref.watch(dailyTaskProvider);

    // 🟢 监听反馈事件 (错误弹窗 / 成功返回)
    ref.listen<DailyTaskState>(dailyTaskProvider, (previous, next) {
      if (next.errorMessage != null && next.errorMessage != previous?.errorMessage) {
        _showErrorDialog(next.errorMessage!);
        ref.read(dailyTaskProvider.notifier).clearMessages();
      }
      if (next.successMessage != null && next.successMessage != previous?.successMessage) {
        if (next.shouldPop) {
          _showSuccessDialog(next.successMessage!);
        }
        ref.read(dailyTaskProvider.notifier).clearMessages();
      }
    });

    return Scaffold(
      appBar: AppBar(title: const Text("Daily Task Update")),
      body: state.isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 日期选择
                  ListTile(
                    title: Text("Date: ${state.selectedDate.toString().split(' ')[0]}"),
                    trailing: const Icon(Icons.calendar_today),
                    onTap: () async {
                      DateTime? picked = await showDatePicker(
                        context: context,
                        initialDate: state.selectedDate,
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2101),
                      );
                      if (picked != null) {
                        ref.read(dailyTaskProvider.notifier).setDate(picked);
                      }
                    },
                  ),
                  
                  _buildTextField(_salesNameController, "Sales Name"),
                  
                  // 下拉选择 Account Type
                  DropdownButtonFormField<String>(
                    initialValue: state.accountType,
                    items: ['Personal', 'Company'].map((type) => 
                      DropdownMenuItem(value: type, child: Text(type))).toList(),
                    onChanged: (val) {
                      if (val != null) {
                        ref.read(dailyTaskProvider.notifier).setAccountType(val);
                      }
                    },
                    decoration: const InputDecoration(labelText: "Account Type"),
                  ),

                  _buildTextField(_liveCountController, "Live Times", isNumber: true),
                  _buildTextField(_leadsController, "Leads", isNumber: true),
                  _buildTextField(_viewersController, "Total Viewers", isNumber: true),
                  _buildTextField(_topViewController, "Top View", isNumber: true),
                  _buildTextField(_avgViewController, "Average View", isNumber: true),
                  
                  // Boosted Switch
                  SwitchListTile(
                    title: const Text("Boosted?"),
                    value: state.isBoosted,
                    onChanged: (val) {
                      ref.read(dailyTaskProvider.notifier).setBoosted(val);
                    },
                  ),

                  _buildTextField(_commentController, "Comment", maxLines: 3),

                  const SizedBox(height: 20),
                  const Text("Photos", style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 10),
                  
                  // 🟢 图片预览网格
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                    ),
                    itemCount: state.selectedImages.length + 1,
                    itemBuilder: (context, index) {
                      if (index == state.selectedImages.length) {
                        return InkWell(
                          onTap: () => ref.read(dailyTaskProvider.notifier).pickImages(),
                          child: Container(
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.grey),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(Icons.add_a_photo, size: 40, color: Colors.grey),
                          ),
                        );
                      }
                      return Stack(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.file(
                              state.selectedImages[index], 
                              fit: BoxFit.cover, 
                              width: double.infinity, 
                              height: double.infinity
                            ),
                          ),
                          Positioned(
                            right: 0,
                            top: 0,
                            child: GestureDetector(
                              onTap: () => ref.read(dailyTaskProvider.notifier).removeImage(index),
                              child: const CircleAvatar(
                                radius: 12,
                                backgroundColor: Colors.red,
                                child: Icon(Icons.close, size: 16, color: Colors.white),
                              ),
                            ),
                          )
                        ],
                      );
                    },
                  ),
                  
                  const SizedBox(height: 30),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: state.isLoading 
                          ? null 
                          : () {
                              // 🟢 触发提交，将 TextEditingController 的值传给 Provider
                              ref.read(dailyTaskProvider.notifier).submitTask(
                                salesName: _salesNameController.text.trim(),
                                leads: _leadsController.text.trim(),
                                viewers: _viewersController.text.trim(),
                                comment: _commentController.text.trim(),
                                topView: _topViewController.text.trim(),
                                avgView: _avgViewController.text.trim(),
                                liveCount: _liveCountController.text.trim(),
                              );
                            },
                      child: const Text("Submit Daily Update", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    ),
                  )
                ],
              ),
            ),
    );
  }

  Widget _buildTextField(TextEditingController ctrl, String label, {bool isNumber = false, int maxLines = 1}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: TextField(
        controller: ctrl,
        keyboardType: isNumber ? TextInputType.number : TextInputType.text,
        maxLines: maxLines,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}