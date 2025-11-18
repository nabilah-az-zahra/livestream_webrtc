import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'dart:io' show Platform;
import 'dart:async';

class NativeVideoPlugin {
  static const MethodChannel _channel = MethodChannel('native_video_plugin');
  static const EventChannel _eventChannel = EventChannel(
    'native_video_plugin/stream',
  );

  static StreamSubscription<dynamic>? _eventSubscription;
  static Function(Uint8List data, String viewerId)? _onEncryptedFrame;
  static Function(int fps)? _onFpsUpdate;

  static bool get isAvailable => Platform.isAndroid;

  static Future<bool> startVideoStream({
    required String streamId,
    List<String> viewers = const [],
  }) async {
    if (!isAvailable) return false;

    try {
      final result = await _channel.invokeMethod('startVideoStream', {
        'streamId': streamId,
        'viewers': viewers,
      });

      _eventSubscription ??= _eventChannel.receiveBroadcastStream().listen(
        (event) {
          _handleEvent(event);
        },
        onError: (error) {
          print('[NATIVE_PLUGIN] Event stream error: $error');
        },
      );

      return result == true;
    } catch (e) {
      print('[NATIVE_PLUGIN] Failed to start video stream: $e');
      return false;
    }
  }

  static Future<bool> stopVideoStream() async {
    if (!isAvailable) return false;

    try {
      await _eventSubscription?.cancel();
      _eventSubscription = null;

      final result = await _channel.invokeMethod('stopVideoStream');
      return result == true;
    } catch (e) {
      print('[NATIVE_PLUGIN] Failed to stop video stream: $e');
      return false;
    }
  }

  static Future<bool> addViewer({
    required String viewerId,
    Uint8List? aesKey,
  }) async {
    if (!isAvailable) return false;

    try {
      final result = await _channel.invokeMethod('addViewer', {
        'viewerId': viewerId,
        'aesKey': aesKey,
      });

      return result == true;
    } catch (e) {
      print('[NATIVE_PLUGIN] Failed to add viewer: $e');
      return false;
    }
  }

  static Future<bool> removeViewer(String viewerId) async {
    if (!isAvailable) return false;

    try {
      final result = await _channel.invokeMethod('removeViewer', {
        'viewerId': viewerId,
      });

      return result == true;
    } catch (e) {
      print('[NATIVE_PLUGIN] Failed to remove viewer: $e');
      return false;
    }
  }

  static Future<bool> updateViewerKey({
    required String viewerId,
    required Uint8List aesKey,
  }) async {
    if (!isAvailable) return false;

    try {
      final result = await _channel.invokeMethod('updateViewerKey', {
        'viewerId': viewerId,
        'aesKey': aesKey,
      });

      return result == true;
    } catch (e) {
      print('[NATIVE_PLUGIN] Failed to update viewer key: $e');
      return false;
    }
  }

  static Future<bool> setTargetFPS(int fps) async {
    if (!isAvailable) return false;

    try {
      final result = await _channel.invokeMethod('setTargetFPS', {'fps': fps});
      return result == true;
    } catch (e) {
      print('[NATIVE_PLUGIN] Failed to set target FPS: $e');
      return false;
    }
  }

  static Future<bool> processFrame(CameraImage image) async {
    if (!isAvailable) return false;

    try {
      final result = await _channel.invokeMethod('processFrame', {
        'width': image.width,
        'height': image.height,
        'yPlane': image.planes[0].bytes,
        'uPlane': image.planes[1].bytes,
        'vPlane': image.planes[2].bytes,
        'yRowStride': image.planes[0].bytesPerRow,
        'uvRowStride': image.planes[1].bytesPerRow,
        'uvPixelStride': image.planes[1].bytesPerPixel ?? 1,
      });

      return result == true;
    } catch (e) {
      print('[NATIVE_PLUGIN] Failed to process frame: $e');
      return false;
    }
  }

  static void onEncryptedFrame(
    Function(Uint8List data, String viewerId) callback,
  ) {
    _onEncryptedFrame = callback;
  }

  static void onFpsUpdate(Function(int fps) callback) {
    _onFpsUpdate = callback;
  }

  static void _handleEvent(dynamic event) {
    try {
      if (event is Map) {
        final type = event['type'] as String?;

        switch (type) {
          case 'encrypted_frame':
            final data = event['data'];
            final viewerId = event['viewerId'] as String?;

            if (data != null && viewerId != null) {
              Uint8List bytes;
              if (data is List<int>) {
                bytes = Uint8List.fromList(data);
              } else if (data is Uint8List) {
                bytes = data;
              } else {
                return;
              }

              _onEncryptedFrame?.call(bytes, viewerId);
            }
            break;

          case 'fps_update':
            final fps = event['fps'] as int?;
            if (fps != null) {
              _onFpsUpdate?.call(fps);
            }
            break;
        }
      }
    } catch (e) {
      print('[NATIVE_PLUGIN] Error handling event: $e');
    }
  }

  static Future<Uint8List> convertYUV420ToJPEG(CameraImage image) async {
    if (!isAvailable) {
      throw UnsupportedError('Native video plugin only supports Android');
    }

    try {
      final Map<String, dynamic> params = {
        'width': image.width,
        'height': image.height,
        'yPlane': image.planes[0].bytes,
        'uPlane': image.planes[1].bytes,
        'vPlane': image.planes[2].bytes,
        'yRowStride': image.planes[0].bytesPerRow,
        'uvRowStride': image.planes[1].bytesPerRow,
        'uvPixelStride': image.planes[1].bytesPerPixel ?? 1,
      };

      final result = await _channel.invokeMethod('convertYUV420ToJPEG', params);
      return Uint8List.fromList(List<int>.from(result));
    } catch (e) {
      print('[NATIVE_PLUGIN] YUV420 conversion error: $e');
      rethrow;
    }
  }

  static Future<Uint8List> compressImage({
    required Uint8List imageBytes,
    required int targetWidth,
    required int targetHeight,
    required int quality,
  }) async {
    if (!isAvailable) {
      throw UnsupportedError('Native video plugin only supports Android');
    }

    try {
      final Map<String, dynamic> params = {
        'imageBytes': imageBytes,
        'targetWidth': targetWidth,
        'targetHeight': targetHeight,
        'quality': quality,
      };

      final result = await _channel.invokeMethod('compressImage', params);
      return Uint8List.fromList(List<int>.from(result));
    } catch (e) {
      print('[NATIVE_PLUGIN] Image compression error: $e');
      rethrow;
    }
  }

  static Future<Uint8List> encryptFrame({
    required Uint8List frameBytes,
    required Uint8List aesKey,
    required String streamId,
    required int timestamp,
  }) async {
    if (!isAvailable) {
      throw UnsupportedError('Native video plugin only supports Android');
    }

    try {
      final Map<String, dynamic> params = {
        'frameBytes': frameBytes,
        'aesKey': aesKey,
        'streamId': streamId,
        'timestamp': timestamp,
      };

      final result = await _channel.invokeMethod('encryptFrame', params);
      return Uint8List.fromList(List<int>.from(result));
    } catch (e) {
      print('[NATIVE_PLUGIN] Frame encryption error: $e');
      rethrow;
    }
  }

  static Future<Uint8List> decryptFrame({
    required Uint8List encrypted,
    required Uint8List aesKey,
    required Uint8List nonce,
    required String streamId,
    required int timestamp,
  }) async {
    try {
      final result = await _channel.invokeMethod('decryptFrame', {
        'encrypted': encrypted,
        'aesKey': aesKey,
        'nonce': nonce,
        'streamId': streamId,
        'timestamp': timestamp,
      });
      return result as Uint8List;
    } on PlatformException catch (e) {
      throw Exception('Native decryption failed: ${e.message}');
    }
  }
}
