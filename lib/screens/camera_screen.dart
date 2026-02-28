import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'camera_controller.dart'; 

class CameraScreen extends ConsumerStatefulWidget {
  const CameraScreen({super.key});

  @override
  ConsumerState<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends ConsumerState<CameraScreen> {
  CameraController? _cameraController;
  Future<void>? _initializeControllerFuture;

  @override
  void initState() {
    super.initState();
    _initHardwareCamera();
  }

  Future<void> _initHardwareCamera() async {
    final cameras = await availableCameras();
    final backCamera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back, 
      orElse: () => cameras.first
    );
    _cameraController = CameraController(backCamera, ResolutionPreset.high, enableAudio: false);
    _initializeControllerFuture = _cameraController!.initialize();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    super.dispose();
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

    // 🟢 监听连续拍照成功的事件
    ref.listen<CameraScreenState>(cameraScreenProvider, (previous, next) {
      // 错误拦截
      if (next.errorMessage != null && next.errorMessage != previous?.errorMessage) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error: ${next.errorMessage}"), backgroundColor: Colors.red)
        );
      }
      
      // 🚀 当连拍计数器增加时，提示用户且不再执行 pop，允许继续点击
      if (next.captureCount > (previous?.captureCount ?? 0)) {
        ScaffoldMessenger.of(context).clearSnackBars(); // 清除旧提示，避免堆积
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("📸 Captured! Uploading in background..."), 
            backgroundColor: Colors.green,
            duration: Duration(milliseconds: 1500), // 改短显示时间，避免阻挡屏幕
            behavior: SnackBarBehavior.floating, // 悬浮样式
          )
        );
      }
    });

    const double uniformFontSize = 15.0;
    const FontWeight uniformFontWeight = FontWeight.bold;

    return Scaffold(
      backgroundColor: Colors.black,
      body: FutureBuilder<void>(
        future: _initializeControllerFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done && _cameraController != null) {
            return Stack(
              children: [
                SizedBox.expand(child: CameraPreview(_cameraController!)),
                
                // 🟢 UI 预览水印上移
                Positioned(
                  bottom: 160, right: 15, left: 15, 
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
                
                // 🟢 拍照按钮整体上移
                Positioned(
                  bottom: 60, left: 0, right: 0,
                  child: Center(
                    child: GestureDetector(
                      onTap: () {
                        // 防暴击：只有处于 Ready 状态时才能点
                        if (state.isReady) {
                          ref.read(cameraScreenProvider.notifier).captureAndUpload(_cameraController!);
                        }
                      },
                      child: Container(
                        height: 80, width: 80,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle, 
                          border: Border.all(color: state.isReady ? Colors.white : Colors.grey.withValues(alpha:0.5), width: 5),
                          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha:0.3), blurRadius: 10)]
                        ),
                        child: Center(
                          child: Container(
                            height: 64, width: 64,
                            decoration: BoxDecoration(color: state.isReady ? Colors.white : Colors.transparent, shape: BoxShape.circle),
                            // 即使在处理中也只阻挡零点几秒，几乎感觉不到
                            child: state.isProcessing 
                              ? const CircularProgressIndicator(color: Colors.black)
                              : Center(child: state.isReady ? null : const Icon(Icons.hourglass_empty, color: Colors.grey, size: 30)), 
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

                // 由于不自动退出了，给用户一个明确的返回按钮
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
              ],
            );
          }
          return const Center(child: CircularProgressIndicator(color: Colors.white));
        },
      ),
    );
  }
}