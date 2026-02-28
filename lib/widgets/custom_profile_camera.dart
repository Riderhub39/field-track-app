import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:easy_localization/easy_localization.dart'; 
import 'dart:io';

// 引入刚刚创建的 controller
import 'custom_profile_camera_controller.dart';

class CustomProfileCamera extends ConsumerStatefulWidget {
  final String? referencePath; 

  const CustomProfileCamera({super.key, this.referencePath});

  @override
  ConsumerState<CustomProfileCamera> createState() => _CustomProfileCameraState();
}

class _CustomProfileCameraState extends ConsumerState<CustomProfileCamera> with WidgetsBindingObserver {
  CameraController? _controller;
  bool _isInitialized = false;

  // 🟢 用于记录相机的硬件/权限错误
  bool _hasCameraError = false;
  String _cameraErrorMessage = "";

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    
    // 初始化参考底图
    ref.read(profileCameraProvider.notifier).prepareReference(widget.referencePath);
    _initializeCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState appState) {
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (appState == AppLifecycleState.inactive) {
      _controller?.dispose();
    } else if (appState == AppLifecycleState.resumed) {
      _initializeCamera();
    }
  }

  // 🚀 核心修复：添加完整的 try-catch 防止相机初始化失败导致死锁
  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw Exception("No camera found on this device.");

      final frontCamera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      _controller = CameraController(
        frontCamera,
        ResolutionPreset.medium, 
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
      );

      await _controller!.initialize();
      if (!mounted) return;

      setState(() => _isInitialized = true);
      
      // 视频流丢给 Controller 处理
      await _controller!.startImageStream((image) {
        ref.read(profileCameraProvider.notifier).processImage(image, _controller!);
      });
    } catch (e) {
      debugPrint('Camera initialization error: $e');
      if (mounted) {
        setState(() {
          _hasCameraError = true;
          _cameraErrorMessage = e.toString();
        });
      }
    }
  }

  // --- Dialogs ---
  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Error'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context); // close dialog
              Navigator.pop(context); // exit camera
            }, 
            child: const Text('Exit')
          ),
        ],
      ),
    );
  }

  void _showCaptureDialog(XFile image) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text('camera.success'.tr()),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.file(File(image.path), height: 200, fit: BoxFit.cover),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              ref.read(profileCameraProvider.notifier).resetCameraState();
              if (_controller != null && !_controller!.value.isStreamingImages) {
                 await _controller!.startImageStream((image) => ref.read(profileCameraProvider.notifier).processImage(image, _controller!));
              }
            },
            child: const Text('Retake', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context); // close dialog
              Navigator.pop(context, image); // pop screen with result
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF15438c)),
            child: const Text('OK', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _showFailureDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Row(children: [Icon(Icons.warning_amber_rounded, color: Colors.red), SizedBox(width: 8), Text("Failed")]),
        content: Text('camera.failed'.tr()),
        actions: [
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              ref.read(profileCameraProvider.notifier).resetCameraState();
              if (_controller != null && !_controller!.value.isStreamingImages) {
                 await _controller!.startImageStream((image) => ref.read(profileCameraProvider.notifier).processImage(image, _controller!));
              }
            },
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 🟢 硬件权限异常拦截
    if (_hasCameraError) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Text(
              "Camera Error:\nPlease allow camera permission in app settings.\n\n$_cameraErrorMessage",
              style: const TextStyle(color: Colors.redAccent, fontSize: 16),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    if (!_isInitialized || _controller == null) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }

    final state = ref.watch(profileCameraProvider);

    // 🟢 监听状态改变以显示弹窗或导航
    ref.listen<ProfileCameraState>(profileCameraProvider, (previous, next) {
      if (next.errorMessage != null && next.errorMessage != previous?.errorMessage) {
        _showErrorDialog(next.errorMessage!);
      }
      if (next.showFailureDialog && !(previous?.showFailureDialog ?? false)) {
        _showFailureDialog();
      }
      if (next.successImage != null && previous?.successImage == null) {
        if (widget.referencePath == null) {
           // 注册模式：预览图片询问是否满意
          _showCaptureDialog(next.successImage!);
        } else {
           // 验证模式：直接带回结果
          Navigator.pop(context, next.successImage);
        }
      }
    });

    final size = MediaQuery.of(context).size;
    final double rectWidth = size.width * 0.75;
    final double rectHeight = size.width * 1.0; 

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(widget.referencePath == null ? 'camera.title_register'.tr() : 'camera.title_verify'.tr()),
        backgroundColor: const Color(0xFF15438c),
        foregroundColor: Colors.white,
      ),
      // 🚀 整体 UI 结构从 Column 改为纯 Stack，让按钮悬浮在预览画面上
      body: Stack(
        fit: StackFit.expand,
        children: [
          CameraPreview(_controller!),
          
          // 🟢 1. 绿色长方形框 (覆盖层)
          Center(
            child: Container(
              width: rectWidth,
              height: rectHeight,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.greenAccent, width: 3),
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          ),

          // 状态提示文字 (位于框上方)
          Positioned(
            top: size.height * 0.1, 
            left: 0, 
            right: 0,
            child: Text(
              state.statusText,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: state.statusColor, 
                fontSize: 20, 
                fontWeight: FontWeight.bold,
                shadows: const [Shadow(color: Colors.black, blurRadius: 4)]
              ),
            ),
          ),

          // 🔵 2. 悬浮的底部手动拍照区域 (Positioned bottom: 60)
          Positioned(
            bottom: 60, // 👈 调整这个值可以控制按钮的上下高度
            left: 0,
            right: 0,
            child: Center(
              child: GestureDetector(
                onTap: state.faceDetected ? () {
                   ref.read(profileCameraProvider.notifier).manualCapture(_controller!, widget.referencePath);
                } : null, 
                child: Container(
                  height: 80,
                  width: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 4),
                    color: state.faceDetected ? Colors.white : Colors.grey.withValues(alpha: 0.8), // 半透明灰色
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.3),
                        blurRadius: 10,
                      )
                    ]
                  ),
                  child: state.faceDetected 
                    ? const Icon(Icons.camera_alt, color: Colors.black, size: 40)
                    : const Icon(Icons.face_retouching_off, color: Colors.black54, size: 40),
                ),
              ),
            ),
          ),

          // Processing Overlay (最顶层遮罩)
          if (state.isTakingPicture)
            Container(
              color: Colors.black54,
              child: const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
            ),
        ],
      ),
    );
  }
} 