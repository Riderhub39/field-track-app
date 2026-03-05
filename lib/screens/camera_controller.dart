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
// 🔴 CHANGED: 迁移至 AutoDisposeNotifier
class CameraScreenNotifier extends AutoDisposeNotifier<CameraScreenState> {
  Timer? _timer;

  // 🔴 CHANGED: 使用 build 方法初始化和清理
  @override
  CameraScreenState build() {
    _initData();
    _startClock();

    ref.onDispose(() {
      _timer?.cancel();
    });

    return CameraScreenState();
  }

  void _startClock() {
    _updateTime();
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
      Position pos = await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(accuracy: LocationAccuracy.high));
      List<Placemark> placemarks = await placemarkFromCoordinates(pos.latitude, pos.longitude);
      if (placemarks.isNotEmpty) {
        final p = placemarks.first;
        String fullAddress = [p.street, p.subLocality, p.locality, p.postalCode, p.administrativeArea]
            .where((e) => e != null && e.toString().isNotEmpty)
            .join(', ');
            
        state = state.copyWith(address: fullAddress.isEmpty ? "Unknown Address" : fullAddress);
      }
    } catch (e) {
      state = state.copyWith(address: "Location Error");
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

  img.BitmapFont font = img.arial24; // 字体缩小配合 720p
  const int marginRight = 20;
  const int marginBottom = 180; // 匹配上移后的 UI

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