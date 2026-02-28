import 'dart:io'; 
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:easy_localization/easy_localization.dart';

import 'face_camera_controller.dart';

class FaceCameraView extends ConsumerStatefulWidget {
  final String? referencePath;

  const FaceCameraView({super.key, this.referencePath});

  @override
  ConsumerState<FaceCameraView> createState() => _FaceCameraViewState();
}

class _FaceCameraViewState extends ConsumerState<FaceCameraView> with WidgetsBindingObserver {
  CameraController? _controller;
  bool _isInitialized = false;

  bool _hasCameraError = false;
  String _cameraErrorMessage = "";

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    
    // 初始化参考底图与特征值
    ref.read(faceCameraProvider.notifier).prepareReference(widget.referencePath);
    _initializeCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
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

  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw Exception("No camera found on this device.");

      final frontCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      _controller = CameraController(
        frontCamera,
        ResolutionPreset.high, 
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
      );

      await _controller!.initialize();
      await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

      if (!mounted) return;
      
      setState(() => _isInitialized = true);
      
      _controller!.startImageStream((image) {
        ref.read(faceCameraProvider.notifier).processImage(image, _controller!);
      });
    } catch (e) {
      debugPrint('Camera Init Error: $e');
      if (mounted) {
        setState(() {
          _hasCameraError = true;
          _cameraErrorMessage = e.toString();
        });
      }
    }
  }

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
              Navigator.pop(context); 
              Navigator.pop(context); 
            }, 
            child: const Text('Exit')
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
        title: Text('camera.failed'.tr()),
        content: const Text("Face mismatch. Please try again in better lighting."),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context); 
              ref.read(faceCameraProvider.notifier).resetCameraState(_controller);
            },
            child: const Text('Retry'),
          )
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 🚀 核心修复：必须将 ref.watch 放在所有提前 return 的最上方！
    // 这样能保证 provider 在相机初始化期间不被销毁，保住正在下载图片的网络进程！
    final state = ref.watch(faceCameraProvider);

    ref.listen<FaceCameraState>(faceCameraProvider, (previous, next) {
      if (next.errorMessage != null && next.errorMessage != previous?.errorMessage) {
        _showErrorDialog(next.errorMessage!);
      }
      
      if (next.showFailureDialog && !(previous?.showFailureDialog ?? false)) {
        _showFailureDialog();
      }
      
      if (next.successImage != null && previous?.successImage == null) {
        Navigator.pop(context, next.successImage); 
      }
    });

    // 🟢 之后再执行 UI 的早期拦截
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

    final size = MediaQuery.of(context).size;
    final double rectWidth = size.width * 0.8;
    final double rectHeight = size.width * 1.1; 

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text('camera.title_verify'.tr()),
        backgroundColor: const Color(0xFF15438c),
        foregroundColor: Colors.white,
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          CameraPreview(_controller!),
          
          ColorFiltered(
            colorFilter: ColorFilter.mode(Colors.black.withValues(alpha:0.5), BlendMode.srcOut),
            child: Stack(
              children: [
                Container(
                  decoration: const BoxDecoration(
                    color: Colors.transparent,
                    backgroundBlendMode: BlendMode.dstOut,
                  ),
                ),
                Center(
                  child: Container(
                    width: rectWidth,
                    height: rectHeight,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20), 
                    ),
                  ),
                ),
              ],
            ),
          ),

          Center(
            child: Container(
              width: rectWidth,
              height: rectHeight,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: state.step == 0 ? Colors.white : (state.step == 1 ? Colors.greenAccent : Colors.blueAccent), 
                  width: 4
                ),
              ),
            ),
          ),

          Positioned(
            bottom: size.height * 0.15, 
            left: 20, right: 20,
            child: Column(
              children: [
                if (state.step == 1)
                  const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.keyboard_double_arrow_up, color: Colors.greenAccent, size: 40),
                      SizedBox(width: 8),
                      Icon(Icons.face, color: Colors.greenAccent, size: 40),
                      SizedBox(width: 8),
                      Icon(Icons.keyboard_double_arrow_down, color: Colors.greenAccent, size: 40),
                    ],
                  ),
                const SizedBox(height: 10),
                Text(
                  state.statusText,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: state.statusColor, 
                    fontSize: 22, 
                    fontWeight: FontWeight.bold,
                    shadows: const [Shadow(color: Colors.black, blurRadius: 4)]
                  ),
                ),
              ],
            ),
          ),

          if (state.isVerifying || state.isLoadingReference)
            Container(
              color: Colors.black54,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(color: Colors.white),
                    const SizedBox(height: 20),
                    Text(state.statusText, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            )
        ],
      ),
    );
  }
}