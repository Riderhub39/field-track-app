import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:easy_localization/easy_localization.dart';

// 🟢 引入控制器
import 'profile_controller.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  final TextEditingController _requestController = TextEditingController();

  @override
  void dispose() {
    _requestController.dispose();
    super.dispose();
  }

  void _showEditRequestDialog() {
    showDialog(
      context: context,
      barrierDismissible: false, 
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        title: Text(
          "profile.dialog_title".tr(),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "profile.dialog_subtitle".tr(),
              style: const TextStyle(fontSize: 13, color: Colors.grey),
            ),
            const SizedBox(height: 15),
            TextField(
              controller: _requestController,
              maxLines: 3,
              decoration: InputDecoration(
                hintText: "profile.reason_hint".tr(),
                hintStyle: TextStyle(color: Colors.grey[400], fontSize: 13),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Colors.blue, width: 2),
                ),
                filled: true,
                fillColor: Colors.grey[50],
              ),
            ),
          ],
        ),
        actionsPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        actionsAlignment: MainAxisAlignment.end,
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _requestController.clear();
            },
            style: TextButton.styleFrom(
              foregroundColor: Colors.grey[700],
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            ),
            child: Text(
              "profile.btn_cancel".tr(),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          
          const SizedBox(width: 8), 

          ElevatedButton.icon(
            onPressed: () {
              if (_requestController.text.trim().isEmpty) return;
              String reason = _requestController.text.trim();
              Navigator.pop(context);
              _requestController.clear();
              ref.read(profileProvider.notifier).submitEditRequest(reason);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue[700], 
              foregroundColor: Colors.white,
              elevation: 2,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            ),
            icon: const Icon(Icons.send, size: 16),
            label: Text("profile.btn_send".tr()),
          ),
        ],
      ),
    );
  }

  // --- 动态构建字段组件 ---
  Widget _buildField(ProfileState state, String labelKey, List<String> path, {bool locked = false}) {
    String value = ref.read(profileProvider.notifier).getValue(path);
    String fieldKey = path.join('.');
    String translatedLabel = labelKey.tr();

    // 只读模式 (未授权编辑 或 字段被强制锁定)
    if (!state.isEditable || locked) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(translatedLabel,
                style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[600],
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              decoration: BoxDecoration(
                color: locked ? Colors.grey[200] : Colors.grey[50], 
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      value,
                      style: TextStyle(
                        fontSize: 15, 
                        color: locked ? Colors.grey[600] : Colors.black87
                      ),
                    ),
                  ),
                  if (locked && state.isEditable)
                     const Icon(Icons.lock, size: 16, color: Colors.grey),
                ],
              ),
            ),
          ],
        ),
      );
    }

    // 编辑模式
    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0),
      child: TextFormField(
        controller: ref.read(profileProvider.notifier).getController(fieldKey, value),
        decoration: InputDecoration(
          labelText: translatedLabel,
          labelStyle: TextStyle(color: Colors.grey[600]),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
          filled: true,
          fillColor: Colors.white,
        ),
      ),
    );
  }

  Widget _buildGroupCard(String titleKey, List<Widget> children) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(titleKey.tr().toUpperCase(),
                style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.blue,
                    fontSize: 13,
                    letterSpacing: 0.5)),
            const Divider(height: 24),
            ...children,
          ],
        ),
      ),
    );
  }

  // --- 各标签页内容 ---

  Widget _buildPersonalTab(ProfileState state) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          _buildGroupCard("profile.group_bio", [
            _buildField(state, "profile.field_name", ['personal', 'name']),
            _buildField(state, "profile.field_nationality", ['personal', 'nationality']),
            _buildField(state, "profile.field_religion", ['personal', 'religion']),
            _buildField(state, "profile.field_race", ['personal', 'race']),
            _buildField(state, "profile.field_gender", ['personal', 'gender']),
            _buildField(state, "profile.field_marital", ['personal', 'marital']),
            _buildField(state, "profile.field_blood", ['personal', 'blood']),
          ]),
          _buildGroupCard("profile.group_docs", [
            _buildField(state, "profile.field_ic", ['personal', 'icNo'], locked: true),
            _buildField(state, "profile.field_passport", ['foreign', 'id'], locked: true),
          ]),
          _buildGroupCard("profile.group_tax", [
            _buildField(state, "profile.field_tax_disable", ['statutory', 'tax', 'disable']),
            _buildField(state, "profile.field_tax_spouse", ['statutory', 'tax', 'spouseStatus']),
            _buildField(state, "profile.field_tax_spouse_disable", ['statutory', 'tax', 'spouseDisable']),
          ]),
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  Widget _buildAddressTab(ProfileState state) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          _buildGroupCard("profile.group_local_addr", [
            _buildField(state, "profile.field_addr_door", ['address', 'local', 'door']),
            _buildField(state, "profile.field_addr_loc", ['address', 'local', 'loc']),
            _buildField(state, "profile.field_addr_street", ['address', 'local', 'street']),
            _buildField(state, "profile.field_addr_city", ['address', 'local', 'city']),
            _buildField(state, "profile.field_addr_pin", ['address', 'local', 'pin']),
            _buildField(state, "profile.field_addr_state", ['address', 'local', 'state']),
            _buildField(state, "profile.field_addr_country", ['address', 'local', 'country']),
          ]),
          _buildGroupCard("profile.group_foreign_addr", [
            _buildField(state, "profile.field_addr_door", ['address', 'foreign', 'door']),
            _buildField(state, "profile.field_addr_loc", ['address', 'foreign', 'loc']),
            _buildField(state, "profile.field_addr_street", ['address', 'foreign', 'street']),
            _buildField(state, "profile.field_addr_city", ['address', 'foreign', 'city']),
            _buildField(state, "profile.field_addr_pin", ['address', 'foreign', 'pin']),
            _buildField(state, "profile.field_addr_state", ['address', 'foreign', 'state']),
            _buildField(state, "profile.field_addr_country", ['address', 'foreign', 'country']),
          ]),
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  Widget _buildContactTab(ProfileState state) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // ⚠️ 安全锁定提示
          Container(
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: Colors.amber.shade50,
              border: Border.all(color: Colors.amber.shade300),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.lock_outline, color: Colors.amber[800], size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    "profile.contact_security_notice".tr(),
                    style: TextStyle(fontSize: 13, color: Colors.brown[800], height: 1.4),
                  ),
                ),
              ],
            ),
          ),

          _buildGroupCard("profile.group_contact", [
            _buildField(state, "profile.field_mobile", ['personal', 'mobile'], locked: true),
            _buildField(state, "profile.field_email", ['personal', 'email'], locked: true),
          ]),
          
          _buildGroupCard("profile.group_emergency", [
            _buildField(state, "profile.field_emergency_name", ['address', 'emergency', 'name']),
            _buildField(state, "profile.field_emergency_rel", ['address', 'emergency', 'rel']),
            _buildField(state, "profile.field_emergency_phone", ['address', 'emergency', 'no']),
          ]),
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  Widget _buildFamilyTab(ProfileState state) {
    List<dynamic> children = [];
    if (state.rawData['family'] != null && state.rawData['family']['children'] != null) {
      children = state.rawData['family']['children'];
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          _buildGroupCard("profile.group_spouse", [
            _buildField(state, "profile.field_spouse_name", ['family', 'spouse', 'name']),
            _buildField(state, "profile.field_dob", ['family', 'spouse', 'dob']),
            _buildField(state, "profile.field_job", ['family', 'spouse', 'job']),
            _buildField(state, "profile.field_spouse_id", ['family', 'spouse', 'id']),
            _buildField(state, "profile.field_phone", ['family', 'spouse', 'phone']),
          ]),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0),
            child: Text("${'profile.group_children'.tr()} (${children.length})",
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
          ),
          if (children.isEmpty)
            Center(
                child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text("profile.no_children".tr(),
                  style: const TextStyle(color: Colors.grey)),
            )),
          ...children.map((child) => Card(
                margin: const EdgeInsets.only(bottom: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  title: Text(child['name'] ?? 'Unknown',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 4),
                      Text("${'profile.field_dob'.tr()}: ${child['dob'] ?? '-'}"),
                      Text("${'profile.field_gender'.tr()}: ${child['gender'] ?? '-'}"),
                      Text("${'profile.field_child_ic'.tr()}: ${child['cert'] ?? '-'}"),
                    ],
                  ),
                ),
              )),
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  // --- 悬浮按钮构建 ---
  Widget? _buildFab(ProfileState state) {
    if (state.isEditable) {
      return FloatingActionButton.extended(
        onPressed: state.isLoading ? null : () => ref.read(profileProvider.notifier).saveProfile(),
        icon: const Icon(Icons.save),
        label: Text("profile.btn_save_changes".tr()),
        backgroundColor: Colors.green,
      );
    } 
    
    if (state.hasPendingRequest) {
      return FloatingActionButton.extended(
        onPressed: null, 
        icon: const Icon(Icons.hourglass_top), 
        label: Text("profile.status_pending".tr()), 
        backgroundColor: Colors.grey,
      );
    }

    return FloatingActionButton.extended(
      onPressed: _showEditRequestDialog,
      icon: const Icon(Icons.edit_note),
      label: Text("profile.btn_request_update".tr()),
      backgroundColor: Colors.blue[800],
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(profileProvider);

    // 🟢 监听 Controller 的消息弹窗事件
    ref.listen<ProfileState>(profileProvider, (previous, next) {
      if (next.errorMessage != null && next.errorMessage != previous?.errorMessage) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(next.errorMessage!.tr()), backgroundColor: Colors.red));
        ref.read(profileProvider.notifier).clearMessages();
      }

      if (next.successMessage != null && next.successMessage != previous?.successMessage) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(next.successMessage!.tr()), backgroundColor: Colors.green));
        ref.read(profileProvider.notifier).clearMessages();
      }
    });

    if (state.isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return DefaultTabController(
      length: 4,
      child: Scaffold(
        backgroundColor: Colors.grey[100],
        appBar: AppBar(
          title: Text("profile.title".tr()),
          elevation: 0,
          backgroundColor: Colors.blue[700],
          foregroundColor: Colors.white,
          bottom: TabBar(
            isScrollable: true,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white70,
            indicatorColor: Colors.white,
            indicatorWeight: 3,
            tabs: [
              Tab(text: "profile.tab_personal".tr()),
              Tab(text: "profile.tab_address".tr()),
              Tab(text: "profile.tab_contact".tr()),
              Tab(text: "profile.tab_family".tr()),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildPersonalTab(state),
            _buildAddressTab(state),
            _buildContactTab(state),
            _buildFamilyTab(state),
          ],
        ),
        floatingActionButton: _buildFab(state),
      ),
    );
  }
}