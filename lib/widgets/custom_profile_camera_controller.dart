import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:path_provider/path_provider.dart'; // 🟢 新增：用于网络图片下载
import '../services/face_recognition_service.dart';

// ==========================================
// 1. 状态定义 (State)
// ==========================================
class ProfileCameraState {
  final String statusText;
  final Color statusColor;
  final bool isTakingPicture;
  final bool faceDetected;
  final String? errorMessage;
  final XFile? successImage; 
  final bool showFailureDialog; 

  ProfileCameraState({
    this.statusText = "Initializing...",
    this.statusColor = Colors.white,
    this.isTakingPicture = false,
    this.faceDetected = false,
    this.errorMessage,
    this.successImage,
    this.showFailureDialog = false,
  });

  ProfileCameraState copyWith({
    String? statusText,
    Color? statusColor,
    bool? isTakingPicture,
    bool? faceDetected,
    String? errorMessage,
    XFile? successImage,
    bool? showFailureDialog,
    bool clearErrorMessage = false, // 🟢 新增：精确控制是否清空错误
  }) {
    return ProfileCameraState(
      statusText: statusText ?? this.statusText,
      statusColor: statusColor ?? this.statusColor,
      isTakingPicture: isTakingPicture ?? this.isTakingPicture,
      faceDetected: faceDetected ?? this.faceDetected,
      errorMessage: clearErrorMessage ? null : (errorMessage ?? this.errorMessage),
      successImage: successImage ?? this.successImage,
      showFailureDialog: showFailureDialog ?? this.showFailureDialog,
    );
  }
}

// ==========================================
// 2. 逻辑控制器 (Controller)
// ==========================================
class ProfileCameraController extends StateNotifier<ProfileCameraState> {
  late final FaceDetector _faceDetector;
  final FaceRecognitionService _faceService = FaceRecognitionService();
  
  // 🚀 性能优化：限制 ML Kit 处理频率
  DateTime _lastProcessTime = DateTime.now();
  bool _isProcessing = false;

  ProfileCameraController() : super(ProfileCameraState()) {
    _initDetector();
  }

  void _initDetector() {
    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        enableContours: false,
        enableClassification: true, 
        enableLandmarks: true,      
        performanceMode: FaceDetectorMode.fast, // 使用 fast 模式即可满足框选需求
        minFaceSize: 0.15, 
      ),
    );
    state = state.copyWith(statusText: 'camera.align'.tr());
  }

  // 🚀 核心修复：加入 Try-Catch-Finally 防止下载失败导致 UI 死锁
  Future<void> prepareReference(String? referencePath) async {
    _faceService.clearReference();
    
    try {
      if (referencePath != null) {
        if (referencePath.startsWith('http') || referencePath.startsWith('https')) {
          if (mounted) state = state.copyWith(statusText: "Loading Profile...");
          
          final request = await HttpClient().getUrl(Uri.parse(referencePath));
          final response = await request.close();
          
          if (response.statusCode == 200) {
            final bytes = await consolidateHttpClientResponseBytes(response);
            final dir = await getTemporaryDirectory();
            final file = File('${dir.path}/temp_ref_profile.jpg');
            await file.writeAsBytes(bytes);
            
            await _faceService.preloadReference(file.path);
          }
        } else {
          await _faceService.preloadReference(referencePath);
        }
      }
    } catch (e) {
      debugPrint("Reference Initialization Error: $e");
      if (mounted) state = state.copyWith(errorMessage: "Failed to load face data: $e");
    } finally {
      if (mounted) state = state.copyWith(statusText: 'camera.align'.tr());
    }
  }

  @override
  void dispose() {
    _faceDetector.close();
    super.dispose();
  }

  // --- 实时视频流处理 ---
  Future<void> processImage(CameraImage image, CameraController controller) async {
    if (state.isTakingPicture || _isProcessing || !mounted) return;

    // 🚀 性能优化：150ms 防抖节流，避免 CPU 过载
    if (DateTime.now().difference(_lastProcessTime).inMilliseconds < 150) {
      return;
    }
    _lastProcessTime = DateTime.now();
    _isProcessing = true;

    try {
      final inputImage = _convertCameraImage(image, controller);
      if (inputImage == null) return;

      final faces = await _faceDetector.processImage(inputImage);
      
      if (!mounted) return;

      if (faces.isEmpty) {
        state = state.copyWith(statusText: 'camera.no_face'.tr(), statusColor: Colors.red, faceDetected: false);
      } else {
        final face = faces.first;
        bool isCentered = _isFaceCentered(face, image.width, image.height);
        
        if (!isCentered) {
           state = state.copyWith(statusText: 'camera.center_face'.tr(), statusColor: Colors.orange, faceDetected: true);
        } else {
           state = state.copyWith(statusText: 'Ready to Capture', statusColor: Colors.green, faceDetected: true);
        }
      }
    } catch (e) {
      debugPrint('Face detection error: $e');
    } finally {
      _isProcessing = false;
    }
  }

  bool _isFaceCentered(Face face, int imgWidth, int imgHeight) {
    double centerX = face.boundingBox.center.dx;
    double centerY = face.boundingBox.center.dy;
    // 放宽限制，保证较容易对齐
    bool xOk = centerX > imgWidth * 0.2 && centerX < imgWidth * 0.8;
    bool yOk = centerY > imgHeight * 0.2 && centerY < imgHeight * 0.8;
    return xOk && yOk;
  }

  InputImage? _convertCameraImage(CameraImage image, CameraController controller) {
    try {
      final sensorOrientation = controller.description.sensorOrientation;
      final rotation = InputImageRotationValue.fromRawValue(sensorOrientation) ?? InputImageRotation.rotation0deg;
      final format = InputImageFormatValue.fromRawValue(image.format.raw) ?? InputImageFormat.nv21;

      Uint8List bytes;
      // 🚀 性能优化：消除 iOS 端的多余内存拷贝
      if (image.planes.length == 1) {
        bytes = image.planes.first.bytes;
      } else {
        final WriteBuffer allBytes = WriteBuffer();
        for (final Plane plane in image.planes) {
          allBytes.putUint8List(plane.bytes);
        }
        bytes = allBytes.done().buffer.asUint8List();
      }

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

  // --- 手动拍照与验证逻辑 ---
  Future<void> manualCapture(CameraController controller, String? referencePath) async {
    if (state.isTakingPicture) return;
    
    state = state.copyWith(isTakingPicture: true, statusText: 'camera.processing'.tr(), clearErrorMessage: true);

    try {
      await controller.stopImageStream();
      final XFile image = await controller.takePicture();
      
      if (referencePath != null) {
        await _performVerification(image, referencePath);
      } else {
        // 无比对模式，直接成功
        if (mounted) state = state.copyWith(successImage: image);
      }
    } catch (e) {
      debugPrint('Capture error: $e');
      if (mounted) state = state.copyWith(errorMessage: e.toString());
      resetCameraState();
    }
  }

  Future<void> _performVerification(XFile image, String referencePath) async {
    state = state.copyWith(statusText: 'camera.verifying'.tr());

    try {
      final result = await _faceService.compareFacesDetailed(referencePath, image);
      if (!mounted) return;

      if (result.verified) {
        state = state.copyWith(successImage: image);
      } else {
        state = state.copyWith(showFailureDialog: true);
      }
    } catch (e) {
       if (mounted) state = state.copyWith(errorMessage: e.toString());
       resetCameraState();
    }
  }

  void resetCameraState() {
    if (mounted) {
      state = state.copyWith(
        isTakingPicture: false,
        statusText: 'camera.align'.tr(),
        statusColor: Colors.white,
        showFailureDialog: false,
        clearErrorMessage: true,
      );
    }
  }
}

final profileCameraProvider = StateNotifierProvider.autoDispose<ProfileCameraController, ProfileCameraState>((ref) {
  return ProfileCameraController();
});