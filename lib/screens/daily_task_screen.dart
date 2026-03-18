import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'daily_task_controller.dart';

class DailyTaskScreen extends StatelessWidget {
  // 修复 1: 添加了命名的 key 参数
  const DailyTaskScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // 这里的 controller 不需要 const，因为它是在运行时初始化的
    final controller = Get.put(DailyTaskController());

    return Scaffold(
      appBar: AppBar(title: const Text("Daily Task Update")),
      body: Obx(() => controller.isLoading.value 
        ? const Center(child: CircularProgressIndicator()) 
        : SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 日期选择
                ListTile(
                  title: Text("Date: ${controller.selectedDate.value.toString().split(' ')[0]}"),
                  trailing: const Icon(Icons.calendar_today),
                  onTap: () async {
                    DateTime? picked = await showDatePicker(
                      context: context,
                      initialDate: DateTime.now(),
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2101),
                    );
                    if (picked != null) controller.selectedDate.value = picked;
                  },
                ),
                
                _buildTextField(controller.salesNameController, "Sales Name"),
                
                // 修复 2: 根据弃用警告，将 value 替换为 initialValue
                DropdownButtonFormField<String>(
                  initialValue: controller.accountType.value, 
                  items: ['Personal', 'Company'].map((type) => 
                    DropdownMenuItem(value: type, child: Text(type))).toList(),
                  onChanged: (val) => controller.accountType.value = val ?? 'Personal',
                  decoration: const InputDecoration(labelText: "Account Type"),
                ),

                _buildTextField(controller.liveCountController, "Live Times", isNumber: true),
                _buildTextField(controller.leadsController, "Leads", isNumber: true),
                _buildTextField(controller.viewersController, "Total Viewers", isNumber: true),
                _buildTextField(controller.topViewController, "Top View", isNumber: true),
                _buildTextField(controller.avgViewController, "Average View", isNumber: true),
                
                SwitchListTile(
                  title: const Text("Boosted?"),
                  value: controller.isBoosted.value,
                  onChanged: (val) => controller.isBoosted.value = val,
                ),

                _buildTextField(controller.commentController, "Comment", maxLines: 3),

                const SizedBox(height: 20),
                const Text("Photos", style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 10),
                
                // 图片预览网格
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                  ),
                  itemCount: controller.selectedImages.length + 1,
                  itemBuilder: (context, index) {
                    if (index == controller.selectedImages.length) {
                      return InkWell(
                        onTap: () => controller.pickImages(),
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
                            controller.selectedImages[index], 
                            fit: BoxFit.cover, 
                            width: double.infinity, 
                            height: double.infinity
                          ),
                        ),
                        Positioned(
                          right: 0,
                          top: 0,
                          child: GestureDetector(
                            onTap: () => controller.selectedImages.removeAt(index),
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
                  child: ElevatedButton(
                    onPressed: () => controller.submitTask(),
                    child: const Text("Submit Daily Update"),
                  ),
                )
              ],
            ),
          )),
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