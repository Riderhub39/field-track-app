class UserModel {
  final String uid;
  final String phoneNumber;
  final String name;
  final String role; // 'admin' or 'staff'
  final bool isActive;
  final DateTime? lastCheckIn;

  UserModel({
    required this.uid,
    required this.phoneNumber,
    this.name = '',
    this.role = 'staff', // Default role is staff
    this.isActive = true,
    this.lastCheckIn,
  });

  // Convert a Map (from Firestore) into a UserModel object
  factory UserModel.fromMap(Map<String, dynamic> map) {
    return UserModel(
      uid: map['uid'] ?? '',
      phoneNumber: map['phoneNumber'] ?? '',
      name: map['name'] ?? '',
      role: map['role'] ?? 'staff',
      isActive: map['isActive'] ?? true,
      lastCheckIn: map['lastCheckIn'] != null 
          ? DateTime.fromMillisecondsSinceEpoch(map['lastCheckIn']) 
          : null,
    );
  }

  // Convert a UserModel object into a Map to save to Firestore
  Map<String, dynamic> toMap() {
    return {
      'uid': uid,
      'phoneNumber': phoneNumber,
      'name': name,
      'role': role,
      'isActive': isActive,
      'lastCheckIn': lastCheckIn?.millisecondsSinceEpoch,
    };
  }
}