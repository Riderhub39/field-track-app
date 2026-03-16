import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart'; 
import 'camera_controller.dart'; 

class CameraScreen extends ConsumerStatefulWidget {
  final String clientName;

  const CameraScreen({
    super.key, 
    required this.clientName,
  });

  @override
  ConsumerState<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends ConsumerState<CameraScreen> with WidgetsBindingObserver {
  CameraController? _cameraController;
  late Future<void> _initializeControllerFuture;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); 
    _initializeControllerFuture = _initHardwareCamera();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final CameraController? cameraController = _cameraController;
    if (cameraController == null || !cameraController.value.isInitialized) return;
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      cameraController.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initializeControllerFuture = _initHardwareCamera();
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this); 
    _cameraController?.dispose();
    super.dispose();
  }

  Future<void> _initHardwareCamera() async {
    try {
      var status = await Permission.camera.request();
      if (!status.isGranted) throw Exception("Camera permission is denied. Please enable it in settings.");
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw Exception("No cameras found on this device.");

      final backCamera = cameras.firstWhere((c) => c.lensDirection == CameraLensDirection.back, orElse: () => cameras.first);
      _cameraController = CameraController(backCamera, ResolutionPreset.high, enableAudio: false, imageFormatGroup: ImageFormatGroup.jpeg);
      await _cameraController!.initialize();
    } catch (e) {
      rethrow; 
    }
  }

  TextStyle _getOutlinedTextStyle({required double fontSize, FontWeight fontWeight = FontWeight.bold, Color color = Colors.white}) {
    return TextStyle(
      fontSize: fontSize, fontWeight: fontWeight, color: color,
      shadows: const [
        Shadow(offset: Offset(-1, -1), color: Colors.black), Shadow(offset: Offset(1, -1), color: Colors.black),
        Shadow(offset: Offset(1, 1), color: Colors.black), Shadow(offset: Offset(-1, 1), color: Colors.black),
        Shadow(blurRadius: 2, color: Colors.black),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(cameraScreenProvider);

    ref.listen<CameraScreenState>(cameraScreenProvider, (previous, next) {
      // 🟢 移除了 "📸 Added to preview list" 弹窗提示，仅保留错误提示
      if (next.errorMessage != null && next.errorMessage != previous?.errorMessage) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: ${next.errorMessage}"), backgroundColor: Colors.red));
      }
    });

    const double uniformFontSize = 14.0;
    const FontWeight uniformFontWeight = FontWeight.bold;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        Navigator.pop(context, state.capturedImages);
      },
      child: Scaffold(
        backgroundColor: Colors.black, 
        body: FutureBuilder<void>(
          future: _initializeControllerFuture,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(child: Text("Camera Error:\n${snapshot.error}", style: const TextStyle(color: Colors.white), textAlign: TextAlign.center));
            }

            if (snapshot.connectionState == ConnectionState.done && _cameraController != null && _cameraController!.value.isInitialized) {
              return Column(
                children: [
                  Expanded(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ClipRect(child: Container(color: Colors.black, child: Center(child: CameraPreview(_cameraController!)))),
                        
                        Positioned(
                          top: 50, right: 20, 
                          child: GestureDetector(
                            onTap: () => Navigator.pop(context, state.capturedImages),
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10), 
                                  decoration: BoxDecoration(color: Colors.green.shade600, borderRadius: BorderRadius.circular(20)), 
                                  child: const Text("Done", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16))
                                ),
                                if (state.capturedImages.isNotEmpty)
                                  Positioned(
                                    top: -5, right: -5,
                                    child: Container(
                                      padding: const EdgeInsets.all(6),
                                      decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
                                      child: Text('${state.capturedImages.length}', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                                    ),
                                  )
                              ],
                            )
                          )
                        ),

                        Positioned(
                          bottom: 20, right: 15, left: 15, 
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(state.dateTimeStr, style: _getOutlinedTextStyle(fontSize: uniformFontSize, fontWeight: uniformFontWeight), textAlign: TextAlign.right),
                              const SizedBox(height: 2),
                              if (widget.clientName.isNotEmpty) ...[
                                Text("Client: ${widget.clientName}", style: _getOutlinedTextStyle(fontSize: uniformFontSize, fontWeight: uniformFontWeight, color: Colors.amber), textAlign: TextAlign.right),
                                const SizedBox(height: 2),
                              ],
                              Text(state.address, style: _getOutlinedTextStyle(fontSize: uniformFontSize, fontWeight: uniformFontWeight), textAlign: TextAlign.right, maxLines: 4),
                              const SizedBox(height: 2),
                              Text("Staff: ${state.staffName}", style: _getOutlinedTextStyle(fontSize: uniformFontSize, fontWeight: uniformFontWeight, color: Colors.white), textAlign: TextAlign.right),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  
                  Container(
                    width: double.infinity, height: 140, color: Colors.black,
                    child: Align(
                      alignment: const Alignment(0, -0.3), 
                      child: GestureDetector(
                        onTap: () {
                          if (state.isReady) {
                            ref.read(cameraScreenProvider.notifier).capturePhoto(_cameraController!, widget.clientName);
                          }
                        },
                        child: Container(
                          height: 80, width: 80,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle, 
                            border: Border.all(color: state.isReady ? Colors.white : Colors.grey.withValues(alpha:0.5), width: 5),
                          ),
                          child: Center(
                            child: Container(
                              height: 64, width: 64,
                              decoration: BoxDecoration(color: state.isReady ? Colors.white : Colors.transparent, shape: BoxShape.circle),
                              child: state.isProcessing ? const CircularProgressIndicator(color: Colors.black) : null, 
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
      ),
    );
  }
}