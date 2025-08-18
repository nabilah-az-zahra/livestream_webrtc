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

  static Function(int frameId)? _onFrameCaptured;
  static Function(int frameId)? _onFrameRendered;

  static bool get isAvailable => Platform.isAndroid;

  static Future<bool> startVideoStream({
    required String streamId,
    List<String> viewers = const [],
  }) async {
    if (!isAvailable) return false;

    try {
      print('[NATIVE_PLUGIN] Starting video stream pipeline...');

      final result = await _channel.invokeMethod('startVideoStream', {
        'streamId': streamId,
        'viewers': viewers,
      });

      if (_eventSubscription == null) {
        print('[NATIVE_PLUGIN] Setting up EventChannel listener...');
        _eventSubscription = _eventChannel.receiveBroadcastStream().listen(
          (event) {
            print('[NATIVE_PLUGIN] RAW EVENT RECEIVED: $event');
            _handleEvent(event);
          },
          onError: (error) {
            print('[NATIVE_PLUGIN] Event stream error: $error');
          },
          onDone: () {
            print('[NATIVE_PLUGIN] Event stream closed');
          },
        );
        print('[NATIVE_PLUGIN] EventChannel listener set up successfully');
      }

      print('[NATIVE_PLUGIN] Video stream pipeline started');
      return result == true;
    } catch (e) {
      print('[NATIVE_PLUGIN] Failed to start video stream: $e');
      return false;
    }
  }

  static Future<bool> stopVideoStream() async {
    if (!isAvailable) return false;

    try {
      print('[NATIVE_PLUGIN] Stopping video stream pipeline...');

      await _eventSubscription?.cancel();
      _eventSubscription = null;

      final result = await _channel.invokeMethod('stopVideoStream');

      print('[NATIVE_PLUGIN] Video stream pipeline stopped');
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

      print('[NATIVE_PLUGIN] Added viewer: $viewerId');
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

      print('[NATIVE_PLUGIN] Removed viewer: $viewerId');
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

      print('[NATIVE_PLUGIN] Updated key for viewer: $viewerId');
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

      print('[NATIVE_PLUGIN] Target FPS set to: $fps');
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

  static Future<bool> recordFrameRendered(int frameId) async {
    if (!isAvailable) return false;

    try {
      final result = await _channel.invokeMethod('recordFrameRendered', {
        'frameId': frameId,
      });

      print('[LATENCY_TEST] Recorded frame rendered: $frameId');
      return result == true;
    } catch (e) {
      print('[LATENCY_TEST] Failed to record frame rendered: $e');
      return false;
    }
  }

  static Future<Map<String, dynamic>?> getLatencyStats() async {
    if (!isAvailable) return null;

    try {
      final result = await _channel.invokeMethod('getLatencyStats');

      if (result is Map<String, dynamic>) {
        print('[LATENCY_TEST] Retrieved latency stats: $result');
        return result;
      }

      return null;
    } catch (e) {
      print('[LATENCY_TEST] Failed to get latency stats: $e');
      return null;
    }
  }

  static void onEncryptedFrame(
    Function(Uint8List data, String viewerId, {int? frameId}) callback,
  ) {
    print('[NATIVE_PLUGIN] Setting encrypted frame callback');
    _onEncryptedFrame = (data, viewerId) {
      callback(data, viewerId);
    };
  }

  static void onFpsUpdate(Function(int fps) callback) {
    print('[NATIVE_PLUGIN] Setting FPS update callback');
    _onFpsUpdate = callback;
  }

  static void onFrameCaptured(Function(int frameId) callback) {
    print('[LATENCY_TEST] Setting frame captured callback');
    _onFrameCaptured = callback;
  }

  static void onFrameRendered(Function(int frameId) callback) {
    print('[LATENCY_TEST] Setting frame rendered callback');
    _onFrameRendered = callback;
  }

  static void _handleEvent(dynamic event) {
    try {
      print('[NATIVE_PLUGIN] Handling event: $event');

      if (event is Map) {
        final type = event['type'] as String?;
        print('[NATIVE_PLUGIN] Event type: $type');

        switch (type) {
          case 'encrypted_frame':
            final data = event['data'];
            final viewerId = event['viewerId'] as String?;
            final frameId = event['frameId'] as int?;

            print('[NATIVE_PLUGIN] Processing encrypted_frame event');
            print('[NATIVE_PLUGIN] Data type: ${data.runtimeType}');
            print('[NATIVE_PLUGIN] ViewerId: $viewerId');
            print('[LATENCY_TEST] FrameId: $frameId');

            if (data != null && viewerId != null) {
              Uint8List bytes;
              if (data is List<int>) {
                bytes = Uint8List.fromList(data);
              } else if (data is Uint8List) {
                bytes = data;
              } else {
                print('[NATIVE_PLUGIN] Invalid data type: ${data.runtimeType}');
                return;
              }

              print(
                  '[NATIVE_PLUGIN] Calling encrypted frame callback with ${bytes.length} bytes for $viewerId');

              if (_onEncryptedFrame != null) {
                if (frameId != null) {
                  _onEncryptedFrame!(bytes, viewerId);
                } else {
                  _onEncryptedFrame!(bytes, viewerId);
                }
              } else {
                print('[NATIVE_PLUGIN] No encrypted frame callback set!');
              }
            } else {
              print(
                  '[NATIVE_PLUGIN] Missing data or viewerId in encrypted_frame event');
            }
            break;

          case 'fps_update':
            final fps = event['fps'] as int?;
            print('[NATIVE_PLUGIN] Processing fps_update event: $fps');

            if (fps != null && _onFpsUpdate != null) {
              _onFpsUpdate!(fps);
            }
            break;

          case 'frame_captured':
            final frameId = event['frameId'] as int?;
            print('[LATENCY_TEST] Frame captured event: $frameId');

            if (frameId != null && _onFrameCaptured != null) {
              _onFrameCaptured!(frameId);
            }
            break;

          case 'frame_rendered':
            final frameId = event['frameId'] as int?;
            print('[LATENCY_TEST] Frame rendered event: $frameId');

            if (frameId != null && _onFrameRendered != null) {
              _onFrameRendered!(frameId);
            }
            break;

          default:
            print('[NATIVE_PLUGIN] Unknown event type: $type');
        }
      } else {
        print('[NATIVE_PLUGIN] Event is not a Map: ${event.runtimeType}');
      }
    } catch (e) {
      print('[NATIVE_PLUGIN] Error handling event: $e');
      print('[NATIVE_PLUGIN] Event was: $event');
    }
  }

  static Future<Uint8List> convertYUV420ToJPEG(CameraImage image) async {
    if (!isAvailable) {
      throw UnsupportedError('Native video plugin only supports Android');
    }

    try {
      print('[NATIVE_PLUGIN] Starting YUV420 conversion...');

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
      final bytes = Uint8List.fromList(List<int>.from(result));

      print(
        '[NATIVE_PLUGIN] YUV420 conversion completed: ${bytes.length} bytes',
      );
      return bytes;
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
      print('[NATIVE_PLUGIN] Starting image compression...');

      final Map<String, dynamic> params = {
        'imageBytes': imageBytes,
        'targetWidth': targetWidth,
        'targetHeight': targetHeight,
        'quality': quality,
      };

      final result = await _channel.invokeMethod('compressImage', params);
      final bytes = Uint8List.fromList(List<int>.from(result));

      print(
        '[NATIVE_PLUGIN] Image compression completed: ${bytes.length} bytes',
      );
      return bytes;
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
      print('[NATIVE_PLUGIN] Starting frame encryption...');

      final Map<String, dynamic> params = {
        'frameBytes': frameBytes,
        'aesKey': aesKey,
        'streamId': streamId,
        'timestamp': timestamp,
      };

      final result = await _channel.invokeMethod('encryptFrame', params);
      final bytes = Uint8List.fromList(List<int>.from(result));

      print(
        '[NATIVE_PLUGIN] Frame encryption completed: ${bytes.length} bytes',
      );
      return bytes;
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
    int? frameId,
  }) async {
    try {
      final result = await _channel.invokeMethod('decryptFrame', {
        'encrypted': encrypted,
        'aesKey': aesKey,
        'nonce': nonce,
        'streamId': streamId,
        'timestamp': timestamp,
        'frameId': frameId,
      });
      return result as Uint8List;
    } on PlatformException catch (e) {
      throw Exception('Native decryption failed: ${e.message}');
    }
  }

  static int? extractFrameId(Uint8List payload) {
    try {
      if (payload.length >= 12 + 8) {
        final frameId =
            payload.buffer.asByteData().getUint64(payload.length - 8);
        return frameId;
      }
    } catch (e) {
      print('[LATENCY_TEST] Failed to extract frameId: $e');
    }
    return null;
  }

  static void printLatencyStats(Map<String, dynamic> stats) {
    print('\n LATENCY TEST RESULTS');
    print('Total frames tested: ${stats['totalFramesTested'] ?? 'N/A'}');
    print(
        'Average latency: ${stats['averageLatencyMs']?.toStringAsFixed(2) ?? 'N/A'} ms');
    print(
        'Median latency: ${stats['medianLatencyMs']?.toStringAsFixed(2) ?? 'N/A'} ms');
    print(
        'Min latency: ${stats['minLatencyMs']?.toStringAsFixed(2) ?? 'N/A'} ms');
    print(
        'Max latency: ${stats['maxLatencyMs']?.toStringAsFixed(2) ?? 'N/A'} ms');
    print(
        '95th percentile: ${stats['p95LatencyMs']?.toStringAsFixed(2) ?? 'N/A'} ms');
    print(
        '99th percentile: ${stats['p99LatencyMs']?.toStringAsFixed(2) ?? 'N/A'} ms');
    print('\n');
  }

  static Future<bool> startEntropyTest() async {
    if (!isAvailable) return false;

    try {
      final result = await _channel.invokeMethod('startEntropyTest');
      print('[ENTROPY_TEST] Entropy testing started');
      return result == true;
    } catch (e) {
      print('[ENTROPY_TEST] Failed to start entropy test: $e');
      return false;
    }
  }

  static Future<dynamic> stopEntropyTest() async {
    if (!isAvailable) return false;

    try {
      final result = await _channel.invokeMethod('stopEntropyTest');
      print('[ENTROPY_TEST] Entropy testing stopped');
      return result;
    } catch (e) {
      print('[ENTROPY_TEST] Failed to stop entropy test: $e');
      return false;
    }
  }

  static Future<Map<String, dynamic>?> getEntropyTestStats() async {
    if (!isAvailable) return null;

    try {
      final result = await _channel.invokeMethod('getEntropyTestStats');
      if (result is Map<String, dynamic>) {
        return result;
      }
      return null;
    } catch (e) {
      print('[ENTROPY_TEST] Failed to get entropy stats: $e');
      return null;
    }
  }
}
