import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:path_provider/path_provider.dart';
import '../services/face_recognition_service.dart';

class FaceCameraView extends StatefulWidget {
  final String? referencePath;

  const FaceCameraView({super.key, this.referencePath});

  @override
  State<FaceCameraView> createState() => _FaceCameraViewState();
}

class _FaceCameraViewState extends State<FaceCameraView> with WidgetsBindingObserver {
  CameraController? _controller;
  bool _isInitialized = false;

  // --- UI Status ---
  String _statusText = "";
  Color _statusColor = Colors.white;
  bool _isLoadingReference = true;
  
  // --- Flow Control ---
  // 0: Find Center Face -> Capture
  // 1: Turn Head Left or Right (Liveness Check)
  // 2: Verifying Captured Image
  int _step = 0; 
  
  XFile? _tempCapturedImage; // 暂存刚开始拍下的正脸照片
  bool _hasCaptured = false; 
  bool _isVerifying = false; 

  // --- Logic ---
  late final FaceDetector _faceDetector;
  bool _isProcessing = false;
  final FaceRecognitionService _faceService = FaceRecognitionService();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _statusText = 'camera.align'.tr(); 

    // 1. Initialize Face Detector
    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        performanceMode: FaceDetectorMode.accurate, 
        enableLandmarks: true,
        enableClassification: false, // 不再需要闭眼检测
        enableContours: false,
        minFaceSize: 0.15, 
      ),
    );

    // 2. Parallel Init: Download Ref & Start Camera
    _downloadAndInitializeReference();
    _initializeCamera();
  }

  Future<void> _downloadAndInitializeReference() async {
    await _faceService.initialize();
    
    if (widget.referencePath == null) {
      if (mounted) setState(() => _isLoadingReference = false);
      return;
    }

    String path = widget.referencePath!;

    if (path.startsWith('http') || path.startsWith('https')) {
      try {
        if (mounted) setState(() => _statusText = "Loading Profile...");
        
        final request = await HttpClient().getUrl(Uri.parse(path));
        final response = await request.close();
        
        if (response.statusCode == 200) {
          final bytes = await consolidateHttpClientResponseBytes(response);
          final dir = await getTemporaryDirectory();
          final file = File('${dir.path}/temp_ref_face.jpg');
          await file.writeAsBytes(bytes);
          
          await _faceService.preloadReference(file.path);
        }
      } catch (e) {
        debugPrint("Ref download error: $e");
      }
    } else {
      await _faceService.preloadReference(path);
    }

    if (mounted) {
      setState(() {
        _isLoadingReference = false;
        _statusText = 'camera.align'.tr();
      });
    }
  }

  Future<void> _initializeCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) return;

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
    _controller!.startImageStream(_processImage);
  }

  // --- Real-time Processing ---
  Future<void> _processImage(CameraImage image) async {
    if (_isLoadingReference || _isProcessing || _isVerifying || !mounted) return;
    _isProcessing = true;

    try {
      final inputImage = _convertCameraImage(image);
      if (inputImage == null) return;

      final faces = await _faceDetector.processImage(inputImage);

      if (faces.isEmpty) {
        if (_step != 0 && mounted && !_hasCaptured) {
          _updateUI(status: 'camera.no_face'.tr(), color: Colors.red, step: 0);
        }
      } else {
        final face = faces.first;
        
        bool isCentered = _isFaceCentered(face, image.width, image.height);
        
        if (!isCentered) {
          if (!_hasCaptured) {
            _updateUI(status: 'camera.center_face'.tr(), color: Colors.orange, step: 0);
          }
        } else {
          // 🟢 核心重构流程：0.找正脸拍照 -> 1.活体摇头 -> 2.验证
          final double? yaw = face.headEulerAngleY; 
          if (yaw == null) return;

          if (_step == 0 && !_hasCaptured) {
            // 阶段 0：要求用户正对镜头，准备抓拍
            if (yaw > -10 && yaw < 10) { 
               // 角度非常正，立刻抓拍暂存
               await _captureFrontFace();
            } else {
               _updateUI(status: "Look straight at the camera", color: Colors.yellowAccent, step: 0);
            }
          } else if (_step == 1 && _hasCaptured) {
            // 阶段 1：照片已拍好，现在要求摇头进行活体检测
            _updateUI(
              status: "Please turn your head left or right\nSila toleh ke kiri atau kanan", 
              color: Colors.greenAccent, 
              step: 1
            );

            // 如果摇头角度超过 20 度（不论左右），认为活体检测通过！
            if (yaw > 20 || yaw < -20) {
              _startVerificationProcess(); // 触发最终的比对流程
            }
          }
        }
      }
    } catch (e) {
      debugPrint("Process error: $e");
    } finally {
      _isProcessing = false;
    }
  }

  bool _isFaceCentered(Face face, int imgWidth, int imgHeight) {
    double centerX = face.boundingBox.center.dx;
    double centerY = face.boundingBox.center.dy;
    
    bool xOk = centerX > imgWidth * 0.1 && centerX < imgWidth * 0.9;
    bool yOk = centerY > imgHeight * 0.1 && centerY < imgHeight * 0.9;
    
    return xOk && yOk; 
  }

  // 🟢 第一步：仅仅是静默抓拍照片，不中断视频流，不立刻比对
  Future<void> _captureFrontFace() async {
    if (_hasCaptured) return;
    
    try {
      // 在有些设备上，takePicture 不能与 startImageStream 同时运行
      await _controller!.stopImageStream();
      _tempCapturedImage = await _controller!.takePicture();
      _hasCaptured = true;
      _step = 1; // 拍照完成，进入活体检测阶段

      // 拍完照立刻恢复视频流，让用户可以进行摇头动作
      await _controller!.startImageStream(_processImage);

    } catch (e) {
      debugPrint("Silent capture error: $e");
      _resetCamera();
    }
  }

  // 🟢 第二步：活体检测通过后，拿刚才拍好的照片去比对
  Future<void> _startVerificationProcess() async {
    if (_isVerifying || _tempCapturedImage == null) return;
    
    setState(() {
      _isVerifying = true;
      _step = 2; // 进入最终验证阶段
      _statusText = 'camera.verifying'.tr();
      _statusColor = Colors.blue;
    });

    try {
      await _controller!.stopImageStream(); // 停止摄像头

      if (widget.referencePath == null) {
        if (mounted) Navigator.pop(context, _tempCapturedImage);
        return;
      }

      // 验证刚才抓拍的正脸图片
      VerifyResult result = await _faceService.compareFacesDetailed(widget.referencePath!, _tempCapturedImage!);

      if (!mounted) return;

      if (result.verified) {
        Navigator.pop(context, _tempCapturedImage); // 验证成功，返回最开始拍的清晰正脸照
      } else {
        setState(() {
          _statusText = 'camera.failed'.tr();
          _statusColor = Colors.red;
        });
        await _showRetryDialog();
      }

    } catch (e) {
      debugPrint("Verification error: $e");
      _resetCamera();
    }
  }

  Future<void> _showRetryDialog() async {
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text('camera.failed'.tr()),
        content: const Text("Face mismatch. Please try again in better lighting."),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _resetCamera();
            },
            child: const Text('Retry'),
          )
        ],
      ),
    );
  }

  void _resetCamera() async {
    if (!mounted) return;
    setState(() {
      _hasCaptured = false;
      _isVerifying = false;
      _step = 0;
      _tempCapturedImage = null; // 清空暂存的图片
      _statusText = 'camera.align'.tr();
      _statusColor = Colors.white;
    });
    
    if (_controller != null) {
      await _controller!.startImageStream(_processImage);
    }
  }

  void _updateUI({required String status, required Color color, required int step}) {
    if (_statusText != status || _statusColor != color || _step != step) {
      if (mounted) {
        setState(() {
          _statusText = status;
          _statusColor = color;
          _step = step;
        });
      }
    }
  }

  InputImage? _convertCameraImage(CameraImage image) {
    if (_controller == null) return null;
    try {
      final camera = _controller!.description;
      final sensorOrientation = camera.sensorOrientation;
      
      InputImageRotation rotation = InputImageRotation.rotation0deg;
      if (Platform.isAndroid) {
        rotation = InputImageRotationValue.fromRawValue(sensorOrientation) ?? InputImageRotation.rotation270deg;
      } else if (Platform.isIOS) {
        rotation = InputImageRotationValue.fromRawValue(sensorOrientation) ?? InputImageRotation.rotation0deg;
      }

      final format = InputImageFormatValue.fromRawValue(image.format.raw) ?? InputImageFormat.nv21;
      
      final WriteBuffer allBytes = WriteBuffer();
      for (final Plane plane in image.planes) {
        allBytes.putUint8List(plane.bytes);
      }
      final bytes = allBytes.done().buffer.asUint8List();

      return InputImage.fromBytes(
        bytes: bytes,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: rotation,
          format: format,
          bytesPerRow: image.planes[0].bytesPerRow,
        ),
      );
    } catch (e) {
      return null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _faceDetector.close();
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
  Widget build(BuildContext context) {
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
                  // 白 (准备) -> 绿 (已抓拍，准备摇头) -> 蓝 (正在处理)
                  color: _step == 0 ? Colors.white : (_step == 1 ? Colors.greenAccent : Colors.blueAccent), 
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
                // 提示图标的变化
                if (_step == 1)
                  const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.keyboard_double_arrow_left, color: Colors.greenAccent, size: 40),
                      Icon(Icons.face, color: Colors.greenAccent, size: 40),
                      Icon(Icons.keyboard_double_arrow_right, color: Colors.greenAccent, size: 40),
                    ],
                  ),
                const SizedBox(height: 10),
                Text(
                  _statusText,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _statusColor, 
                    fontSize: 22, 
                    fontWeight: FontWeight.bold,
                    shadows: const [Shadow(color: Colors.black, blurRadius: 4)]
                  ),
                ),
              ],
            ),
          ),

          if (_isVerifying || _isLoadingReference)
            Container(
              color: Colors.black54,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(color: Colors.white),
                    const SizedBox(height: 20),
                    Text(_statusText, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            )
        ],
      ),
    );
  }
}