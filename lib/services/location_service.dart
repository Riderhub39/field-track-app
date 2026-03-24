import 'dart:io'; // 引入 Platform
import 'package:geolocator/geolocator.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

class LocationService {
  // Update your getOfficeLocation method to use these keys:
  Future<Map<String, double>?> getOfficeLocation() async {
    try {
      DocumentSnapshot doc = await FirebaseFirestore.instance
          .collection('settings')
          .doc('office_location')
          .get();

      if (doc.exists) {
        final data = doc.data() as Map<String, dynamic>;
        return {
          // Use 'latitude' and 'longitude' instead of 'lat' and 'lng'
          'lat': (data['latitude'] as num).toDouble(), 
          'lng': (data['longitude'] as num).toDouble(),
          'radius': (data['radius'] as num).toDouble(),
        };
      }
    } catch (e) {
      debugPrint("Error fetching office location: $e");
    }
    return null;
  }

  Future<Position> getCurrentLocation() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.deniedForever) {
        return Future.error('Location permissions are permanently denied.');
      }
    }
    
    LocationSettings locationSettings;

    if (Platform.isIOS) {
      // 🟢 仅针对 iOS 添加的特殊配置，确保后台定位存活
      locationSettings = AppleSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 100,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: true, 
      );
    } else {
      // 🟢 保持 Android (及其他平台) 的原有逻辑完全不变
      locationSettings = const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 100,
      );
    }

    return await Geolocator.getCurrentPosition(
      locationSettings: locationSettings,
    );
  }

  bool isWithinRange(Position staffPos, double officeLat, double officeLng, double radius) {
    double distance = Geolocator.distanceBetween(
      staffPos.latitude,
      staffPos.longitude,
      officeLat,
      officeLng,
    );
    return distance <= radius;
  }
}