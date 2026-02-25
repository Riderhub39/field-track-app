import 'dart:io';
import 'dart:math';
import 'dart:ui'; // 🟢 [修复] 引入 UI 库以识别 Rect 类
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

class FaceRecognitionService {
  Interpreter? _interpreter;
  late final FaceDetector _faceDetector;

  static const int inputSize = 112;
  static const int embeddingSize = 192;
  double threshold = 1.0; 

  // 缓存底片的中间数据，用于 Debug 对比
  List<double>? _cachedRefEmbedding;
  List<double>? _debugRefInputTensor; 
  int? _debugRefCenterPixel;          

  static final FaceRecognitionService _instance = FaceRecognitionService._internal();
  factory FaceRecognitionService() => _instance;
  
  FaceRecognitionService._internal() {
    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        performanceMode: FaceDetectorMode.accurate,
        enableLandmarks: true, 
        enableClassification: false,
      ),
    );
  }

  Future<void> initialize({
    String assetPath = 'assets/models/mobilefacenet.tflite',
    int threads = 4,
  }) async {
    try {
      final options = InterpreterOptions()..threads = threads;
      _interpreter = await Interpreter.fromAsset(assetPath, options: options);
      _interpreter!.allocateTensors();
      
      var inputShape = _interpreter!.getInputTensor(0).shape;
      var outputShape = _interpreter!.getOutputTensor(0).shape;
      
      debugPrint("✅ Model Loaded.");
      debugPrint("ℹ️ Model Input: $inputShape");
      debugPrint("ℹ️ Model Output: $outputShape");
      
    } catch (e) {
      debugPrint("❌ Model load error: $e");
    }
  }

  void clearReference() {
    _cachedRefEmbedding = null;
    _debugRefInputTensor = null;
    _debugRefCenterPixel = null;
  }

  // ==========================================
  //  核心逻辑：参考图加载与探测图比对
  // ==========================================

  Future<bool> preloadReference(String path) async {
    debugPrint("\n🔵 [STEP 1] Loading Reference...");
    final file = File(path);
    if (!file.existsSync()) return false;

    // 1. 直接用原文件路径调用 ML Kit (🚀 避免了二次编码和 I/O)
    final inputImage = InputImage.fromFilePath(path);
    final faces = await _faceDetector.processImage(inputImage);
    
    Rect? faceBox;
    if (faces.isNotEmpty) {
      Face face = faces.reduce((a, b) => (a.boundingBox.width * a.boundingBox.height) > (b.boundingBox.width * b.boundingBox.height) ? a : b);
      faceBox = face.boundingBox;
      debugPrint("📐 [REF] Face Box: ${faceBox.left}, ${faceBox.top}, ${faceBox.width}x${faceBox.height}");
    } else {
      debugPrint("⚠️ [REF] No faces detected.");
    }

    // 2. 将耗时的图像处理操作丢给后台 Isolate (🚀 避免 UI 卡顿)
    final processArgs = _ProcessImageArgs(path, faceBox);
    final processResult = await compute(_processImageInIsolate, processArgs);
    
    if (processResult == null) return false;

    // 3. 在主线程运行 TFLite (C++ 底层极快)
    var embedding = _runInference(processResult.inputTensor, label: "REF");
    if (embedding == null) return false;

    _cachedRefEmbedding = embedding;
    _debugRefInputTensor = processResult.inputTensor.toList();
    _debugRefCenterPixel = processResult.centerPixel;

    return true;
  }

  Future<VerifyResult> compareFacesDetailed(String refPath, XFile photo) async {
    debugPrint("\n🟠 [STEP 2] Loading Probe...");
    
    if (_cachedRefEmbedding == null) {
      bool success = await preloadReference(refPath);
      if (!success) return VerifyResult(false, 999.0);
    }

    // 1. ML Kit 人脸检测 (直接读取原始路径)
    final inputImage = InputImage.fromFilePath(photo.path);
    final faces = await _faceDetector.processImage(inputImage);
    
    Rect? faceBox;
    if (faces.isNotEmpty) {
      Face face = faces.reduce((a, b) => (a.boundingBox.width * a.boundingBox.height) > (b.boundingBox.width * b.boundingBox.height) ? a : b);
      faceBox = face.boundingBox;
      debugPrint("📐 [PROBE] Face Box: ${faceBox.left}, ${faceBox.top}, ${faceBox.width}x${faceBox.height}");
    } else {
      debugPrint("⚠️ [PROBE] No faces detected.");
    }

    // 2. Isolate 图像处理
    final processArgs = _ProcessImageArgs(photo.path, faceBox);
    final processResult = await compute(_processImageInIsolate, processArgs);
    
    if (processResult == null || _cachedRefEmbedding == null) {
      return VerifyResult(false, 999.0);
    }

    // 3. TFLite 推理
    var probeEmbedding = _runInference(processResult.inputTensor, label: "PROBE");
    if (probeEmbedding == null) return VerifyResult(false, 999.0);

    // ===========================================
    // 🚨 终极对比 DEBUG 报告
    // ===========================================
    debugPrint("\n🔍 ========= DEBUG REPORT =========");
    debugPrint("1️⃣ Center Pixel (Raw RGB Hex):");
    debugPrint("   REF  : ${_debugRefCenterPixel?.toRadixString(16).toUpperCase()}");
    debugPrint("   PROBE: ${processResult.centerPixel.toRadixString(16).toUpperCase()}");
    
    debugPrint("2️⃣ Input Tensor (Normalized):");
    debugPrint("   REF  : ${_debugRefInputTensor?.sublist(0, 5)}");
    debugPrint("   PROBE: ${processResult.inputTensor.sublist(0, 5)}");

    debugPrint("3️⃣ Output Embedding (Normalized):");
    debugPrint("   REF  : ${_cachedRefEmbedding?.sublist(0, 5)}");
    debugPrint("   PROBE: ${probeEmbedding.sublist(0, 5)}");

    double distance = _euclideanDistance(_cachedRefEmbedding!, probeEmbedding);
    debugPrint("4️⃣ Euclidean Distance: $distance");
    debugPrint("🔍 ===============================\n");

    return VerifyResult(distance <= threshold, distance);
  }

  // ==========================================
  //  内部处理函数 (运行于主线程)
  // ==========================================

  List<double>? _runInference(Float32List inputTensor, {required String label}) {
    if (_interpreter == null) return null;
    try {
      Object input = inputTensor.reshape([1, inputSize, inputSize, 3]);
      List<List<double>> output = List.generate(1, (_) => List.filled(embeddingSize, 0.0));
      
      _interpreter!.run(input, output);
      return _l2Normalize(output[0]);
    } catch (e) {
      debugPrint("❌ [$label] Run inference error: $e");
      return null;
    }
  }

  List<double> _l2Normalize(List<double> v) {
    double sum = 0.0;
    for (var x in v) {
      sum += x * x;
    }
    final norm = sqrt(sum);
    if (norm == 0.0) return v;
    return v.map((e) => e / norm).toList();
  }

  double _euclideanDistance(List<double> a, List<double> b) {
    double sum = 0.0;
    for (int i = 0; i < a.length; i++) {
      double diff = a[i] - b[i];
      sum += diff * diff;
    }
    return sqrt(sum);
  }
}

// ==========================================
//  独立的 Isolate 静态处理函数
// ==========================================

class _ProcessImageArgs {
  final String filePath;
  final Rect? faceBox;
  _ProcessImageArgs(this.filePath, this.faceBox);
}

class _ProcessImageResult {
  final Float32List inputTensor;
  final int centerPixel;
  _ProcessImageResult(this.inputTensor, this.centerPixel);
}

/// 该方法在后台 Isolate 运行，切勿在此处调用任何 Platform Channel 或全局变量
_ProcessImageResult? _processImageInIsolate(_ProcessImageArgs args) {
  try {
    // 1. 读取与解码
    final bytes = File(args.filePath).readAsBytesSync();
    img.Image? image = img.decodeImage(bytes);
    if (image == null) return null;

    // 2. 修复旋转与颜色通道
    image = img.bakeOrientation(image);
    if (image.numChannels != 3) {
      image = image.convert(numChannels: 3);
    }

    img.Image finalImage = image;

    // 3. 安全裁剪 (🚀 边界情况处理优化)
    if (args.faceBox != null) {
      int x = args.faceBox!.left.toInt();
      int y = args.faceBox!.top.toInt();
      int w = args.faceBox!.width.toInt();
      int h = args.faceBox!.height.toInt();

      int size = (max(w, h) * 1.2).toInt();
      
      // 限制 Size 不能超过原图的最小边
      int maxSize = min(image.width, image.height);
      if (size > maxSize) size = maxSize;

      int centerX = x + w ~/ 2;
      int centerY = y + h ~/ 2;
      
      int newX = centerX - size ~/ 2;
      int newY = centerY - size ~/ 2;

      // 完美防越界控制
      if (newX < 0) newX = 0;
      if (newY < 0) newY = 0;
      if (newX + size > image.width) newX = image.width - size;
      if (newY + size > image.height) newY = image.height - size;

      finalImage = img.copyCrop(image, x: newX, y: newY, width: size, height: size);
    }

    // 4. Resize 到 112x112
    const int targetSize = 112; 
    img.Image resized = img.copyResize(finalImage, width: targetSize, height: targetSize);

    // 提取中心像素供 Debug
    var p = resized.getPixel(targetSize ~/ 2, targetSize ~/ 2);
    int centerPixel = (p.r.toInt() << 16) | (p.g.toInt() << 8) | p.b.toInt();

    // 5. 快速遍历生成输入张量 (🚀 Float32List 直接赋值，最快方式)
    Float32List inputBytes = Float32List(targetSize * targetSize * 3);
    int pixelIndex = 0;

    for (var pixel in resized) {
      inputBytes[pixelIndex++] = (pixel.r - 127.5) / 128.0;
      inputBytes[pixelIndex++] = (pixel.g - 127.5) / 128.0;
      inputBytes[pixelIndex++] = (pixel.b - 127.5) / 128.0;
    }

    return _ProcessImageResult(inputBytes, centerPixel);
    
  } catch (e) {
    debugPrint("Isolate Processing Error: $e");
    return null;
  }
}

// ==========================================
//  外部使用的数据类
// ==========================================
class VerifyResult {
  final bool verified;
  final double score;
  VerifyResult(this.verified, this.score);
}