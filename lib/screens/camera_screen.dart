import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart'; // 🟢 新增引入
import 'camera_controller.dart'; 

class CameraScreen extends ConsumerStatefulWidget {
  const CameraScreen({super.key});

  @override
  ConsumerState<CameraScreen> createState() => _CameraScreenState();
}

// 🟢 新增 with WidgetsBindingObserver 用于监听 App 切后台和恢复
class _CameraScreenState extends ConsumerState<CameraScreen> with WidgetsBindingObserver {
  CameraController? _cameraController;
  late Future<void> _initializeControllerFuture;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); // 🟢 注册生命周期监听
    _initializeControllerFuture = _initHardwareCamera();
  }

  // 🟢 监听 App 生命周期，防止切后台回来后相机卡死
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final CameraController? cameraController = _cameraController;

    // 如果相机还没初始化好，直接忽略
    if (cameraController == null || !cameraController.value.isInitialized) {
      return;
    }

    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      // App 失去焦点（如切后台、弹系统权限窗）时，释放相机
      cameraController.dispose();
    } else if (state == AppLifecycleState.resumed) {
      // App 恢复焦点时，重新初始化相机
      _initializeControllerFuture = _initHardwareCamera();
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this); // 🟢 移除监听
    _cameraController?.dispose();
    super.dispose();
  }

  Future<void> _initHardwareCamera() async {
    try {
      // 💡 核心修复1：在触碰相机硬件前，先手动要求权限并等待结果
      var status = await Permission.camera.request();
      if (!status.isGranted) {
        throw Exception("Camera permission is denied. Please enable it in settings.");
      }

      final cameras = await availableCameras();
      
      if (cameras.isEmpty) {
        throw Exception("No cameras found on this device.");
      }

      final backCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back, 
        orElse: () => cameras.first
      );
      
      _cameraController = CameraController(
        backCamera, 
        ResolutionPreset.high, 
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg, 
      );
      
      await _cameraController!.initialize();
    } catch (e) {
      debugPrint("Camera Init Error: $e");
      rethrow; 
    }
  }

  TextStyle _getOutlinedTextStyle({required double fontSize, FontWeight fontWeight = FontWeight.bold, Color color = Colors.white}) {
    return TextStyle(
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color,
      shadows: const [
        Shadow(offset: Offset(-1, -1), color: Colors.black),
        Shadow(offset: Offset(1, -1), color: Colors.black),
        Shadow(offset: Offset(1, 1), color: Colors.black),
        Shadow(offset: Offset(-1, 1), color: Colors.black),
        Shadow(blurRadius: 2, color: Colors.black),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(cameraScreenProvider);

    ref.listen<CameraScreenState>(cameraScreenProvider, (previous, next) {
      if (next.errorMessage != null && next.errorMessage != previous?.errorMessage) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error: ${next.errorMessage}"), backgroundColor: Colors.red)
        );
      }
      
      if (next.captureCount > (previous?.captureCount ?? 0)) {
        ScaffoldMessenger.of(context).clearSnackBars(); 
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("📸 Captured! Uploading in background..."), 
            backgroundColor: Colors.green,
            duration: Duration(milliseconds: 1500), 
            behavior: SnackBarBehavior.floating, 
          )
        );
      }
    });

    const double uniformFontSize = 15.0;
    const FontWeight uniformFontWeight = FontWeight.bold;

    return Scaffold(
      backgroundColor: Colors.black, // 确保整体背景为黑色
      body: FutureBuilder<void>(
        future: _initializeControllerFuture,
        builder: (context, snapshot) {
          
          if (snapshot.hasError) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error_outline, color: Colors.red, size: 60),
                  const SizedBox(height: 16),
                  Text("Camera Error:\n${snapshot.error}", 
                    style: const TextStyle(color: Colors.white), 
                    textAlign: TextAlign.center
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text("Go Back"),
                  )
                ],
              ),
            );
          }

          if (snapshot.connectionState == ConnectionState.done && 
              _cameraController != null && 
              _cameraController!.value.isInitialized) {
                
            return Column(
              children: [
                // 🟢 上半部分：相机预览区与水印
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // 1. 相机画面
                      ClipRect(
                        child: Container(
                          color: Colors.black,
                          child: Center(
                            child: CameraPreview(_cameraController!),
                          ),
                        ),
                      ),
                      
                      // 2. 右上角关闭按钮
                      Positioned(
                        top: 50, right: 20, 
                        child: GestureDetector(
                          onTap: () => Navigator.pop(context), 
                          child: Container(
                            padding: const EdgeInsets.all(8), 
                            decoration: BoxDecoration(color: Colors.black.withValues(alpha:0.4), shape: BoxShape.circle), 
                            child: const Icon(Icons.close, color: Colors.white, size: 24)
                          )
                        )
                      ),

                      // 3. 水印文字（紧贴底部边界，即紧贴下方的黑色控制区）
                      Positioned(
                        bottom: 20, // 距离相机预览区底部的间距
                        right: 15, 
                        left: 15, 
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end, 
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(state.dateTimeStr, style: _getOutlinedTextStyle(fontSize: uniformFontSize, fontWeight: uniformFontWeight), textAlign: TextAlign.right),
                            const SizedBox(height: 4),
                            Text(state.address, style: _getOutlinedTextStyle(fontSize: uniformFontSize, fontWeight: uniformFontWeight), textAlign: TextAlign.right, maxLines: 4),
                            const SizedBox(height: 4),
                            Text("Staff: ${state.staffName}", style: _getOutlinedTextStyle(fontSize: uniformFontSize, fontWeight: uniformFontWeight, color: Colors.white), textAlign: TextAlign.right),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                
                // 🟢 下半部分：黑色控制区域（快门按钮）
                Container(
                  width: double.infinity,
                  height: 140, // 黑色区域的固定高度
                  color: Colors.black,
                  child: Align(
                    // 💡 将 alignment 从 Center 改为 Align
                    // y 轴范围从 -1.0 (顶部) 到 1.0 (底部)。
                    // 设置为 -0.3 会让按钮从中心点稍微向上移动。
                    alignment: const Alignment(0, -0.3), 
                    child: GestureDetector(
                      onTap: () {
                        if (state.isReady) {
                          ref.read(cameraScreenProvider.notifier).captureAndUpload(_cameraController!);
                        }
                      },
                      child: Container(
                        height: 80, width: 80,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle, 
                          border: Border.all(color: state.isReady ? Colors.white : Colors.grey.withValues(alpha:0.5), width: 5),
                          boxShadow: [BoxShadow(color: Colors.white.withValues(alpha:0.1), blurRadius: 10)]
                        ),
                        child: Center(
                          child: Container(
                            height: 64, width: 64,
                            decoration: BoxDecoration(color: state.isReady ? Colors.white : Colors.transparent, shape: BoxShape.circle),
                            child: state.isProcessing 
                              ? const CircularProgressIndicator(color: Colors.black)
                              : Center(child: state.isReady ? null : const Icon(Icons.hourglass_empty, color: Colors.grey, size: 30)), 
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          }
          
          return const Center(child: CircularProgressIndicator(color: Colors.white));
        },
      ),
    );
  }
  }