import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;
import 'package:gal/gal.dart';

// ==========================================
// 1. 状态定义 (State) - 保持不变
// ==========================================
class CameraScreenState {
  final String address;
  final String staffName;
  final String dateTimeStr;
  final bool isProcessing;
  final String? errorMessage;
  final int captureCount; // 🟢 用于触发界面的连拍成功提示

  CameraScreenState({
    this.address = "Locating...",
    this.staffName = "Loading...",
    this.dateTimeStr = "",
    this.isProcessing = false,
    this.errorMessage,
    this.captureCount = 0,
  });

  CameraScreenState copyWith({
    String? address,
    String? staffName,
    String? dateTimeStr,
    bool? isProcessing,
    String? errorMessage,
    int? captureCount,
  }) {
    return CameraScreenState(
      address: address ?? this.address,
      staffName: staffName ?? this.staffName,
      dateTimeStr: dateTimeStr ?? this.dateTimeStr,
      isProcessing: isProcessing ?? this.isProcessing,
      errorMessage: errorMessage,
      captureCount: captureCount ?? this.captureCount,
    );
  }

  bool get isReady =>
      address != "Locating..." &&
      address != "Location Error" &&
      staffName != "Loading..." &&
      staffName != "Unknown Staff" &&
      !isProcessing;
}

// ==========================================
// 2. 逻辑控制器 (Controller)
// ==========================================
class CameraScreenNotifier extends AutoDisposeNotifier<CameraScreenState> {
  Timer? _timer;

  @override
  CameraScreenState build() {
    // 1. 注册清理逻辑
    ref.onDispose(() {
      _timer?.cancel();
    });

    // 2. 异步获取网络和定位数据
    _initData();

    // 3. 启动定时器
    _startClock();

    // 🚀 核心修复：直接将当前时间赋予初始状态，而不是在 build 期间修改 state
    return CameraScreenState(
      dateTimeStr: DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now()),
    );
  }

  void _startClock() {
    // 🚀 核心修复：删除了容易导致奔溃的 _updateTime() 同步调用
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _updateTime());
  }

  void _updateTime() {
    state = state.copyWith(dateTimeStr: DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now()));
  }

  Future<void> _initData() async {
    await Future.wait([_fetchStaffName(), _initLocationAndAddress()]);
  }

  Future<void> _fetchStaffName() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      try {
        final q = await FirebaseFirestore.instance.collection('users').where('authUid', isEqualTo: user.uid).limit(1).get();
        if (q.docs.isNotEmpty) {
          final data = q.docs.first.data();
          final dynamic personal = data['personal'];
          String name = (personal is Map && personal['name'] != null) ? personal['name'] : (data['name'] ?? "Staff");
          
          state = state.copyWith(staffName: name);
          return;
        }
      } catch (e) {
        debugPrint("Error fetching staff name: $e");
      }
    }
    state = state.copyWith(staffName: "Unknown Staff");
  }

 Future<void> _initLocationAndAddress() async {
    try {
      // 1. 检查定位服务是否开启
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        state = state.copyWith(address: "Location disabled");
        return;
      }

      // 2. 检查并请求定位权限
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          state = state.copyWith(address: "Permission denied");
          return;
        }
      }
      if (permission == LocationPermission.deniedForever) {
        state = state.copyWith(address: "Permission denied forever");
        return;
      }

      // 3. 获取定位，增加 10 秒超时防止卡死
      Position pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high)
      ).timeout(const Duration(seconds: 10));

      List<Placemark> placemarks = await placemarkFromCoordinates(pos.latitude, pos.longitude);
      if (placemarks.isNotEmpty) {
        final p = placemarks.first;
        String fullAddress = [p.street, p.subLocality, p.locality, p.postalCode, p.administrativeArea]
            .where((e) => e != null && e.toString().isNotEmpty)
            .join(', ');
            
        state = state.copyWith(address: fullAddress.isEmpty ? "Unknown Address" : fullAddress);
      }
    } catch (e) {
      debugPrint("Location error: $e");
      // 如果超时或其他错误，降级提示
      state = state.copyWith(address: "Location Error (Try outside/Enable GPS)");
    }
  }

  // 🚀 核心优化：连拍逻辑
  Future<void> captureAndUpload(CameraController cameraController) async {
    if (!state.isReady) return;

    // 锁定极短时间，仅用于获取感光元器件快门画面
    state = state.copyWith(isProcessing: true, errorMessage: null);

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception("User not logged in");

      // 1. 闪电抓拍（约 0.1 ~ 0.3 秒）
      final XFile rawImage = await cameraController.takePicture();

      // 2. 拍完立刻释放快门，允许用户继续点击下一张连拍
      state = state.copyWith(
        isProcessing: false, 
        captureCount: state.captureCount + 1 // 触发 UI 的 Toast 提示
      );

      // 3. 把耗时的加水印和网络上传剥离，丢进后台不管它（不用 await）
      _processAndUploadInBackground(
        rawImage: rawImage,
        userUid: user.uid,
        address: state.address,
        staffName: state.staffName,
        dateTimeStr: state.dateTimeStr,
      );

    } catch (e) {
      state = state.copyWith(isProcessing: false, errorMessage: "Capture failed: ${e.toString()}");
    }
  }

  // 🟢 独立的后台静默上传任务
  Future<void> _processAndUploadInBackground({
    required XFile rawImage,
    required String userUid,
    required String address,
    required String staffName,
    required String dateTimeStr,
  }) async {
    try {
      // 1. 丢给 Isolate 烧录水印与图片压缩
      final args = _WatermarkArgs(
        inputPath: rawImage.path, address: address, staffName: staffName, dateTimeStr: dateTimeStr,
      );
      final watermarkedFile = await compute(_watermarkInIsolate, args);
      String fileName = watermarkedFile.path.split('/').last;

      // 2. 静默存入手机相册
      try {
        await Gal.putImage(watermarkedFile.path, album: "FieldTrack");
      } catch (_) {}

      // 3. 静默上传 Firebase Storage
      Reference storageRef = FirebaseStorage.instance.ref().child('accident_evidence').child(fileName);
      await storageRef.putFile(watermarkedFile);
      String downloadUrl = await storageRef.getDownloadURL();

      // 4. 静默写入数据库
      await FirebaseFirestore.instance.collection('evidence_logs').add({
        'uid': userUid,
        'staffName': staffName,
        'photoUrl': downloadUrl,
        'location': address,
        'capturedAt': FieldValue.serverTimestamp(),
        'localTime': dateTimeStr,
        'fileName': fileName,
        'type': 'accident_evidence'
      });

    } catch (e) {
      debugPrint("❌ Background upload failed: $e");
    }
  }
}

// 🔴 CHANGED: 暴露 Provider
final cameraScreenProvider = NotifierProvider.autoDispose<CameraScreenNotifier, CameraScreenState>(() {
  return CameraScreenNotifier();
});

// ==========================================
// 3. 后台 Isolate 水印处理与极致压缩 - 保持不变
// ==========================================
class _WatermarkArgs {
  final String inputPath;
  final String address;
  final String staffName;
  final String dateTimeStr;
  _WatermarkArgs({required this.inputPath, required this.address, required this.staffName, required this.dateTimeStr});
}

File _watermarkInIsolate(_WatermarkArgs args) {
  final Uint8List bytes = File(args.inputPath).readAsBytesSync();
  img.Image? baseImage = img.decodeImage(bytes);
  if (baseImage == null) return File(args.inputPath);

  // 🚀 将 1080p 降为 720p：体积更小，极大提升 Firebase 传输速度
  const int targetWidth = 720;
  if (baseImage.width != targetWidth) {
    baseImage = img.copyResize(baseImage, width: targetWidth, interpolation: img.Interpolation.linear);
  }

  img.BitmapFont font = img.arial24; // 字体缩小配合 720 p
  const int marginRight = 20;
  const int marginBottom = 20; // 匹配上移后的 UI

  List<String> wrapText(String text, int maxChars) {
    List<String> lines = [];
    String currentLine = "";
    for (var word in text.split(' ')) {
      if ((currentLine + word).length > maxChars) {
        lines.add(currentLine.trim());
        currentLine = "$word ";
      } else {
        currentLine += "$word ";
      }
    }
    if (currentLine.isNotEmpty) lines.add(currentLine.trim());
    return lines;
  }

  List<String> allLines = [args.dateTimeStr, ...wrapText(args.address, 45), "Staff: ${args.staffName}"];
  int lineHeight = (font.lineHeight * 1.3).toInt();
  int yStart = baseImage.height - (allLines.length * lineHeight) - marginBottom;

  for (int i = 0; i < allLines.length; i++) {
    String line = allLines[i];
    int textWidth = line.length * 12; 
    int x = baseImage.width - marginRight - textWidth;
    bool isStaff = (i == allLines.length - 1);
    
    final black = img.ColorRgba8(0, 0, 0, 255);
    for (var o in [[-2, -2], [0, -2], [2, -2], [-2, 0], [2, 0], [-2, 2], [0, 2], [2, 2]]) {
      img.drawString(baseImage, line, font: font, x: x + o[0], y: yStart + (i * lineHeight) + o[1], color: black);
    }
    final mainColor = isStaff ? img.ColorRgba8(255, 235, 59, 255) : img.ColorRgba8(255, 255, 255, 255);
    img.drawString(baseImage, line, font: font, x: x, y: yStart + (i * lineHeight), color: mainColor);
  }

  final String newPath = '${Directory.systemTemp.path}/ev_${DateTime.now().millisecondsSinceEpoch}.jpg';
  final File newFile = File(newPath);
  
  // 🚀 JPG 压缩率 75，肉眼无损，但图片可以压到 300KB 以内，秒传！
  newFile.writeAsBytesSync(img.encodeJpg(baseImage, quality: 75));
  return newFile;
}