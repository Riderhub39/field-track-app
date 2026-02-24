import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:camera/camera.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:network_info_plus/network_info_plus.dart'; 
import 'package:flutter_riverpod/flutter_riverpod.dart'; 

import '../widgets/shimmer_loading.dart';
import '../widgets/face_camera_view.dart';
import 'correction_request_screen.dart';
import '../services/tracking_service.dart'; 
import '../services/notification_service.dart'; // 🟢 引入以进行 Token 绑定

class AttendanceScreen extends StatefulWidget {
  const AttendanceScreen({super.key});

  @override
  State<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends State<AttendanceScreen> {
  ImageProvider? _appBarImage;

  @override
  void initState() {
    super.initState();
    _loadUserProfile();
    _autoBindFCM(); // 🟢 自动绑定推送 Token
  }

  Future<void> _autoBindFCM() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      await NotificationService().bindFCMToken(user.uid);
    }
  }

  Future<void> _loadUserProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final q = await FirebaseFirestore.instance
          .collection('users')
          .where('authUid', isEqualTo: user.uid)
          .limit(1)
          .get();

      if (q.docs.isNotEmpty && mounted) {
        final data = q.docs.first.data();
        final faceUrl = data['faceIdPhoto']?.toString();

        if (faceUrl != null && faceUrl.isNotEmpty) {
          if (faceUrl.startsWith('http')) {
            setState(() {
              _appBarImage = NetworkImage(faceUrl);
            });
          } else {
            final file = File(faceUrl);
            if (file.existsSync()) {
              setState(() {
                _appBarImage = FileImage(file);
              });
            }
          }
        }
      }
    } catch (e) {
      // Error handling silently
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Text("att.title".tr()),
          backgroundColor: const Color(0xFF15438c),
          foregroundColor: Colors.white,
          elevation: 0,
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 16.0),
              child: CircleAvatar(
                radius: 16,
                backgroundColor: Colors.grey.shade300,
                backgroundImage: _appBarImage,
                child: _appBarImage == null
                    ? const Icon(Icons.person, color: Colors.grey, size: 20)
                    : null,
              ),
            ),
          ],
        ),
        body: const TabBarView(
          physics: NeverScrollableScrollPhysics(),
          children: [
            AttendanceActionTab(),
            HistoryTab(),
            ScheduleTab(),
            SubmitTab(),
          ],
        ),
        bottomNavigationBar: Container(
          color: Colors.white,
          child: SafeArea(
            child: TabBar(
              labelColor: const Color(0xFF15438c),
              unselectedLabelColor: Colors.black,
              indicatorColor: const Color(0xFF15438c),
              indicatorSize: TabBarIndicatorSize.tab,
              tabs: [
                Tab(icon: const Icon(Icons.touch_app), text: "att.tab_clock_in".tr()),
                Tab(icon: const Icon(Icons.history), text: "att.tab_history".tr()),
                Tab(icon: const Icon(Icons.calendar_month), text: "att.tab_schedule".tr()),
                Tab(icon: const Icon(Icons.assignment_return), text: "att.tab_submit".tr()),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class AttendanceActionTab extends ConsumerStatefulWidget {
  const AttendanceActionTab({super.key});
  @override
  ConsumerState<AttendanceActionTab> createState() => _AttendanceActionTabState();
}

class _AttendanceActionTabState extends ConsumerState<AttendanceActionTab> {
  bool _isLoading = false;
  bool _isProcessingAction = false; 
  String _staffName = "Staff";
  String _employeeId = "";
  
  String _currentAddress = "att.locating".tr(); // 🟢 已多语言化
  Timer? _timer;
  
  String? _referenceFaceIdPath; 
  XFile? _capturedPhoto;
  String _selectedAction = "Clock In"; 

  final Completer<GoogleMapController> _mapController = Completer();
  CameraPosition? _initialPosition;
  Set<Marker> _markers = {};

  // 🟢 今日打卡预览状态
  String _todayInTime = "--:--";
  String _todayOutTime = "--:--";
  StreamSubscription? _attendanceSubscription;

  @override
  void initState() {
    super.initState();
    _fetchUserDataAndFaceId(); 
    _initLocation();
    _listenToTodayAttendance(); // 🟢 开始实时监听
  }

  @override
  void dispose() {
    _timer?.cancel();
    _attendanceSubscription?.cancel();
    super.dispose();
  }

  // 🟢 实时更新今日打卡时间
  void _listenToTodayAttendance() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final todayStr = DateFormat('yyyy-MM-dd').format(DateTime.now());

    _attendanceSubscription = FirebaseFirestore.instance
        .collection('attendance')
        .where('uid', isEqualTo: user.uid)
        .where('date', isEqualTo: todayStr)
        .where('verificationStatus', whereIn: ['Pending', 'Verified', 'Corrected'])
        .snapshots()
        .listen((snapshot) {
      if (mounted) {
        String inT = "--:--";
        String outT = "--:--";
        final docs = snapshot.docs;
        docs.sort((a, b) => (a['timestamp'] as Timestamp).compareTo(b['timestamp'] as Timestamp));

        for (var doc in docs) {
          final data = doc.data();
          final ts = (data['timestamp'] as Timestamp).toDate();
          final formatted = DateFormat('HH:mm').format(ts);
          if (data['session'] == 'Clock In') inT = formatted;
          if (data['session'] == 'Clock Out') outT = formatted;
        }
        setState(() {
          _todayInTime = inT;
          _todayOutTime = outT;
        });
      }
    });
  }

  Future<void> _fetchUserDataAndFaceId() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final q = await FirebaseFirestore.instance
          .collection('users')
          .where('authUid', isEqualTo: user.uid)
          .limit(1)
          .get();
      if (q.docs.isNotEmpty && mounted) {
        final data = q.docs.first.data();
        
        setState(() {
          _staffName = data['personal']['name'] ?? "Staff";
          if (data['personal'] != null && data['personal']['empCode'] != null) {
            _employeeId = "(${data['personal']['empCode']})";
          }
        });

        final faceUrl = data['faceIdPhoto']?.toString();
        if (faceUrl != null) {
          if (faceUrl.startsWith('http')) {
             _downloadFaceImage(faceUrl);
          } else {
             setState(() => _referenceFaceIdPath = faceUrl);
          }
        }
      }
    } catch (e) {
      // Error handling silently
    }
  }

  Future<void> _downloadFaceImage(String url) async {
    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final tempDir = await getTemporaryDirectory();
        final tempFile = File('${tempDir.path}/face_id_ref.jpg');
        await tempFile.writeAsBytes(response.bodyBytes);
        if (mounted) {
          setState(() => _referenceFaceIdPath = tempFile.path);
        }
      }
    } catch (e) {
      // Error handling silently
    }
  }

  Future<void> _initLocation() async {
    try {
      Position? pos = await _determinePosition();
      if (pos != null) {
        final latLng = LatLng(pos.latitude, pos.longitude);
        setState(() {
          _initialPosition = CameraPosition(target: latLng, zoom: 15);
          _markers = {
            Marker(markerId: const MarkerId('current'), position: latLng)
          };
        });
        if (mounted) await _getAddressFromLatLng(pos);
      }
    } catch (e) {
      if (mounted) setState(() => _currentAddress = "att.location_error".tr());
    }
  }

  Future<void> _getAddressFromLatLng(Position position) async {
    try {
      List<Placemark> placemarks =
          await placemarkFromCoordinates(position.latitude, position.longitude);
      
      if (placemarks.isNotEmpty && mounted) {
        Placemark place = placemarks[0];
        
        List<String> parts = [
          place.name ?? "",
          place.subThoroughfare ?? "",
          place.thoroughfare ?? "",
          place.subLocality ?? "",
          place.locality ?? "",
          place.postalCode ?? "",
          place.administrativeArea ?? "",
          place.country ?? ""
        ];

        String detailedAddress = parts
            .where((p) => p.isNotEmpty)
            .toSet() 
            .join(", ");

        setState(() => _currentAddress = detailedAddress);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _currentAddress =
            "GPS: ${position.latitude.toStringAsFixed(4)}, ${position.longitude.toStringAsFixed(4)}");
      }
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
    return await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.high));
  }

  Future<bool> _validateRestrictions() async {
    setState(() => _isLoading = true);
    
    try {
      final doc = await FirebaseFirestore.instance.collection('settings').doc('office_location').get();
      if (!doc.exists) return true;
      
      final data = doc.data() as Map<String, dynamic>;
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

        if (!isWifiValid) {
           throw "Not connected to company WiFi.\nPlease connect to clock in.";
        }
      }

      Position? currentPos = await _determinePosition();
      if (currentPos == null) throw "Cannot determine GPS location.";

      double distanceInMeters = Geolocator.distanceBetween(
        currentPos.latitude,
        currentPos.longitude,
        officeLat,
        officeLng,
      );

      if (distanceInMeters > allowedRadius) {
        throw "You are outside office range.\nPlease move closer to clock in.";
      }

      return true;

    } catch (e) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text("Access Denied"), 
            content: Text(e.toString()),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("OK"))],
          ),
        );
      }
      return false;
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

 Future<void> _showActionPicker() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final now = DateTime.now();
    final todayStr = DateFormat('yyyy-MM-dd').format(now);
    
    final q = await FirebaseFirestore.instance
        .collection('attendance')
        .where('uid', isEqualTo: user.uid)
        .where('date', isEqualTo: todayStr)
        .where('verificationStatus', whereIn: ['Pending', 'Verified', 'Corrected'])
        .get();

    bool hasAnyRecord = q.docs.isNotEmpty; 
    String? lastSession;
    bool hasClockedOut = false;
    DateTime? lastPunchTime;

    if (hasAnyRecord) {
      final docs = q.docs;
      docs.sort((a, b) => (a['timestamp'] as Timestamp).compareTo(b['timestamp'] as Timestamp));
      final last = docs.last;
      
      lastSession = last['session'];
      lastPunchTime = (last['timestamp'] as Timestamp).toDate(); 
      hasClockedOut = docs.any((doc) => doc['session'] == 'Clock Out');
    }

    if (!mounted) return;

    if (lastPunchTime != null) {
      final difference = now.difference(lastPunchTime);
      if (difference.inMinutes < 30) {
        final waitMinutes = 30 - difference.inMinutes;
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.timer, color: Colors.orange),
                SizedBox(width: 10),
                Text("Action Locked"),
              ],
            ),
            content: Text("Please wait $waitMinutes more minutes before your next action to prevent duplicate records."),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text("OK"),
              )
            ],
          ),
        );
        return; 
      }
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true, 
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text("att.select_action".tr(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 20),
              
              _buildActionTile(
                title: "att.act_clock_in".tr(),
                subtitle: hasAnyRecord 
                    ? "att.sub_locked_submitted".tr() 
                    : "att.sub_start_shift".tr(),
                icon: Icons.login,
                color: Colors.green,
                isLocked: hasAnyRecord, 
                onTap: () => _handleAction("Clock In"),
              ),
              
              const Divider(),

              _buildActionTile(
                title: "att.act_break_out".tr(),
                subtitle: hasClockedOut 
                    ? "Shift Ended" 
                    : ((lastSession == 'Break Out') ? "att.sub_locked_verified".tr() : "att.sub_lunch".tr()),
                icon: Icons.coffee,
                color: Colors.orange,
                isLocked: !hasAnyRecord || (lastSession == 'Break Out') || hasClockedOut,
                onTap: () => _handleAction("Break Out"),
              ),

              _buildActionTile(
                title: "att.act_break_in".tr(),
                subtitle: hasClockedOut 
                    ? "Shift Ended" 
                    : ((lastSession == 'Break In') ? "att.sub_locked_verified".tr() : "att.sub_back_work".tr()),
                icon: Icons.work_history,
                color: Colors.blue,
                isLocked: !hasAnyRecord || (lastSession == 'Break In') || hasClockedOut || (lastSession != 'Break Out'),
                onTap: () => _handleAction("Break In"),
              ),

              const Divider(),

              _buildActionTile(
                title: "att.act_clock_out".tr(),
                subtitle: hasClockedOut ? "att.sub_locked_verified".tr() : "att.sub_end_shift".tr(),
                icon: Icons.logout,
                color: Colors.red,
                isLocked: !hasAnyRecord || hasClockedOut,
                onTap: () => _handleAction("Clock Out"),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildActionTile({
    required String title, 
    required String subtitle, 
    required IconData icon, 
    required Color color, 
    required bool isLocked,
    required VoidCallback onTap
  }) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: isLocked ? Colors.grey : color, 
        child: Icon(isLocked ? Icons.lock : icon, color: Colors.white)
      ),
      title: Text(
        title, 
        style: TextStyle(
          color: isLocked ? Colors.grey : Colors.black,
          decoration: isLocked ? TextDecoration.lineThrough : null
        )
      ),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
      onTap: isLocked ? null : onTap,
      enabled: !isLocked,
    );
  }

  void _handleAction(String action) async {
    Navigator.pop(context); 
    bool isAllowed = await _validateRestrictions();
    if (!isAllowed) return; 

    setState(() => _selectedAction = action);
    _takePhoto(); 
  }

  Future<void> _takePhoto() async {
    if (_referenceFaceIdPath == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("att.err_no_face_id".tr())));
      return;
    }

    final result = await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (context) =>
                FaceCameraView(referencePath: _referenceFaceIdPath))); 

    if (result != null && result is XFile && mounted) {
      setState(() {
        _capturedPhoto = result;
      });
      String actionDisplay = _getActionDisplayText(_selectedAction);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text("att.msg_photo_captured".tr(args: [actionDisplay])),
          backgroundColor: Colors.green));
    }
  }

  String _getActionDisplayText(String action) {
    if(action == "Clock In") return "att.act_clock_in".tr();
    if(action == "Break Out") return "att.act_break_out".tr();
    if(action == "Break In") return "att.act_break_in".tr();
    if(action == "Clock Out") return "att.act_clock_out".tr();
    return action;
  }

  Future<void> _submitAttendance() async {
    if (_capturedPhoto == null) return;
    if (_isProcessingAction) return; 

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    setState(() {
      _isProcessingAction = true; 
    });

    final XFile photoFile = _capturedPhoto!;
    final String action = _selectedAction;
    final DateTime actionTime = DateTime.now(); 
    final String uid = user.uid;
    final String email = user.email ?? "";
    final String name = _staffName;

    setState(() {
      _capturedPhoto = null;
      _isLoading = false;
    });

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text("att.msg_queueing".tr(args: [_getActionDisplayText(action)])),
      backgroundColor: Colors.blue,
      duration: const Duration(seconds: 2),
    ));

    await _processUpload(
      uid: uid,
      email: email,
      name: name,
      file: photoFile,
      action: action,
      timestamp: actionTime,
    );
    
    if (mounted) {
      setState(() {
        _isProcessingAction = false;
      });
    }
  }

  Future<void> _processUpload({
    required String uid,
    required String email,
    required String name,
    required XFile file,
    required String action,
    required DateTime timestamp,
  }) async {
    try {
      Position? position = await _determinePosition();
      if (position == null) throw "GPS Signal Lost";

      String addressStr = await _fetchAddressString(position);

      String fileName = '${timestamp.millisecondsSinceEpoch}.jpg';
      Reference storageRef = FirebaseStorage.instance
          .ref()
          .child('attendance_photos')
          .child(uid)
          .child(fileName);
      
      await storageRef.putFile(File(file.path));
      String photoUrl = await storageRef.getDownloadURL();

      final todayStr = DateFormat('yyyy-MM-dd').format(timestamp);
      
      Map<String, dynamic> newRecord = {
        'uid': uid,
        'name': name,
        'email': email,
        'date': todayStr,
        'verificationStatus': "Pending", 
        'session': action, 
        'location': GeoPoint(position.latitude, position.longitude),
        'address': addressStr,
        'photoUrl': photoUrl, 
        'timestamp': Timestamp.fromDate(timestamp), 
      };

      await FirebaseFirestore.instance.collection('attendance').add(newRecord);

      if (action == 'Clock In') {
        ref.read(trackingProvider.notifier).startTracking(uid);
      } else if (action == 'Break Out') {
        ref.read(trackingProvider.notifier).stopTracking();
      } else if (action == 'Break In') {
        ref.read(trackingProvider.notifier).startTracking(uid);
      } else if (action == 'Clock Out') {
        ref.read(trackingProvider.notifier).stopTracking();
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text("att.msg_success".tr()), 
            backgroundColor: Colors.green));
      }

    } catch (e) {
      debugPrint("Upload failed: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Upload Failed. Please check your connection or try again later."), 
            backgroundColor: Colors.red,
          ),
        );
      }
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
    } catch (e) { /* ignore */ }
    return "GPS: ${position.latitude.toStringAsFixed(4)}, ${position.longitude.toStringAsFixed(4)}";
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());

    final now = DateTime.now();
    // 🟢 应用 Locale 到日期格式化
    final displayDate = DateFormat('dd/MM/yyyy (EEE)', context.locale.languageCode).format(now);
    const whiteTextColor = Color(0xFFFFFFFF);
    const naviColor = Color(0xFF15438c);

    String actionDisplay = _getActionDisplayText(_selectedAction);

    return SingleChildScrollView(
      child: Column(
        children: [
          Stack(
            alignment: Alignment.bottomCenter,
            children: [
              SizedBox(
                height: 180,
                width: double.infinity,
                child: _initialPosition == null
                    ? Container(color: Colors.grey[300], child: const Center(child: CircularProgressIndicator()))
                    : GoogleMap(
                        mapType: MapType.normal,
                        initialCameraPosition: _initialPosition!,
                        markers: _markers,
                        myLocationEnabled: true,
                        zoomControlsEnabled: false,
                        onMapCreated: (GoogleMapController controller) {
                          if (!_mapController.isCompleted) {
                            _mapController.complete(controller);
                          }
                        },
                      ),
              ),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.only(topLeft: Radius.circular(16), topRight: Radius.circular(16)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.location_on, color: Colors.orange),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _currentAddress,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            decoration: const BoxDecoration(
              color: naviColor,
              borderRadius: BorderRadius.only(
                bottomLeft: Radius.circular(24),
                bottomRight: Radius.circular(24),
              ),
            ),
            child: Column(
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const Icon(Icons.calendar_today, color: Colors.white, size: 20),
                      const SizedBox(height: 4),
                      Text(displayDate, style: const TextStyle(fontWeight: FontWeight.bold, color: whiteTextColor)),
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                Text(_staffName, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: whiteTextColor)),
                Text(_employeeId, style: const TextStyle(fontSize: 16, color: Colors.white)),

                const SizedBox(height: 20),
                const Divider(color: Colors.white54),
                const SizedBox(height: 15),

                // 🟢 今日打卡预览 (Time Boxes)
                Row(
                  children: [
                    Expanded(child: _buildActionTimeBox("att.label_in".tr(), _todayInTime)),
                    const SizedBox(width: 12),
                    Expanded(child: _buildActionTimeBox("att.label_out".tr(), _todayOutTime)),
                  ],
                ),

                const SizedBox(height: 30),

                GestureDetector(
                  onTap: _isProcessingAction ? null : _showActionPicker,
                  child: Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: _isProcessingAction ? Colors.grey : Colors.amber,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        if (!_isProcessingAction)
                          BoxShadow(color: Colors.amber.withValues(alpha: 0.3), blurRadius: 10, offset: const Offset(0, 5))
                      ],
                      image: _capturedPhoto != null
                          ? DecorationImage(image: FileImage(File(_capturedPhoto!.path)), fit: BoxFit.cover)
                          : null,
                    ),
                    child: _capturedPhoto == null
                        ? (_isProcessingAction 
                            ? const Padding(padding: EdgeInsets.all(20.0), child: CircularProgressIndicator(color: Colors.white))
                            : const Icon(Icons.camera_alt_rounded, color: Colors.white, size: 40))
                        : null,
                  ),
                ),

                const SizedBox(height: 20),
                
                if (_capturedPhoto == null && !_isProcessingAction)
                  Text("att.hint_tap_camera".tr(), style: const TextStyle(color: Colors.white70, fontSize: 12)),

                const SizedBox(height: 20),

                SizedBox(
                  width: double.infinity,
                  height: 55,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      backgroundColor: (_capturedPhoto != null && !_isProcessingAction) ? whiteTextColor : Colors.grey.shade300,
                      foregroundColor: (_capturedPhoto != null && !_isProcessingAction) ? naviColor : Colors.grey.shade500,
                      elevation: (_capturedPhoto != null && !_isProcessingAction) ? 3 : 0,
                    ),
                    onPressed: _isProcessingAction ? null : () {
                      if (_capturedPhoto == null) {
                        showDialog(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: Row(
                              children: [
                                const Icon(Icons.camera_alt_outlined, color: Colors.orange),
                                const SizedBox(width: 10),
                                Text("att.dialog_photo_title".tr()),
                              ],
                            ),
                            content: Text("att.dialog_photo_content".tr()),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: Text("att.btn_ok".tr(), style: const TextStyle(color: Colors.blue)),
                              ),
                            ],
                          ),
                        );
                      } else {
                        _submitAttendance();
                      }
                    },
                    child: Text(
                      _isProcessingAction 
                        ? "Processing..."
                        : (_capturedPhoto != null 
                          ? "att.btn_confirm".tr(args: [actionDisplay])
                          : "att.btn_clock_attendance".tr()),
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // 辅助方法：构建今日打卡专用的 Time Box
  Widget _buildActionTimeBox(String label, String time) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.white70)),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white24),
          ),
          child: Center(
            child: Text(
              time, 
              style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 18)
            ),
          ),
        )
      ],
    );
  }
}

// ==========================================
//  Tab 2: History
// ==========================================
class HistoryTab extends StatefulWidget {
  const HistoryTab({super.key});

  @override
  State<HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<HistoryTab> {
  bool _isDescending = true;

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return const Center(child: Text("Please login"));

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 10),
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: Row(
                  children: [
                    Text("att.header_date".tr(), style: const TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(width: 4),
                    InkWell(
                      onTap: () {
                        setState(() {
                          _isDescending = !_isDescending;
                        });
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(4.0),
                        child: Icon(
                          _isDescending ? Icons.arrow_downward : Icons.arrow_upward,
                          size: 16,
                          color: const Color(0xFF15438c),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                  flex: 4,
                  child: Text("att.header_address".tr(), style: const TextStyle(fontWeight: FontWeight.bold))),
              Expanded(
                  flex: 2,
                  child: Text("att.header_status".tr(), style: const TextStyle(fontWeight: FontWeight.bold), textAlign: TextAlign.right)),
            ],
          ),
        ),
        const Divider(height: 1),
        
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('attendance')
                .where('uid', isEqualTo: user.uid)
                .orderBy('timestamp', descending: _isDescending)
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const ShimmerLoadingList();
              }
              
              final allDocs = snapshot.data?.docs ?? [];
              
              final docs = allDocs.where((d) {
                final data = d.data() as Map<String, dynamic>;
                final address = data['address']?.toString() ?? '';
                if (address.contains("Admin Manual") || address.contains("Admin Override") || address.contains("System Auto Clock Out")) return false;
                return true;
              }).toList();

              if (docs.isEmpty) {
                return Center(child: Text("att.no_history".tr(), style: const TextStyle(color: Colors.grey)));
              }

              return ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: docs.length,
                separatorBuilder: (ctx, i) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final data = docs[index].data() as Map<String, dynamic>;
                  final ts = (data['timestamp'] as Timestamp).toDate();
                  
                  // 🟢 使用 Locale 格式化历史记录日期和时间
                  String displayTime = DateFormat('HH:mm:ss', context.locale.languageCode).format(ts);
                  String displayDate = DateFormat('dd-MM-yyyy', context.locale.languageCode).format(ts);

                  String status = data['verificationStatus'] ?? 'Pending';
                  bool isArchived = status == 'Archived';

                  return Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isArchived ? Colors.grey.shade50 : Colors.white, 
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 3,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(displayDate,
                                  style: TextStyle(
                                      fontWeight: FontWeight.bold, 
                                      fontSize: 13, 
                                      color: isArchived ? Colors.grey : Colors.black54, 
                                  )),
                              Text(displayTime, 
                                  style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                      color: isArchived ? Colors.grey : Colors.black87, 
                                      decoration: isArchived ? TextDecoration.lineThrough : null,
                                  )), 
                            ],
                          ),
                        ),
                        Expanded(
                          flex: 4,
                          child: Text(
                            data['address'] ?? "Unknown",
                            style: TextStyle(
                              fontSize: 12, 
                              color: isArchived ? Colors.grey : const Color(0xFF15438c),
                            ),
                            maxLines: 5,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: _buildStatusIcon(status),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildStatusIcon(String status) {
    if (status == 'Verified' || status == 'Corrected' || status == 'Approved') {
      return const Icon(Icons.check_circle, color: Colors.green, size: 20);
    } else if (status == 'Rejected') {
      return const Icon(Icons.cancel, color: Colors.red, size: 20);
    } else if (status == 'Archived') {
      return const Icon(Icons.history, color: Colors.grey, size: 20); 
    } else {
      return const Icon(Icons.task_alt, color: Colors.black54, size: 20); 
    }
  }
}

// ==========================================
//  Tab 3: Schedule Tab 
// ==========================================

class ScheduleTab extends StatefulWidget {
  const ScheduleTab({super.key});
  @override
  State<ScheduleTab> createState() => _ScheduleTabState();
}

class _ScheduleTabState extends State<ScheduleTab> {
  DateTime _currentStartDate = DateTime.now();
  String? _myEmpCode;
  bool _isFetchingUser = true;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _currentStartDate = now.subtract(Duration(days: now.weekday - 1));
    _fetchEmployeeCode();
  }

  Future<void> _fetchEmployeeCode() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final q = await FirebaseFirestore.instance.collection('users').where('authUid', isEqualTo: user.uid).limit(1).get();
      if (q.docs.isNotEmpty && mounted) {
        setState(() { _myEmpCode = q.docs.first.id; _isFetchingUser = false; });
      } else { if(mounted) setState(() => _isFetchingUser = false); }
    } catch (e) { if(mounted) setState(() => _isFetchingUser = false); }
  }

  void _changeWeek(int weeks) {
    setState(() => _currentStartDate = _currentStartDate.add(Duration(days: 7 * weeks)));
  }

  String _formatDuration(Duration d) {
    int minutes = d.inMinutes;
    int h = minutes ~/ 60;
    int m = minutes % 60;
    return "${h}h ${m}m";
  }

  @override
  Widget build(BuildContext context) {
    if (_isFetchingUser) return const Center(child: CircularProgressIndicator());
    if (_myEmpCode == null) return Center(child: Text("att.err_profile_not_linked".tr()));

    final user = FirebaseAuth.instance.currentUser;
    final endDate = _currentStartDate.add(const Duration(days: 6));
    final startStr = DateFormat('yyyy-MM-dd').format(_currentStartDate);
    final endStr = DateFormat('yyyy-MM-dd').format(endDate);
    
    // 🟢 应用 Locale 到日期范围选择器
    final displayRange = "${DateFormat('dd MMM', context.locale.languageCode).format(_currentStartDate)} - ${DateFormat('dd MMM', context.locale.languageCode).format(endDate)}";

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
          color: Colors.white,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(icon: const Icon(Icons.arrow_back, color: Colors.grey), onPressed: () => _changeWeek(-1)),
              Text(displayRange, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF15438c))),
              IconButton(icon: const Icon(Icons.arrow_forward, color: Colors.grey), onPressed: () => _changeWeek(1)),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance.collection('schedules')
                .where('userId', isEqualTo: _myEmpCode)
                .where('date', isGreaterThanOrEqualTo: startStr)
                .where('date', isLessThanOrEqualTo: endStr)
                .orderBy('date')
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) return const ShimmerLoadingList();
              final scheduleDocs = snapshot.data?.docs ?? [];
              if (scheduleDocs.isEmpty) return Center(child: Text("att.no_shifts".tr(), style: const TextStyle(color: Colors.grey)));
              
              return ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: scheduleDocs.length,
                itemBuilder: (context, index) {
                  final scheduleData = scheduleDocs[index].data() as Map<String, dynamic>;
                  final dateStr = scheduleData['date'] as String;

                  DateTime? schedStart = scheduleData['start'] != null ? (scheduleData['start'] as Timestamp).toDate() : null;
                  DateTime? schedEnd = scheduleData['end'] != null ? (scheduleData['end'] as Timestamp).toDate() : null;

                  return StreamBuilder<QuerySnapshot>(
                    stream: FirebaseFirestore.instance.collection('attendance')
                        .where('uid', isEqualTo: user?.uid)
                        .where('date', isEqualTo: dateStr)
                        .snapshots(),
                    builder: (context, attSnapshot) {
                      String timeIn = "--:--";
                      String timeOut = "--:--";
                      String status = "Absent";
                      Color statusColor = Colors.grey;
                      
                      String lateStr = "0h 0m";
                      String underStr = "0h 0m";
                      String otStr = "0h 0m";
                      
                      bool isAbsent = false;
                      final now = DateTime.now();
                      final scheduleDate = DateTime.parse(dateStr);
                      final today = DateTime(now.year, now.month, now.day);
                      final checkDate = DateTime(scheduleDate.year, scheduleDate.month, scheduleDate.day);
                      
                      if (checkDate.isBefore(today)) {
                         isAbsent = true; 
                      }

                      if (attSnapshot.hasData && attSnapshot.data!.docs.isNotEmpty) {
                        final docs = attSnapshot.data!.docs;
                        final verifiedDocs = docs.where((d) {
                          final data = d.data() as Map<String, dynamic>;
                          return data['verificationStatus'] == 'Verified' || data['verificationStatus'] == 'Corrected';
                        }).toList();
                        
                        if (verifiedDocs.isNotEmpty) {
                            isAbsent = false; 
                        }

                        QueryDocumentSnapshot? clockInDoc;
                        try { clockInDoc = verifiedDocs.firstWhere((d) => (d.data() as Map<String,dynamic>)['session'] == 'Clock In'); } catch (e) { clockInDoc = null; }

                        QueryDocumentSnapshot? clockOutDoc;
                        try { clockOutDoc = verifiedDocs.lastWhere((d) => (d.data() as Map<String,dynamic>)['session'] == 'Clock Out'); } catch (e) { clockOutDoc = null; }

                        QueryDocumentSnapshot? breakOutDoc;
                        try { breakOutDoc = verifiedDocs.lastWhere((d) => (d.data() as Map<String,dynamic>)['session'] == 'Break Out'); } catch (e) { breakOutDoc = null; }

                        if (clockInDoc != null) {
                           final data = clockInDoc.data() as Map<String, dynamic>;
                           final ts = (data['timestamp'] as Timestamp).toDate();
                           
                           timeIn = DateFormat('HH:mm').format(ts);
                           if (schedStart != null && ts.isAfter(schedStart)) {
                             lateStr = _formatDuration(ts.difference(schedStart));
                           }
                           
                           status = "Working";
                           statusColor = Colors.blue;
                        }

                        if (clockOutDoc != null) {
                           final data = clockOutDoc.data() as Map<String, dynamic>;
                           final ts = (data['timestamp'] as Timestamp).toDate();
                           
                           timeOut = DateFormat('HH:mm').format(ts);
                           
                           status = "Present";
                           statusColor = Colors.green;
                           
                           if (schedEnd != null) {
                             if (ts.isAfter(schedEnd)) {
                               otStr = _formatDuration(ts.difference(schedEnd));
                             } else if (ts.isBefore(schedEnd)) {
                               underStr = _formatDuration(schedEnd.difference(ts));
                             }
                           }
                        } else if (breakOutDoc != null) {
                           final data = breakOutDoc.data() as Map<String, dynamic>;
                           final ts = (data['timestamp'] as Timestamp).toDate();
                           timeOut = DateFormat('HH:mm').format(ts);
                        }
                      }

                      return _buildScheduleCard(
                        scheduleData, timeIn, timeOut, status, statusColor, lateStr, underStr, otStr, isAbsent, context
                      );
                    }
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
  
  Widget _buildScheduleCard(Map<String, dynamic> scheduleData, String inTime, String outTime, String status, Color color, String late, String under, String ot, bool isAbsent, BuildContext context) {
    final dateObj = DateTime.parse(scheduleData['date']);
    
    // 🟢 应用 Locale 格式化星期和日期
    final weekDay = DateFormat('EEEE', context.locale.languageCode).format(dateObj);
    final fmtDate = DateFormat('dd/MM/yyyy', context.locale.languageCode).format(dateObj);
    
    String shiftStart = scheduleData['start'] != null ? DateFormat('HH:mm').format((scheduleData['start'] as Timestamp).toDate().toLocal()) : "--:--";
    String shiftEnd = scheduleData['end'] != null ? DateFormat('HH:mm').format((scheduleData['end'] as Timestamp).toDate().toLocal()) : "--:--";

    Color lateColor = late == "0h 0m" ? Colors.black : Colors.red;
    Color underColor = under == "0h 0m" ? Colors.black : Colors.red;

    return Card(
      elevation: 2,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text("${'att.label_shift'.tr()} ($shiftStart - $shiftEnd)", style: const TextStyle(color: Color(0xFF15438c), fontWeight: FontWeight.bold, fontSize: 15)),
                Text("$weekDay ($fmtDate)", style: const TextStyle(color: Colors.blueGrey, fontSize: 13)),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 5,
                  child: Row(
                    children: [
                      Expanded(child: _buildTimeBox("att.label_in".tr(), inTime)),
                      const SizedBox(width: 10),
                      Expanded(child: _buildTimeBox("att.label_out".tr(), outTime)),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  flex: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (status != "Absent" && !isAbsent) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4)),
                          child: Text(status, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.bold)),
                        ),
                        const SizedBox(height: 8),
                      ],
                      _buildStatRow("Late", late, lateColor),
                      const SizedBox(height: 4),
                      _buildStatRow("Under", under, underColor),
                      const SizedBox(height: 4),
                      _buildStatRow("OT", ot, Colors.blue),
                    ],
                  ),
                )
              ],
            ),
            if (isAbsent)
               Container(
                 margin: const EdgeInsets.only(top: 10),
                 padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
                 decoration: BoxDecoration(
                   color: Colors.red.shade50,
                   borderRadius: BorderRadius.circular(4),
                   border: Border.all(color: Colors.red.shade200)
                 ),
                 child: const Text("ABSENT", style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 14, letterSpacing: 1.0)),
               )
          ],
        ),
      ),
    );
  }

  Widget _buildTimeBox(String label, String time) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(color: const Color(0xFFE3F2FD), borderRadius: BorderRadius.circular(8)),
          child: Center(
            child: Text(time, style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF15438c), fontSize: 15)),
          ),
        )
      ],
    );
  }

  Widget _buildStatRow(String label, String value, Color valueColor) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Text("$label: ", style: const TextStyle(fontSize: 11, color: Colors.black)),
        Text(value, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: valueColor)),
      ],
    );
  }
}

// ==========================================
//  Tab 4: Submit Tab
// ==========================================

class SubmitTab extends StatefulWidget {
  const SubmitTab({super.key});
  @override
  State<SubmitTab> createState() => _SubmitTabState();
}

class _SubmitTabState extends State<SubmitTab> {
  DateTime _currentStartDate = DateTime.now();
  String? _myEmpCode;
  bool _isFetchingUser = true;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _currentStartDate = now.subtract(Duration(days: now.weekday - 1));
    _fetchEmployeeCode();
  }

  Future<void> _fetchEmployeeCode() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final q = await FirebaseFirestore.instance.collection('users').where('authUid', isEqualTo: user.uid).limit(1).get();
      if (q.docs.isNotEmpty && mounted) {
        setState(() { _myEmpCode = q.docs.first.id; _isFetchingUser = false; });
      } else { if(mounted) setState(() => _isFetchingUser = false); }
    } catch (e) { if(mounted) setState(() => _isFetchingUser = false); }
  }

  void _changeWeek(int weeks) {
    setState(() => _currentStartDate = _currentStartDate.add(Duration(days: 7 * weeks)));
  }

  String _formatDuration(Duration d) {
    int minutes = d.inMinutes;
    int h = minutes ~/ 60;
    int m = minutes % 60;
    return "${h}h ${m}m";
  }

  @override
  Widget build(BuildContext context) {
    if (_isFetchingUser) return const Center(child: CircularProgressIndicator());
    if (_myEmpCode == null) return Center(child: Text("att.err_profile_not_linked".tr()));

    final user = FirebaseAuth.instance.currentUser;
    final now = DateTime.now();
    
    final originalEndDate = _currentStartDate.add(const Duration(days: 6));
    final endOfToday = DateTime(now.year, now.month, now.day, 23, 59, 59);
    DateTime effectiveEndDate = originalEndDate.isAfter(endOfToday) ? endOfToday : originalEndDate;
    
    final startStr = DateFormat('yyyy-MM-dd').format(_currentStartDate);
    final endStr = DateFormat('yyyy-MM-dd').format(effectiveEndDate);
    
    // 🟢 修正 Tab 日期显示为 Locale aware
    final displayRange = "${DateFormat('dd MMM', context.locale.languageCode).format(_currentStartDate)} - ${DateFormat('dd MMM', context.locale.languageCode).format(originalEndDate)}";
    bool isFutureWeek = _currentStartDate.isAfter(endOfToday);

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
          color: Colors.white,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(icon: const Icon(Icons.arrow_back, color: Colors.grey), onPressed: () => _changeWeek(-1)),
              Text(displayRange, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF15438c))),
              IconButton(icon: const Icon(Icons.arrow_forward, color: Colors.grey), onPressed: () => _changeWeek(1)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8.0),
          child: Text("att.hint_correction".tr(), style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ),
        
        Expanded(
          child: isFutureWeek 
            ? Center(child: Text("att.no_shifts".tr(), style: const TextStyle(color: Colors.grey))) 
            : StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance.collection('schedules')
                .where('userId', isEqualTo: _myEmpCode)
                .where('date', isGreaterThanOrEqualTo: startStr)
                .where('date', isLessThanOrEqualTo: endStr) 
                .orderBy('date')
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) return const ShimmerLoadingList();
              final scheduleDocs = snapshot.data?.docs ?? [];
              if (scheduleDocs.isEmpty) return Center(child: Text("att.no_shifts".tr(), style: const TextStyle(color: Colors.grey)));
              
              return ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: scheduleDocs.length,
                itemBuilder: (context, index) {
                  final scheduleData = scheduleDocs[index].data() as Map<String, dynamic>;
                  final dateStr = scheduleData['date'] as String;
                  
                  DateTime? schedStart = scheduleData['start'] != null ? (scheduleData['start'] as Timestamp).toDate() : null;
                  DateTime? schedEnd = scheduleData['end'] != null ? (scheduleData['end'] as Timestamp).toDate() : null;
                  
                  String? attendanceId; 

                  return StreamBuilder<QuerySnapshot>(
                    stream: FirebaseFirestore.instance.collection('attendance')
                        .where('uid', isEqualTo: user?.uid)
                        .where('date', isEqualTo: dateStr)
                        .snapshots(),
                    builder: (context, attSnapshot) {
                      String timeIn = "--:--";
                      String timeOut = "--:--";
                      
                      String lateStr = "0h 0m";
                      String underStr = "0h 0m";
                      String otStr = "0h 0m";
                      
                      bool isAbsent = false;
                      final now = DateTime.now();
                      final scheduleDate = DateTime.parse(dateStr);
                      final today = DateTime(now.year, now.month, now.day);
                      final checkDate = DateTime(scheduleDate.year, scheduleDate.month, scheduleDate.day);
                      
                      if (checkDate.isBefore(today)) {
                         isAbsent = true; 
                      }

                      if (attSnapshot.hasData && attSnapshot.data!.docs.isNotEmpty) {
                        final docs = attSnapshot.data!.docs;
                        attendanceId = docs.first.id;
                        
                        final verifiedDocs = docs.where((d) {
                          final data = d.data() as Map<String, dynamic>;
                          return data['verificationStatus'] == 'Verified' || data['verificationStatus'] == 'Corrected';
                        }).toList();
                        
                        if (verifiedDocs.isNotEmpty) {
                            isAbsent = false; 
                        }

                        QueryDocumentSnapshot? clockInDoc;
                        try { clockInDoc = verifiedDocs.firstWhere((d) => (d.data() as Map<String,dynamic>)['session'] == 'Clock In'); } catch (e) { clockInDoc = null; }

                        QueryDocumentSnapshot? clockOutDoc;
                        try { clockOutDoc = verifiedDocs.lastWhere((d) => (d.data() as Map<String,dynamic>)['session'] == 'Clock Out'); } catch (e) { clockOutDoc = null; }

                        QueryDocumentSnapshot? breakOutDoc;
                        try { breakOutDoc = verifiedDocs.lastWhere((d) => (d.data() as Map<String,dynamic>)['session'] == 'Break Out'); } catch (e) { breakOutDoc = null; }

                        if (clockInDoc != null) {
                           final data = clockInDoc.data() as Map<String, dynamic>;
                           final ts = (data['timestamp'] as Timestamp).toDate();
                           
                           timeIn = DateFormat('HH:mm').format(ts);
                           if (schedStart != null && ts.isAfter(schedStart)) {
                             lateStr = _formatDuration(ts.difference(schedStart));
                           }
                        }

                        if (clockOutDoc != null) {
                           final data = clockOutDoc.data() as Map<String, dynamic>;
                           final ts = (data['timestamp'] as Timestamp).toDate();
                           
                           timeOut = DateFormat('HH:mm').format(ts);
                           
                           if (schedEnd != null) {
                             if (ts.isAfter(schedEnd)) {
                               otStr = _formatDuration(ts.difference(schedEnd));
                             } else if (ts.isBefore(schedEnd)) {
                               underStr = _formatDuration(schedEnd.difference(ts));
                             }
                           }
                        } else if (breakOutDoc != null) {
                           final data = breakOutDoc.data() as Map<String, dynamic>;
                           final ts = (data['timestamp'] as Timestamp).toDate();
                           timeOut = DateFormat('HH:mm').format(ts);
                        }
                      }

                      return _buildSubmitCard(
                        scheduleData, attendanceId, timeIn, timeOut, lateStr, underStr, otStr, isAbsent, context
                      );
                    }
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildSubmitCard(Map<String, dynamic> scheduleData, String? attendanceId, String inTime, String outTime, String late, String under, String ot, bool isAbsent, BuildContext context) {
    final dateObj = DateTime.parse(scheduleData['date']);
    
    // 🟢 Locale aware formatting
    final weekDay = DateFormat('EEEE', context.locale.languageCode).format(dateObj);
    final fmtDate = DateFormat('dd/MM/yyyy', context.locale.languageCode).format(dateObj);
    
    String shiftStart = scheduleData['start'] != null ? DateFormat('HH:mm').format((scheduleData['start'] as Timestamp).toDate().toLocal()) : "--:--";
    String shiftEnd = scheduleData['end'] != null ? DateFormat('HH:mm').format((scheduleData['end'] as Timestamp).toDate().toLocal()) : "--:--";

    Color lateColor = late == "0h 0m" ? Colors.black : Colors.red;
    Color underColor = under == "0h 0m" ? Colors.black : Colors.red;

    return GestureDetector(
      onTap: () {
        Navigator.push(context, MaterialPageRoute(builder: (_) => CorrectionRequestScreen(
          date: dateObj, 
          attendanceId: attendanceId, 
          originalIn: inTime, 
          originalOut: outTime
        )));
      },
      child: Card(
        elevation: 2,
        margin: const EdgeInsets.only(bottom: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: Colors.blue.withValues(alpha:0.3))),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text("${'att.label_shift'.tr()} ($shiftStart - $shiftEnd)", style: const TextStyle(color: Color(0xFF15438c), fontWeight: FontWeight.bold, fontSize: 15)), 
                  Text("$weekDay ($fmtDate)", style: const TextStyle(color: Colors.blueGrey, fontSize: 13)),
                ],
              ),
              const SizedBox(height: 12),
              
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 5,
                    child: Row(
                      children: [
                        Expanded(child: _buildTimeBox("att.label_in".tr(), inTime)),
                        const SizedBox(width: 10),
                        Expanded(child: _buildTimeBox("att.label_out".tr(), outTime)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    flex: 3,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        const Icon(Icons.edit_note, color: Colors.blue, size: 24),
                        const SizedBox(height: 8),
                        _buildStatRow("Late", late, lateColor),
                        const SizedBox(height: 4),
                        _buildStatRow("Under", under, underColor),
                        const SizedBox(height: 4),
                        _buildStatRow("OT", ot, Colors.blue),
                      ],
                    ),
                  )
                ],
              ),
              if (isAbsent)
               Container(
                 margin: const EdgeInsets.only(top: 10),
                 padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
                 decoration: BoxDecoration(
                   color: Colors.red.shade50,
                   borderRadius: BorderRadius.circular(4),
                   border: Border.all(color: Colors.red.shade200)
                 ),
                 child: const Text("ABSENT", style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 14, letterSpacing: 1.0)),
               )
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTimeBox(String label, String time) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(color: const Color(0xFFE3F2FD), borderRadius: BorderRadius.circular(8)),
          child: Center(
            child: Text(time, style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF15438c), fontSize: 15)),
          ),
        )
      ],
    );
  }

  Widget _buildStatRow(String label, String value, Color valueColor) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Text("$label: ", style: const TextStyle(fontSize: 11, color: Colors.black)),
        Text(value, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: valueColor)),
      ],
    );
  }
}