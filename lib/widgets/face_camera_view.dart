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
  // 1: Nod Head Up or Down (Liveness Check)
  // 2: Verifying Captured Image
  int _step = 0; 
  
  XFile? _tempCapturedImage; 
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
        enableClassification: false, 
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
          // 🟢 读取面部的偏航角(Yaw 左右) 和 俯仰角(Pitch 上下)
          final double? yaw = face.headEulerAngleY; 
          final double? pitch = face.headEulerAngleX; 
          
          if (yaw == null || pitch == null) return;

          if (_step == 0 && !_hasCaptured) {
            // 阶段 0：要求用户必须是正脸（不偏头也不低头/抬头），确保抓拍质量
            if (yaw > -10 && yaw < 10 && pitch > -10 && pitch < 10) { 
               await _captureFrontFace();
            } else {
               _updateUI(status: "Look straight at the camera", color: Colors.yellowAccent, step: 0);
            }
          } else if (_step == 1 && _hasCaptured) {
            // 阶段 1：照片已拍好，要求用户向上或向下点头进行活体检测
            _updateUI(
              status: "Please nod up or down\nSila angguk ke atas atau bawah", 
              color: Colors.greenAccent, 
              step: 1
            );

            // 🟢 只要检测到向上仰头 (>15度) 或向下低头 (< -15度) 任意一个动作，即判定为活人！
            if (pitch > 15 || pitch < -15) {
              _startVerificationProcess(); 
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

  // 🟢 静默抓拍照片，拍完恢复视频流
  Future<void> _captureFrontFace() async {
    if (_hasCaptured) return;
    
    try {
      await _controller!.stopImageStream();
      _tempCapturedImage = await _controller!.takePicture();
      _hasCaptured = true;
      _step = 1; 

      await _controller!.startImageStream(_processImage);

    } catch (e) {
      debugPrint("Silent capture error: $e");
      _resetCamera();
    }
  }

  // 🟢 活体通过后，验证刚才暂存的照片
  Future<void> _startVerificationProcess() async {
    if (_isVerifying || _tempCapturedImage == null) return;
    
    setState(() {
      _isVerifying = true;
      _step = 2; 
      _statusText = 'camera.verifying'.tr();
      _statusColor = Colors.blue;
    });

    try {
      await _controller!.stopImageStream(); 

      if (widget.referencePath == null) {
        if (mounted) Navigator.pop(context, _tempCapturedImage);
        return;
      }

      VerifyResult result = await _faceService.compareFacesDetailed(widget.referencePath!, _tempCapturedImage!);

      if (!mounted) return;

      if (result.verified) {
        Navigator.pop(context, _tempCapturedImage); 
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
      _tempCapturedImage = null; 
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
                // 🟢 UI图标改为上下箭头，提示点头/抬头
                if (_step == 1)
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