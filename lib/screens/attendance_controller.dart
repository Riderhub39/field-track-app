import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:network_info_plus/network_info_plus.dart';
import '../services/time_service.dart';
import 'package:easy_localization/easy_localization.dart';
import '../services/tracking_service.dart';
import '../services/notification_service.dart';

// ==========================================
// 1. 状态定义 (State) - 保持不变
// ==========================================
class AttendanceState {
  // 用户数据
  final String staffName;
  final String employeeId;
  final String myEmpCode; // User Doc ID
  final ImageProvider? appBarImage;
  final String? referenceFaceIdPath;
  final bool isFetchingUser;

  // 定位与地图
  final String currentAddress;
  final CameraPosition? initialPosition;
  final Set<Marker> markers;

  // 交互状态
  final bool isLoading;
  final bool isProcessingAction;
  final XFile? capturedPhoto;
  final String selectedAction;

  // 今日打卡缓存 (用于瞬间渲染 UI，无需重复请求)
  final String todayInTime;
  final String todayOutTime;
  final String? lastSession;
  final bool hasClockedOut;
  final bool hasAnyRecord;
  final DateTime? lastPunchTime;

  // 事件通知
  final String? errorMessage;
  final String? successMessage;

  AttendanceState({
    this.staffName = "Staff",
    this.employeeId = "",
    this.myEmpCode = "",
    this.appBarImage,
    this.referenceFaceIdPath,
    this.isFetchingUser = true,
    this.currentAddress = "att.locating", // locale key
    this.initialPosition,
    this.markers = const {},
    this.isLoading = false,
    this.isProcessingAction = false,
    this.capturedPhoto,
    this.selectedAction = "Clock In",
    this.todayInTime = "--:--",
    this.todayOutTime = "--:--",
    this.lastSession,
    this.hasClockedOut = false,
    this.hasAnyRecord = false,
    this.lastPunchTime,
    this.errorMessage,
    this.successMessage,
  });

  AttendanceState copyWith({
    String? staffName,
    String? employeeId,
    String? myEmpCode,
    ImageProvider? appBarImage,
    String? referenceFaceIdPath,
    bool? isFetchingUser,
    String? currentAddress,
    CameraPosition? initialPosition,
    Set<Marker>? markers,
    bool? isLoading,
    bool? isProcessingAction,
    XFile? capturedPhoto,
    String? selectedAction,
    String? todayInTime,
    String? todayOutTime,
    String? lastSession,
    bool? hasClockedOut,
    bool? hasAnyRecord,
    DateTime? lastPunchTime,
    String? errorMessage,
    String? successMessage,
    bool clearPhoto = false,
    bool clearMessages = false,
  }) {
    return AttendanceState(
      staffName: staffName ?? this.staffName,
      employeeId: employeeId ?? this.employeeId,
      myEmpCode: myEmpCode ?? this.myEmpCode,
      appBarImage: appBarImage ?? this.appBarImage,
      referenceFaceIdPath: referenceFaceIdPath ?? this.referenceFaceIdPath,
      isFetchingUser: isFetchingUser ?? this.isFetchingUser,
      currentAddress: currentAddress ?? this.currentAddress,
      initialPosition: initialPosition ?? this.initialPosition,
      markers: markers ?? this.markers,
      isLoading: isLoading ?? this.isLoading,
      isProcessingAction: isProcessingAction ?? this.isProcessingAction,
      capturedPhoto: clearPhoto ? null : (capturedPhoto ?? this.capturedPhoto),
      selectedAction: selectedAction ?? this.selectedAction,
      todayInTime: todayInTime ?? this.todayInTime,
      todayOutTime: todayOutTime ?? this.todayOutTime,
      lastSession: lastSession ?? this.lastSession,
      hasClockedOut: hasClockedOut ?? this.hasClockedOut,
      hasAnyRecord: hasAnyRecord ?? this.hasAnyRecord,
      lastPunchTime: lastPunchTime ?? this.lastPunchTime,
      errorMessage: clearMessages ? null : (errorMessage ?? this.errorMessage),
      successMessage: clearMessages ? null : (successMessage ?? this.successMessage),
    );
  }
}

// ==========================================
// 2. 逻辑控制器 (Controller)
// ==========================================
// 🔴 CHANGED: 迁移到 Notifier (保持与原版一样非 autoDispose 的生命周期)
class AttendanceNotifier extends Notifier<AttendanceState> {
  StreamSubscription? _attendanceSub;

  // 🔴 CHANGED: 使用 build 方法初始化
  @override
  AttendanceState build() {
    // 异步初始化
    _initAll();
    
    // 🔴 CHANGED: 注册资源清理
    ref.onDispose(() {
      _attendanceSub?.cancel();
    });

    return AttendanceState();
  }

  Future<void> _initAll() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      NotificationService().bindFCMToken(user.uid);
      await _fetchUserData(user.uid);
      _listenToTodayAttendance(user.uid);
    }
    await _initLocation();
  }

  // 全局只拉取一次用户数据，供所有 Tab 共享
  Future<void> _fetchUserData(String uid) async {
    try {
      final q = await FirebaseFirestore.instance.collection('users').where('authUid', isEqualTo: uid).limit(1).get();
      if (q.docs.isNotEmpty) {
        final doc = q.docs.first;
        final data = doc.data();
        
        String sName = data['personal']?['name'] ?? "Staff";
        String eId = data['personal']?['empCode'] != null ? "(${data['personal']['empCode']})" : "";
        String docId = doc.id;
        
        ImageProvider? appImage;
        String? refFacePath;
        
        final faceUrl = data['faceIdPhoto']?.toString();
        if (faceUrl != null && faceUrl.isNotEmpty) {
          if (faceUrl.startsWith('http')) {
            appImage = NetworkImage(faceUrl);
            refFacePath = await _downloadFaceImage(faceUrl);
          } else {
            final file = File(faceUrl);
            if (file.existsSync()) {
              appImage = FileImage(file);
              refFacePath = faceUrl;
            }
          }
        }
        
        // 🔴 CHANGED: 移除 mounted
        state = state.copyWith(
          staffName: sName,
          employeeId: eId,
          myEmpCode: docId,
          appBarImage: appImage,
          referenceFaceIdPath: refFacePath,
          isFetchingUser: false,
        );
      }
    } catch (e) {
      state = state.copyWith(isFetchingUser: false);
    }
  }

  Future<String?> _downloadFaceImage(String url) async {
    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final tempDir = await getTemporaryDirectory();
        final tempFile = File('${tempDir.path}/face_id_ref.jpg');
        await tempFile.writeAsBytes(response.bodyBytes);
        return tempFile.path;
      }
    } catch (_) {}
    return null;
  }

  // 🟢 实时后台监听今日打卡，不再在点击打卡时阻塞查询
  void _listenToTodayAttendance(String uid) {
    final now = TimeService.now; 
  final todayStr = DateFormat('yyyy-MM-dd').format(now);

    _attendanceSub = FirebaseFirestore.instance
        .collection('attendance')
        .where('uid', isEqualTo: uid)
        .where('date', isEqualTo: todayStr)
        .where('verificationStatus', whereIn: ['Pending', 'Verified', 'Corrected'])
        .snapshots()
        .listen((snapshot) {
      
      String inT = "--:--";
      String outT = "--:--";
      String? lastSess;
      bool clockedOut = false;
      DateTime? lastPunch;

      final docs = snapshot.docs;
      docs.sort((a, b) => (a['timestamp'] as Timestamp).compareTo(b['timestamp'] as Timestamp));

      if (docs.isNotEmpty) {
        final lastData = docs.last.data();
        lastSess = lastData['session'];
        lastPunch = (lastData['timestamp'] as Timestamp).toDate();
        clockedOut = docs.any((doc) => doc.data()['session'] == 'Clock Out');

        for (var doc in docs) {
          final data = doc.data();
          final ts = (data['timestamp'] as Timestamp).toDate();
          final formatted = DateFormat('HH:mm').format(ts);
          if (data['session'] == 'Clock In') inT = formatted;
          if (data['session'] == 'Clock Out') outT = formatted;
        }
      }

      state = state.copyWith(
        todayInTime: inT,
        todayOutTime: outT,
        lastSession: lastSess,
        hasClockedOut: clockedOut,
        hasAnyRecord: docs.isNotEmpty,
        lastPunchTime: lastPunch,
      );
    });
  }

  Future<void> _initLocation() async {
    try {
      Position? pos = await _determinePosition();
      if (pos != null) {
        final latLng = LatLng(pos.latitude, pos.longitude);
        String addr = await _fetchAddressString(pos);
        state = state.copyWith(
          initialPosition: CameraPosition(target: latLng, zoom: 15),
          markers: { Marker(markerId: const MarkerId('current'), position: latLng) },
          currentAddress: addr,
        );
      }
    } catch (e) {
      state = state.copyWith(currentAddress: "att.location_error");
    }
  }

  Future<Position?> _determinePosition() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return null;
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return null;
    }
    return await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(accuracy: LocationAccuracy.high));
  }

  Future<String> _fetchAddressString(Position position) async {
    try {
      List<Placemark> placemarks = await placemarkFromCoordinates(position.latitude, position.longitude);
      if (placemarks.isNotEmpty) {
        Placemark place = placemarks[0];
        List<String> parts = [
          place.name ?? "", place.subThoroughfare ?? "", place.thoroughfare ?? "",
          place.subLocality ?? "", place.locality ?? "", place.postalCode ?? "",
          place.administrativeArea ?? "", place.country ?? ""
        ];
        return parts.where((p) => p.isNotEmpty).toSet().join(", ");
      }
    } catch (_) {}
    return "GPS: ${position.latitude.toStringAsFixed(4)}, ${position.longitude.toStringAsFixed(4)}";
  }

  // 🟢 核心打卡校验逻辑
  Future<String?> validateRestrictionsAndSetAction(String action) async {
    state = state.copyWith(isLoading: true, clearMessages: true);
    
    try {
      final doc = await FirebaseFirestore.instance.collection('settings').doc('office_location').get();
      if (!doc.exists) {
        state = state.copyWith(selectedAction: action);
        return null; // 没设限制，允许放行
      }
      
      final data = doc.data() as Map<String, dynamic>;
      final double officeLat = (data['latitude'] as num).toDouble();
      final double officeLng = (data['longitude'] as num).toDouble();
      final double allowedRadius = (data['radius'] as num?)?.toDouble() ?? 500.0;

      // WiFi 校验
      List<Map<String, String>> allowedWifiList = [];
      if (data['allowedWifis'] is List) {
        for (var item in data['allowedWifis']) {
          if (item is String) {
            allowedWifiList.add({'ssid': item, 'bssid': ''});
          } else if (item is Map) {
            allowedWifiList.add({
              'ssid': item['ssid']?.toString() ?? '',
              'bssid': item['bssid']?.toString().toLowerCase() ?? ''
            });
          }
        }
      } else if (data['wifiSSID'] is String) {
        allowedWifiList.add({'ssid': data['wifiSSID'], 'bssid': ''});
      }

      if (allowedWifiList.isNotEmpty) {
        final info = NetworkInfo();
        String? currentSSID = await info.getWifiName();
        String? currentBSSID = await info.getWifiBSSID(); 

        if (currentSSID != null) currentSSID = currentSSID.replaceAll('"', '');
        if (currentBSSID != null) currentBSSID = currentBSSID.toLowerCase();
        if (currentBSSID == "02:00:00:00:00:00") currentBSSID = null;

        bool isWifiValid = false;

        // 开发模式后门：放行模拟器网络
        if (kDebugMode && (currentSSID == 'AndroidWifi' || currentBSSID == '02:00:00:00:00:00' || currentBSSID == null)) {
          isWifiValid = true;
        } else {
          for (var config in allowedWifiList) {
            bool ssidMatch = config['ssid'] == currentSSID;
            bool bssidMatch = true;
            if (config['bssid'] != null && config['bssid']!.isNotEmpty) {
               if (currentBSSID == null) {
                 throw "Unable to verify WiFi security.\nPlease enable GPS/Location permission.";
               }
               bssidMatch = config['bssid'] == currentBSSID;
            }
            if (ssidMatch && bssidMatch) {
              isWifiValid = true;
              break;
            }
          }
        }

        if (!isWifiValid) {
           throw "Not connected to company WiFi.\nPlease connect to clock in.";
        }
      }

      // GPS 距离校验
      Position? currentPos = await _determinePosition();
      if (currentPos == null) throw "Cannot determine GPS location.";

      double distanceInMeters = Geolocator.distanceBetween(
        currentPos.latitude, currentPos.longitude, officeLat, officeLng,
      );

      if (distanceInMeters > allowedRadius) {
        throw "You are outside office range.\nPlease move closer to clock in.";
      }

      state = state.copyWith(selectedAction: action);
      return null; // 验证通过
    } catch (e) {
      return e.toString(); // 返回错误给 UI
    } finally {
      state = state.copyWith(isLoading: false);
    }
  }

  void setCapturedPhoto(XFile photo) {
    state = state.copyWith(capturedPhoto: photo);
  }

  void clearMessages() {
    state = state.copyWith(clearMessages: true);
  }

  Future<void> submitAttendance() async {
    if (state.capturedPhoto == null || state.isProcessingAction) return;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    state = state.copyWith(isProcessingAction: true, clearMessages: true);

    final XFile photoFile = state.capturedPhoto!;
    final String action = state.selectedAction;
    final DateTime actionTime = (TimeService.now); 
    final String uid = user.uid;

    try {
      Position? position = await _determinePosition();
      if (position == null) throw "GPS Signal Lost";

      String addressStr = await _fetchAddressString(position);

      String fileName = '${actionTime.millisecondsSinceEpoch}.jpg';
      Reference storageRef = FirebaseStorage.instance
          .ref()
          .child('attendance_photos')
          .child(uid)
          .child(fileName);
      
      await storageRef.putFile(File(photoFile.path));
      String photoUrl = await storageRef.getDownloadURL();

      final todayStr = DateFormat('yyyy-MM-dd').format(actionTime);
      
      Map<String, dynamic> newRecord = {
        'uid': uid,
        'name': state.staffName,
        'email': user.email ?? "",
        'date': todayStr,
        'verificationStatus': "Pending", 
        'session': action, 
        'location': GeoPoint(position.latitude, position.longitude),
        'address': addressStr,
        'photoUrl': photoUrl, 
        'timestamp': Timestamp.fromDate(actionTime), 
      };

      await FirebaseFirestore.instance.collection('attendance').add(newRecord);

      // 触发后台轨迹追踪
      if (action == 'Clock In' || action == 'Break In') {
        ref.read(trackingProvider.notifier).startTracking(uid);
      } else if (action == 'Break Out' || action == 'Clock Out') {
        ref.read(trackingProvider.notifier).stopTracking();
      }

      state = state.copyWith(
        isProcessingAction: false, 
        clearPhoto: true, 
        successMessage: "att.msg_success".tr()
      );

    } catch (e) {
      debugPrint("Upload failed: $e");
      state = state.copyWith(
        isProcessingAction: false, 
        errorMessage: "Upload Failed. Please check your connection or try again later."
      );
    }
  }
}

// 🔴 CHANGED: 暴露 Provider 使用 NotifierProvider 语法
final attendanceProvider = NotifierProvider<AttendanceNotifier, AttendanceState>(() {
  return AttendanceNotifier();
});