import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;
import 'package:flutter/foundation.dart';

class ImageConverter {
  /// 异步将 CameraImage 转换为 img.Image (RGB)
  /// 🚀 自动识别平台格式：支持 Android (YUV420) 和 iOS (BGRA8888)
  /// 使用 compute 放入独立 Isolate 运行，解决 UI 卡顿问题
  static Future<img.Image?> convertCameraImageToImageAsync(CameraImage image) async {
    try {
      // ==========================================
      // 🟢 1. 处理 Android 默认的 YUV420 格式 (保留原有逻辑)
      // ==========================================
      if (image.format.group == ImageFormatGroup.yuv420) {
        // 提取核心数据用于跨 Isolate 传递
        final args = _YuvConversionArgs(
          width: image.width,
          height: image.height,
          plane0Bytes: image.planes[0].bytes,
          plane1Bytes: image.planes[1].bytes,
          plane2Bytes: image.planes[2].bytes,
          uvRowStride: image.planes[1].bytesPerRow,
          uvPixelStride: image.planes[1].bytesPerPixel ?? 1,
        );
        // 将计算任务派发给后台 Isolate
        return await compute(_convertYUV420InIsolate, args);
      } 
      // ==========================================
      // 🍎 2. 处理 iOS 默认的 BGRA8888 格式 (新增逻辑)
      // ==========================================
      else if (image.format.group == ImageFormatGroup.bgra8888) {
        final args = _BgraConversionArgs(
          width: image.width,
          height: image.height,
          bytes: image.planes[0].bytes, // iOS 的 BGRA 格式只有一个 plane
        );
        return await compute(_convertBGRA8888InIsolate, args);
      }

      debugPrint("❌ Unsupported image format: ${image.format.group}");
      return null;
    } catch (e) {
      debugPrint("Conversion Error: $e");
      return null;
    }
  }
}

// ==========================================
//  后台 Isolate 处理区
// ==========================================

// ------------------------------------------
// 🟢 Android (YUV420) 专用数据结构与处理逻辑 (完全保留)
// ------------------------------------------

/// 传递给 Isolate 的数据包 (YUV)
class _YuvConversionArgs {
  final int width;
  final int height;
  final Uint8List plane0Bytes;
  final Uint8List plane1Bytes;
  final Uint8List plane2Bytes;
  final int uvRowStride;
  final int uvPixelStride;

  _YuvConversionArgs({
    required this.width,
    required this.height,
    required this.plane0Bytes,
    required this.plane1Bytes,
    required this.plane2Bytes,
    required this.uvRowStride,
    required this.uvPixelStride,
  });
}

/// 顶级函数：在独立 Isolate 中执行 YUV 转 RGB (Android 原有完美逻辑)
img.Image? _convertYUV420InIsolate(_YuvConversionArgs args) {
  try {
    var imgBuffer = img.Image(width: args.width, height: args.height);

    for (int y = 0; y < args.height; y++) {
      for (int x = 0; x < args.width; x++) {
        final int uvIndex = (args.uvPixelStride * (x / 2).floor()) + (args.uvRowStride * (y / 2).floor());
        final int index = y * args.width + x;

        final yp = args.plane0Bytes[index];
        final up = args.plane1Bytes[uvIndex];
        final vp = args.plane2Bytes[uvIndex];

        // YUV 转 RGB 公式
        int r = (yp + (vp - 128) * 1.402).toInt();
        int g = (yp - (up - 128) * 0.34414 - (vp - 128) * 0.71414).toInt();
        int b = (yp + (up - 128) * 1.772).toInt();

        // 限制范围 0-255
        r = r.clamp(0, 255);
        g = g.clamp(0, 255);
        b = b.clamp(0, 255);

        imgBuffer.setPixelRgb(x, y, r, g, b);
      }
    }
    return imgBuffer;
  } catch (e) {
    debugPrint("Isolate Conversion Error: $e");
    return null;
  }
}

// ------------------------------------------
// 🍎 iOS (BGRA8888) 专用数据结构与处理逻辑 (新增)
// ------------------------------------------

/// 传递给 Isolate 的数据包 (BGRA)
class _BgraConversionArgs {
  final int width;
  final int height;
  final Uint8List bytes;

  _BgraConversionArgs({
    required this.width,
    required this.height,
    required this.bytes,
  });
}

/// 顶级函数：在独立 Isolate 中执行 BGRA 读取 (iOS 极速转换逻辑)
img.Image? _convertBGRA8888InIsolate(_BgraConversionArgs args) {
  try {
    // BGRA 格式可以直接利用 image 库底层接口快速读取，性能极高
    return img.Image.fromBytes(
      width: args.width,
      height: args.height,
      bytes: args.bytes.buffer,
      order: img.ChannelOrder.bgra, 
    );
  } catch (e) {
    debugPrint("BGRA Conversion Error: $e");
    return null;
  }
}