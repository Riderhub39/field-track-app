import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;
import 'package:gal/gal.dart';

// 🟢 1. 新增一个照片数据类，用于把照片的完整元数据带回预览页
class CapturedPhoto {
  final String path;
  final String address;
  final String staffName;
  final String dateTimeStr;

  CapturedPhoto({
    required this.path,
    required this.address,
    required this.staffName,
    required this.dateTimeStr,
  });
}

// ==========================================
// 2. 状态定义 (State)
// ==========================================
class CameraScreenState {
  final String address;
  final String staffName;
  final String dateTimeStr;
  final bool isProcessing;
  final String? errorMessage;
  final int captureCount; 
  final List<CapturedPhoto> capturedImages; // 🟢 新增：保存当前会话拍下的所有照片

  CameraScreenState({
    this.address = "Locating...",
    this.staffName = "Loading...",
    this.dateTimeStr = "",
    this.isProcessing = false,
    this.errorMessage,
    this.captureCount = 0,
    this.capturedImages = const [], 
  });

  CameraScreenState copyWith({
    String? address,
    String? staffName,
    String? dateTimeStr,
    bool? isProcessing,
    String? errorMessage,
    int? captureCount,
    List<CapturedPhoto>? capturedImages,
  }) {
    return CameraScreenState(
      address: address ?? this.address,
      staffName: staffName ?? this.staffName,
      dateTimeStr: dateTimeStr ?? this.dateTimeStr,
      isProcessing: isProcessing ?? this.isProcessing,
      errorMessage: errorMessage,
      captureCount: captureCount ?? this.captureCount,
      capturedImages: capturedImages ?? this.capturedImages,
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
// 3. 逻辑控制器 (Controller)
// ==========================================
class CameraScreenNotifier extends AutoDisposeNotifier<CameraScreenState> {
  Timer? _timer;

  @override
  CameraScreenState build() {
    ref.onDispose(() {
      _timer?.cancel();
    });
    _initData();
    _startClock();
    return CameraScreenState(
      dateTimeStr: DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now()),
    );
  }

  void _startClock() {
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
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        state = state.copyWith(address: "Location disabled");
        return;
      }
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
      state = state.copyWith(address: "Location Error (Try outside/Enable GPS)");
    }
  }

  // 🟢 拍照并烧录水印，但不上传！
  Future<void> capturePhoto(CameraController cameraController, String clientName) async {
    if (!state.isReady) return;
    state = state.copyWith(isProcessing: true, errorMessage: null);

    try {
      final XFile rawImage = await cameraController.takePicture();

      state = state.copyWith(
        isProcessing: false, 
        captureCount: state.captureCount + 1 
      );

      _processWatermarkInBackground(
        rawImage: rawImage,
        address: state.address,
        staffName: state.staffName,
        dateTimeStr: state.dateTimeStr,
        clientName: clientName,
      );
    } catch (e) {
      state = state.copyWith(isProcessing: false, errorMessage: "Capture failed: ${e.toString()}");
    }
  }

  Future<void> _processWatermarkInBackground({
    required XFile rawImage,
    required String address,
    required String staffName,
    required String dateTimeStr,
    required String clientName,
  }) async {
    try {
      final args = _WatermarkArgs(
        inputPath: rawImage.path, 
        address: address, 
        staffName: staffName, 
        dateTimeStr: dateTimeStr,
        clientName: clientName,
      );
      final watermarkedFile = await compute(_watermarkInIsolate, args);

      try { await Gal.putImage(watermarkedFile.path, album: "FieldTrack"); } catch (_) {}

      // 🟢 重点：将处理好的照片追加到 state 的列表中
      final newPhoto = CapturedPhoto(
        path: watermarkedFile.path,
        address: address,
        staffName: staffName,
        dateTimeStr: dateTimeStr,
      );

      state = state.copyWith(
        capturedImages: [...state.capturedImages, newPhoto],
      );

    } catch (e) {
      debugPrint("❌ Watermark failed: $e");
    }
  }
}

final cameraScreenProvider = NotifierProvider.autoDispose<CameraScreenNotifier, CameraScreenState>(() {
  return CameraScreenNotifier();
});

// ==========================================
// 4. 后台 Isolate 水印处理 (保持不变)
// ==========================================
class _WatermarkArgs {
  final String inputPath;
  final String address;
  final String staffName;
  final String dateTimeStr;
  final String clientName;
  _WatermarkArgs({
    required this.inputPath, required this.address, required this.staffName, 
    required this.dateTimeStr, required this.clientName
  });
}

File _watermarkInIsolate(_WatermarkArgs args) {
  final Uint8List bytes = File(args.inputPath).readAsBytesSync();
  img.Image? baseImage = img.decodeImage(bytes);
  if (baseImage == null) return File(args.inputPath);

  const int targetWidth = 720;
  if (baseImage.width != targetWidth) {
    baseImage = img.copyResize(baseImage, width: targetWidth, interpolation: img.Interpolation.linear);
  }

  img.BitmapFont font = img.arial24; 
  const int marginRight = 20;
  const int marginBottom = 20; 

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

  List<String> allLines = [args.dateTimeStr];
  if (args.clientName.isNotEmpty) {
    allLines.add("Client: ${args.clientName}");
  }
  allLines.addAll([
    ...wrapText(args.address, 45), 
    "Staff: ${args.staffName}"
  ]);

  int lineHeight = (font.lineHeight * 1.3).toInt();
  int yStart = baseImage.height - (allLines.length * lineHeight) - marginBottom;

  for (int i = 0; i < allLines.length; i++) {
    String line = allLines[i];
    int textWidth = line.length * 12; 
    int x = baseImage.width - marginRight - textWidth;
    
    bool isHighlight = line.startsWith("Client:") || line.startsWith("Staff:"); 
    
    final black = img.ColorRgba8(0, 0, 0, 255);
    for (var o in [[-2, -2], [0, -2], [2, -2], [-2, 0], [2, 0], [-2, 2], [0, 2], [2, 2]]) {
      img.drawString(baseImage, line, font: font, x: x + o[0], y: yStart + (i * lineHeight) + o[1], color: black);
    }
    
    img.Color mainColor = isHighlight ? img.ColorRgba8(255, 235, 59, 255) : img.ColorRgba8(255, 255, 255, 255); 
    img.drawString(baseImage, line, font: font, x: x, y: yStart + (i * lineHeight), color: mainColor);
  }

  final String newPath = '${Directory.systemTemp.path}/ev_${DateTime.now().millisecondsSinceEpoch}.jpg';
  final File newFile = File(newPath);
  newFile.writeAsBytesSync(img.encodeJpg(baseImage, quality: 75));
  return newFile;
}