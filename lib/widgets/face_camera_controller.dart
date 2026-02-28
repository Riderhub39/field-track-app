import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:path_provider/path_provider.dart';
import '../services/face_recognition_service.dart';

class FaceCameraState {
  final String statusText;
  final Color statusColor;
  final bool isLoadingReference;
  final int step; 
  final bool hasCaptured;
  final bool isVerifying;
  final XFile? tempCapturedImage; 
  final XFile? successImage;      
  final bool showFailureDialog;   
  final String? errorMessage;     

  FaceCameraState({
    this.statusText = "Initializing...",
    this.statusColor = Colors.white,
    this.isLoadingReference = true,
    this.step = 0,
    this.hasCaptured = false,
    this.isVerifying = false,
    this.tempCapturedImage,
    this.successImage,
    this.showFailureDialog = false,
    this.errorMessage, 
  });

  FaceCameraState copyWith({
    String? statusText,
    Color? statusColor,
    bool? isLoadingReference,
    int? step,
    bool? hasCaptured,
    bool? isVerifying,
    XFile? tempCapturedImage,
    XFile? successImage,
    bool? showFailureDialog,
    String? errorMessage, 
    bool clearErrorMessage = false,
  }) {
    return FaceCameraState(
      statusText: statusText ?? this.statusText,
      statusColor: statusColor ?? this.statusColor,
      isLoadingReference: isLoadingReference ?? this.isLoadingReference,
      step: step ?? this.step,
      hasCaptured: hasCaptured ?? this.hasCaptured,
      isVerifying: isVerifying ?? this.isVerifying,
      tempCapturedImage: tempCapturedImage ?? this.tempCapturedImage, 
      successImage: successImage ?? this.successImage, 
      showFailureDialog: showFailureDialog ?? this.showFailureDialog,
      errorMessage: clearErrorMessage ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

class FaceCameraController extends StateNotifier<FaceCameraState> {
  late final FaceDetector _faceDetector;
  final FaceRecognitionService _faceService = FaceRecognitionService();
  String? _referencePath;

  DateTime _lastProcessTime = DateTime.now();
  bool _isProcessingFrame = false;

  FaceCameraController() : super(FaceCameraState()) {
    _initDetector();
  }

  void _initDetector() {
    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        performanceMode: FaceDetectorMode.accurate, 
        enableLandmarks: true,
        enableClassification: false, 
        enableContours: false,
        minFaceSize: 0.15, 
      ),
    );
    state = state.copyWith(statusText: 'camera.align'.tr());
  }

  Future<void> prepareReference(String? path) async {
    _referencePath = path;
    
    try {
      await _faceService.initialize();
      
      if (path != null) {
        if (path.startsWith('http') || path.startsWith('https')) {
          if (mounted) state = state.copyWith(statusText: "Loading Profile...");
          
          // 🚀 增加 15 秒超时控制，避免弱网导致的永久死锁
          final request = await HttpClient().getUrl(Uri.parse(path)).timeout(const Duration(seconds: 15));
          final response = await request.close();
          
          if (response.statusCode == 200) {
            final bytes = await consolidateHttpClientResponseBytes(response);
            final dir = await getTemporaryDirectory();
            final file = File('${dir.path}/temp_ref_face.jpg');
            await file.writeAsBytes(bytes);
            
            await _faceService.preloadReference(file.path);
          } else {
             throw Exception("HTTP ${response.statusCode}");
          }
        } else {
          await _faceService.preloadReference(path);
        }
      }
    } catch (e) {
      debugPrint("Reference Initialization Error: $e");
      if (mounted) state = state.copyWith(errorMessage: "Failed to load face data: $e");
    } finally {
      if (mounted) {
        state = state.copyWith(
          isLoadingReference: false,
          statusText: 'camera.align'.tr(),
        );
      }
    }
  }

  @override
  void dispose() {
    _faceDetector.close();
    super.dispose();
  }

  Future<void> processImage(CameraImage image, CameraController controller) async {
    if (state.isLoadingReference || _isProcessingFrame || state.isVerifying || !mounted) return;

    if (DateTime.now().difference(_lastProcessTime).inMilliseconds < 150) {
      return;
    }
    _lastProcessTime = DateTime.now();
    _isProcessingFrame = true;

    try {
      final inputImage = _convertCameraImage(image, controller);
      if (inputImage == null) return;

      final faces = await _faceDetector.processImage(inputImage);
      if (!mounted) return;

      if (faces.isEmpty) {
        if (state.step != 0 && !state.hasCaptured) {
          _updateUI(status: 'camera.no_face'.tr(), color: Colors.red, step: 0);
        }
      } else {
        final face = faces.first;
        bool isCentered = _isFaceCentered(face, image.width, image.height);
        
        if (!isCentered) {
          if (!state.hasCaptured) {
            _updateUI(status: 'camera.center_face'.tr(), color: Colors.orange, step: 0);
          }
        } else {
          final double? yaw = face.headEulerAngleY; 
          final double? pitch = face.headEulerAngleX; 
          
          if (yaw == null || pitch == null) return;

          if (state.step == 0 && !state.hasCaptured) {
            if (yaw > -10 && yaw < 10 && pitch > -10 && pitch < 10) { 
               await _captureFrontFace(controller);
            } else {
               _updateUI(status: "Look straight at the camera", color: Colors.yellowAccent, step: 0);
            }
          } else if (state.step == 1 && state.hasCaptured) {
            _updateUI(
              status: "Please nod up or down\nSila angguk ke atas atau bawah", 
              color: Colors.greenAccent, 
              step: 1
            );

            if (pitch > 15 || pitch < -15) {
              _startVerificationProcess(controller); 
            }
          }
        }
      }
    } catch (e) {
      debugPrint("Process error: $e");
    } finally {
      _isProcessingFrame = false;
    }
  }

  void _updateUI({required String status, required Color color, required int step}) {
    if (state.statusText != status || state.statusColor != color || state.step != step) {
      if (mounted) {
        state = state.copyWith(statusText: status, statusColor: color, step: step);
      }
    }
  }

  bool _isFaceCentered(Face face, int imgWidth, int imgHeight) {
    double centerX = face.boundingBox.center.dx;
    double centerY = face.boundingBox.center.dy;
    
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

  Future<void> _captureFrontFace(CameraController controller) async {
    if (state.hasCaptured) return;
    
    try {
      await controller.stopImageStream();
      final image = await controller.takePicture();
      
      if (mounted) {
        state = state.copyWith(
          hasCaptured: true,
          step: 1,
          tempCapturedImage: image,
        );
      }
      await controller.startImageStream((img) => processImage(img, controller));
    } catch (e) {
      debugPrint("Silent capture error: $e");
      resetCameraState(controller);
    }
  }

  Future<void> _startVerificationProcess(CameraController controller) async {
    if (state.isVerifying || state.tempCapturedImage == null) return;
    
    if (mounted) {
      state = state.copyWith(
        isVerifying: true,
        step: 2,
        statusText: 'camera.verifying'.tr(),
        statusColor: Colors.blue,
      );
    }

    try {
      await controller.stopImageStream(); 

      if (_referencePath == null) {
        if (mounted) state = state.copyWith(successImage: state.tempCapturedImage);
        return;
      }

      VerifyResult result = await _faceService.compareFacesDetailed(_referencePath!, state.tempCapturedImage!);

      if (!mounted) return;

      if (result.verified) {
        state = state.copyWith(successImage: state.tempCapturedImage);
      } else {
        state = state.copyWith(
          statusText: 'camera.failed'.tr(),
          statusColor: Colors.red,
          showFailureDialog: true,
        );
      }
    } catch (e) {
      debugPrint("Verification error: $e");
      resetCameraState(controller);
    }
  }

  void resetCameraState(CameraController? controller) async {
    if (!mounted) return;
    state = FaceCameraState(
      statusText: 'camera.align'.tr(),
      statusColor: Colors.white,
      isLoadingReference: false, 
      step: 0,
      hasCaptured: false,
      isVerifying: false,
      showFailureDialog: false,
    );
    
    if (controller != null && !controller.value.isStreamingImages) {
      await controller.startImageStream((img) => processImage(img, controller));
    }
  }
}

final faceCameraProvider = StateNotifierProvider.autoDispose<FaceCameraController, FaceCameraState>((ref) {
  return FaceCameraController();
});