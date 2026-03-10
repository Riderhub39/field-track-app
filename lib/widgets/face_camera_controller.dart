import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img; 
import '../services/face_recognition_service.dart';

// ==========================================
// 1. 状态定义 (State)
// ==========================================
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
  final bool showHelpTips; 

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
    this.showHelpTips = false, 
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
    bool? showHelpTips, 
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
      showHelpTips: showHelpTips ?? this.showHelpTips,
    );
  }
}

// ==========================================
// 2. 逻辑控制器 (Controller)
// ==========================================
class FaceCameraNotifier extends AutoDisposeNotifier<FaceCameraState> {
  late final FaceDetector _faceDetector;
  final FaceRecognitionService _faceService = FaceRecognitionService();
  String? _referencePath;

  DateTime _lastProcessTime = DateTime.now();
  bool _isProcessingFrame = false;
  DateTime _stepStartTime = DateTime.now(); 

  @override
  FaceCameraState build() {
    _initDetector();

    ref.onDispose(() {
      _faceDetector.close();
    });

    return FaceCameraState(statusText: 'camera.align'.tr());
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
  }

  Future<void> prepareReference(String? path) async {
    _referencePath = path;
    
    try {
      await _faceService.initialize();
      
      if (path != null) {
        if (path.startsWith('http') || path.startsWith('https')) {
          state = state.copyWith(statusText: "Loading Profile...");
          
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
      state = state.copyWith(errorMessage: "Failed to load face data: $e");
    } finally {
      state = state.copyWith(
        isLoadingReference: false,
        statusText: 'camera.align'.tr(),
      );
      _stepStartTime = DateTime.now(); 
    }
  }

  void _checkTimeout() {
    final secondsSpent = DateTime.now().difference(_stepStartTime).inSeconds;
    if (secondsSpent > 3 && !state.showHelpTips) {
      state = state.copyWith(showHelpTips: true);
    } else if (secondsSpent <= 3 && state.showHelpTips) {
      state = state.copyWith(showHelpTips: false);
    }
  }

  Future<void> processImage(CameraImage image, CameraController controller) async {
    if (state.isLoadingReference || _isProcessingFrame || state.isVerifying) return;

    if (DateTime.now().difference(_lastProcessTime).inMilliseconds < 150) {
      return;
    }
    _lastProcessTime = DateTime.now();
    _isProcessingFrame = true;

    try {
      _checkTimeout(); 

      final inputImage = _convertCameraImage(image, controller);
      if (inputImage == null) return;

      final faces = await _faceDetector.processImage(inputImage);

      if (faces.isEmpty) {
        if (state.step != 0 && !state.hasCaptured) {
          _updateUI(status: 'camera.no_face'.tr(), color: Colors.red, step: 0);
        }
      } else {
        final face = faces.first;
        
        // 🟢 核心修复：获取真实的旋转后宽高
        int actualWidth = image.width;
        int actualHeight = image.height;
        
        // 如果底层传感器和手机屏幕是垂直关系（通常竖屏就是 90 或 270 度），需要交换宽高！
        if (controller.description.sensorOrientation == 90 || controller.description.sensorOrientation == 270) {
          actualWidth = image.height;
          actualHeight = image.width;
        }

        // 使用真实的宽度计算人脸比例
        double faceRatio = face.boundingBox.width / actualWidth;

        // 使用真实的宽高做居中判断
        bool isCentered = _isFaceCentered(face, actualWidth, actualHeight);
        
        if (!isCentered) {
          if (!state.hasCaptured) {
            _updateUI(status: 'Center your face', color: Colors.orange, step: 0);
          }
        } 
        else if (faceRatio < 0.25) {
          _updateUI(status: 'Move closer', color: Colors.orange, step: 0);
        } 
        else if (faceRatio > 0.75) {
          _updateUI(status: 'Move further', color: Colors.orange, step: 0);
        } 
        else {
          final double? yaw = face.headEulerAngleY; 
          final double? pitch = face.headEulerAngleX; 
          
          if (yaw == null || pitch == null) return;

          // 🟢 精简逻辑：只要脸在框内且没有过度歪头，直接抓拍并验证！
          if (state.step == 0 && !state.hasCaptured) {
            // 放宽判断，允许头部有轻微的倾斜（±15度以内都算合格）
            if (yaw > -15 && yaw < 15 && pitch > -15 && pitch < 15) { 
               await _captureAndVerify(image, controller); 
            } else {
               _updateUI(status: "Look straight", color: Colors.yellowAccent, step: 0);
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
      if (state.step != step) {
        _stepStartTime = DateTime.now();
        state = state.copyWith(statusText: status, statusColor: color, step: step, showHelpTips: false);
      } else {
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

  // 🟢 极速验证逻辑：一气呵成完成抽帧和对比
  Future<void> _captureAndVerify(CameraImage image, CameraController controller) async {
    if (state.hasCaptured || state.isVerifying) return;
    
    // 立即进入验证状态，锁死后续帧的进入
    state = state.copyWith(
      hasCaptured: true,
      isVerifying: true,
      step: 2,
      statusText: 'camera.verifying'.tr(),
      statusColor: Colors.blue,
    );
    
    try {
      // 🟢 保护措施 1：安全地停止流，即使底层硬件报错也【不要】中断整个验证流程
      try {
        if (controller.value.isStreamingImages) {
          await controller.stopImageStream(); 
        }
      } catch (streamError) {
        debugPrint("Stop stream warning (Ignored): $streamError");
      }
      
      final dir = await getTemporaryDirectory();
      final String tempPath = '${dir.path}/temp_captured_face_${DateTime.now().millisecondsSinceEpoch}.jpg';
      
      final Map<String, dynamic> isolateData = {
        'width': image.width,
        'height': image.height,
        'format': image.format.group.name,
        'sensorOrientation': controller.description.sensorOrientation,
        'isFrontCamera': controller.description.lensDirection == CameraLensDirection.front,
        'tempPath': tempPath,
        'planes': image.planes.map((p) => {
          'bytes': p.bytes,
          'bytesPerRow': p.bytesPerRow,
          'bytesPerPixel': p.bytesPerPixel,
        }).toList(),
      };

      final String? savedPath = await compute(_processCameraImageInIsolate, isolateData);
      
      if (savedPath != null) {
        final capturedImage = XFile(savedPath);
        state = state.copyWith(tempCapturedImage: capturedImage);

        if (_referencePath == null) {
          state = state.copyWith(successImage: capturedImage);
          return;
        }

        // 进行人脸比对
        VerifyResult result = await _faceService.compareFacesDetailed(_referencePath!, capturedImage);

        if (result.verified) {
          state = state.copyWith(successImage: capturedImage);
        } else {
          state = state.copyWith(
            statusText: 'camera.failed'.tr(),
            statusColor: Colors.red,
            showFailureDialog: true,
            isVerifying: false,
          );
        }
      } else {
        throw Exception("Failed to convert image in isolate.");
      }
    } catch (e) {
      debugPrint("Capture/Verify error: $e");
      // 🟢 保护措施 2：出错了绝对不要悄悄 reset 导致死循环闪跳！
      // 而是明确告诉用户出错了，让用户点击弹窗后再重置。
      state = state.copyWith(
        statusText: 'Error occurred',
        statusColor: Colors.red,
        showFailureDialog: true,
        isVerifying: false,
      );
    }
  }
  void resetCameraState(CameraController? controller) async {
    _stepStartTime = DateTime.now();
    state = FaceCameraState(
      statusText: 'camera.align'.tr(),
      statusColor: Colors.white,
      isLoadingReference: false, 
      step: 0,
      hasCaptured: false,
      isVerifying: false,
      showFailureDialog: false,
      showHelpTips: false,
    );
    
    if (controller != null && !controller.value.isStreamingImages) {
      await controller.startImageStream((img) => processImage(img, controller));
    }
  }
}

final faceCameraProvider = NotifierProvider.autoDispose<FaceCameraNotifier, FaceCameraState>(() {
  return FaceCameraNotifier();
});

// ==========================================
// 3. 后台图像处理 Isolate 函数 (必须放在类外顶层)
// ==========================================
// ==========================================
// 3. 后台图像处理 Isolate 函数 (必须放在类外顶层)
// ==========================================
Future<String?> _processCameraImageInIsolate(Map<String, dynamic> data) async {
  try {
    final int width = data['width'];
    final int height = data['height'];
    final String format = data['format'];
    final int sensorOrientation = data['sensorOrientation'];
    final bool isFrontCamera = data['isFrontCamera'];
    final String tempPath = data['tempPath'];
    final List<dynamic> planes = data['planes'];

    img.Image? convertedImage;

    // 🟢 兼容 nv21 和 yuv420
    if (format == 'yuv420' || format == 'nv21') {
      convertedImage = img.Image(width: width, height: height);
      
      if (planes.length == 3) {
        // 这是标准的 Y, U, V 三个独立平面
        final Uint8List yPlane = planes[0]['bytes'];
        final Uint8List uPlane = planes[1]['bytes'];
        final Uint8List vPlane = planes[2]['bytes'];
        
        final int uvRowStride = planes[1]['bytesPerRow'];
        final int uvPixelStride = planes[1]['bytesPerPixel'] ?? 1;

        for (int y = 0; y < height; y++) {
          int uvRow = y >> 1;
          for (int x = 0; x < width; x++) {
            int uvCol = x >> 1;
            int index = y * width + x;
            int uvIndex = uvRow * uvRowStride + uvCol * uvPixelStride;

            final int yp = yPlane[index];
            final int up = uPlane[uvIndex];
            final int vp = vPlane[uvIndex];

            int r = (yp + vp * 1436 / 1024 - 179).round().clamp(0, 255);
            int g = (yp - up * 46549 / 131072 + 44 - vp * 93604 / 131072 + 91).round().clamp(0, 255);
            int b = (yp + up * 1814 / 1024 - 227).round().clamp(0, 255);

            convertedImage.setPixelRgb(x, y, r, g, b);
          }
        }
      } else if (planes.length == 1) {
        // 🔴 修复黑白问题：部分手机 nv21 格式被压缩在同一个 plane 里
        final Uint8List bytes = planes[0]['bytes'];
        final int frameSize = width * height;

        for (int y = 0; y < height; y++) {
          for (int x = 0; x < width; x++) {
            int yIndex = y * width + x;
            if (yIndex >= bytes.length) continue;
            int yp = bytes[yIndex];

            // 计算交错的 UV 数据偏移量
            int uvRow = y >> 1;
            int uvCol = x >> 1;
            int uvIndex = frameSize + (uvRow * width) + (uvCol * 2);

            int vp = 128;
            int up = 128;
            if (uvIndex < bytes.length - 1) {
                vp = bytes[uvIndex];     // V
                up = bytes[uvIndex + 1]; // U
            }

            int r = (yp + vp * 1436 / 1024 - 179).round().clamp(0, 255);
            int g = (yp - up * 46549 / 131072 + 44 - vp * 93604 / 131072 + 91).round().clamp(0, 255);
            int b = (yp + up * 1814 / 1024 - 227).round().clamp(0, 255);
            convertedImage.setPixelRgb(x, y, r, g, b);
          }
        }
      } else if (planes.length == 2) {
        // 🔴 修复黑白问题：NV12/NV21 两个平面的情况（Y一个，交错的UV一个）
        final Uint8List yPlane = planes[0]['bytes'];
        final Uint8List uvPlane = planes[1]['bytes'];
        final int uvRowStride = planes[1]['bytesPerRow'] ?? width;
        final int uvPixelStride = planes[1]['bytesPerPixel'] ?? 2;

        for (int y = 0; y < height; y++) {
          for (int x = 0; x < width; x++) {
            int yIndex = y * width + x;
            if (yIndex >= yPlane.length) continue;
            int yp = yPlane[yIndex];

            int uvRow = y >> 1;
            int uvCol = x >> 1;
            int uvIndex = uvRow * uvRowStride + uvCol * uvPixelStride;

            int vp = 128;
            int up = 128;
            if (uvIndex < uvPlane.length - 1) {
                vp = uvPlane[uvIndex];     // V
                up = uvPlane[uvIndex + 1]; // U
            }

            int r = (yp + vp * 1436 / 1024 - 179).round().clamp(0, 255);
            int g = (yp - up * 46549 / 131072 + 44 - vp * 93604 / 131072 + 91).round().clamp(0, 255);
            int b = (yp + up * 1814 / 1024 - 227).round().clamp(0, 255);
            convertedImage.setPixelRgb(x, y, r, g, b);
          }
        }
      }
    } else if (format == 'bgra8888') {
       final Uint8List bytes = planes[0]['bytes'];
       convertedImage = img.Image.fromBytes(
         width: width,
         height: height,
         bytes: bytes.buffer,
         order: img.ChannelOrder.bgra,
       );
    }

    if (convertedImage != null) {
      if (sensorOrientation != 0) {
        convertedImage = img.copyRotate(convertedImage, angle: sensorOrientation);
      }
      if (isFrontCamera) {
        convertedImage = img.flipHorizontal(convertedImage);
      }

      final jpegBytes = img.encodeJpg(convertedImage, quality: 85);
      final file = File(tempPath);
      file.writeAsBytesSync(jpegBytes);
      return tempPath;
    }
  } catch (e) {
    debugPrint("Isolate image processing error: $e");
  }
  return null;
}