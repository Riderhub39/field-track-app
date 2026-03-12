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
import 'package:shared_preferences/shared_preferences.dart'; // 🟢 引入插件
import '../services/time_service.dart';
import 'package:easy_localization/easy_localization.dart';
import '../services/tracking_service.dart';
import '../services/notification_service.dart';
import 'package:firebase_database/firebase_database.dart';

// ==========================================
// 1. 状态定义 (State)
// ==========================================
class AttendanceState {
  // 用户数据
  final String staffName;
  final String employeeId;
  final String myEmpCode; 
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

  // 🟢 PDPA 相关
  final bool shouldShowLocationConsent; // 是否显示 PDPA 询问

  // 今日打卡缓存
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
    this.currentAddress = "att.locating", 
    this.initialPosition,
    this.markers = const {},
    this.isLoading = false,
    this.isProcessingAction = false,
    this.capturedPhoto,
    this.selectedAction = "Clock In",
    this.shouldShowLocationConsent = false, // 默认不显示
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
    bool? shouldShowLocationConsent,
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
      shouldShowLocationConsent: shouldShowLocationConsent ?? this.shouldShowLocationConsent,
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
class AttendanceNotifier extends AutoDisposeNotifier<AttendanceState> {
  StreamSubscription? _attendanceSub;
  Map<String, dynamic>? _officeSettingsCache;

  @override
  AttendanceState build() {
    _initAll();
    
    ref.onDispose(() {
      _attendanceSub?.cancel();
    });

    return AttendanceState();
  }

  Future<void> _initAll() async {
    // 🟢 1. 优先检查 PDPA 状态
    await _checkPDPAConsent();

    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      NotificationService().bindFCMToken(user.uid);
      await _fetchUserData(user.uid);
      _listenToTodayAttendance(user.uid);
    }
    _fetchOfficeSettings(); 
    
    // 🟢 2. 只有在不需要显示弹窗（即已 Ignore）时，才自动执行定位
    if (!state.shouldShowLocationConsent) {
      await _initLocation();
    }
  }

  // 🟢 核心逻辑：检查是否需要显示 PDPA 询问
  Future<void> _checkPDPAConsent() async {
    final prefs = await SharedPreferences.getInstance();
    // 检查是否永久忽略了该提醒
    bool hasIgnored = prefs.getBool('has_ignored_pdpa_permanently') ?? false;
    
    if (!hasIgnored) {
      state = state.copyWith(shouldShowLocationConsent: true);
    }
  }

  // 🟢 核心逻辑：完成 PDPA 授权流程
  Future<void> completePDPAConsent({required bool permanently}) async {
    if (permanently) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('has_ignored_pdpa_permanently', true);
    }
    
    state = state.copyWith(shouldShowLocationConsent: false);
    
    // 用户操作后，无论点击哪个，立刻开始初始化位置（本次会话允许使用位置）
    await _initLocation();
  }

  Future<void> _fetchOfficeSettings() async {
    try {
      final doc = await FirebaseFirestore.instance.collection('settings').doc('office_location').get(const GetOptions(source: Source.serverAndCache));
      if (doc.exists) {
        _officeSettingsCache = doc.data();
      }
    } catch (e) {
      debugPrint("Failed to load office settings cache: $e");
    }
  }

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
    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 3), 
        ),
      );
    } catch (e) {
      return await Geolocator.getLastKnownPosition();
    }
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

  Future<String?> validateRestrictionsAndSetAction(String action) async {
    state = state.copyWith(isLoading: true, clearMessages: true, clearPhoto: true);
    
    try {
      if (_officeSettingsCache == null) {
        await _fetchOfficeSettings();
      }
      
      if (_officeSettingsCache == null) {
         state = state.copyWith(selectedAction: action);
         return null;
      }
      
      final data = _officeSettingsCache!;
      final double officeLat = (data['latitude'] as num).toDouble();
      final double officeLng = (data['longitude'] as num).toDouble();
      final double allowedRadius = (data['radius'] as num?)?.toDouble() ?? 500.0;

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

        if (kDebugMode && (currentSSID == 'AndroidWifi' || currentBSSID == '02:00:00:00:00:00' || currentBSSID == null)) {
          isWifiValid = true;
        } else {
          for (var config in allowedWifiList) {
            bool ssidMatch = config['ssid'] == currentSSID;
            bool bssidMatch = true;
            if (config['bssid'] != null && config['bssid']!.isNotEmpty) {
               if (currentBSSID == null) {
                 throw "Not connected to company Wifi.Please connect to clock.";
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

      Position? currentPos = await _determinePosition();
      if (currentPos == null) throw "Cannot determine GPS location.";

      double distanceInMeters = Geolocator.distanceBetween(
        currentPos.latitude, currentPos.longitude, officeLat, officeLng,
      );

      if (distanceInMeters > allowedRadius) {
        throw "You are outside office range.\nPlease move closer to clock in.";
      }

      state = state.copyWith(selectedAction: action);
      return null; 
    } catch (e) {
      return e.toString(); 
    } finally {
      state = state.copyWith(isLoading: false);
    }
  }

  void setCapturedPhoto(XFile photo) {
    state = state.copyWith(capturedPhoto: photo);
  }

  void clearCapturedPhoto() {
    state = state.copyWith(clearPhoto: true);
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
    final DateTime actionTime = TimeService.now; 
    final String uid = user.uid;

    try {
      Position? position = await _determinePosition();
      if (position == null) throw "GPS Signal Lost";

      String addressStr = await _fetchAddressString(position);
      final todayStr = DateFormat('yyyy-MM-dd').format(actionTime);

      final docRef = FirebaseFirestore.instance.collection('attendance').doc();
      
      Map<String, dynamic> newRecord = {
        'uid': uid,
        'name': state.staffName,
        'email': user.email ?? "",
        'date': todayStr,
        'verificationStatus': "Pending", 
        'session': action, 
        'location': GeoPoint(position.latitude, position.longitude),
        'address': addressStr,
        'photoUrl': "pending", 
        'localPhotoPath': photoFile.path, 
        'timestamp': Timestamp.fromDate(actionTime), 
      };

      await docRef.set(newRecord);

      if (action == 'Clock In' || action == 'Break In') {
        ref.read(trackingProvider.notifier).startTracking(uid);
        try {
          FirebaseDatabase.instance.ref("live_locations/$uid").update({
            'uid': uid,
            'lat': position.latitude,
            'lng': position.longitude,
            'speed': 0.0, 
            'heading': 0.0,
            'lastUpdate': ServerValue.timestamp, 
          });
        } catch (e) {
          debugPrint("❌ Init Location Upload Failed: $e");
        }
      } else if (action == 'Break Out' || action == 'Clock Out') {
        ref.read(trackingProvider.notifier).stopTracking();
      }

      final actionTimeStr = DateFormat('h:mm a').format(actionTime);
      final formattedAction = action.toLowerCase(); 

      state = state.copyWith(
        isProcessingAction: false, 
        clearPhoto: true, 
        successMessage: "You have successfully $formattedAction at $actionTimeStr" 
      );

      _uploadPhotoBackground(docRef, uid, photoFile, actionTime);

    } catch (e) {
      debugPrint("Submit failed: $e");
      state = state.copyWith(
        isProcessingAction: false, 
        errorMessage: "Operation Failed: Please try again."
      );
    }
  }

  Future<void> _uploadPhotoBackground(DocumentReference docRef, String uid, XFile photoFile, DateTime actionTime) async {
    try {
      String fileName = '${actionTime.millisecondsSinceEpoch}.jpg';
      Reference storageRef = FirebaseStorage.instance
          .ref()
          .child('attendance_photos')
          .child(uid)
          .child(fileName);
      
      await storageRef.putFile(File(photoFile.path));
      String photoUrl = await storageRef.getDownloadURL();

      await docRef.update({'photoUrl': photoUrl});
    } catch (e) {
      debugPrint("Background photo upload failed: $e");
    }
  }
}

final attendanceProvider = NotifierProvider.autoDispose<AttendanceNotifier, AttendanceState>(() {
  return AttendanceNotifier();
});