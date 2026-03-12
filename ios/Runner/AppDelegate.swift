import Flutter
import UIKit
// 🟢 1. 引入 Google Maps 库
import GoogleMaps

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    
    // 🟢 2. 配置 iOS 专用的 API Key
    GMSServices.provideAPIKey("AIzaSyDggQmKVTngNmq1-C_GJ64Tq9LqkCiBsuI")
    
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}