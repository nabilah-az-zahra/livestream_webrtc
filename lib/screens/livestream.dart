import 'dart:async';
import 'dart:convert';
import 'dart:math';
// import 'dart:math' as math;
// import 'dart:ui' as ui;
import 'package:camera/camera.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
// import 'package:image/image.dart' as img;
import 'package:livekit_client/livekit_client.dart';
import 'package:livestream_webrtc/main.dart';
import 'package:livestream_webrtc/livekit_service.dart';
import 'package:livestream_webrtc/exchange_service.dart';
import 'package:livestream_webrtc/e2ee_service.dart';
import 'package:livestream_webrtc/native_video_plugin.dart';

class LiveStreamPage extends StatefulWidget {
  final String streamTitle;
  final String streamId;
  final bool isStreamer;
  final String streamerId;
  final String streamerUsername;
  final String liveKitUrl;

  const LiveStreamPage({
    super.key,
    required this.streamTitle,
    required this.streamId,
    required this.isStreamer,
    required this.streamerId,
    required this.streamerUsername,
    required this.liveKitUrl,
  });

  @override
  State<LiveStreamPage> createState() => _LiveStreamPageState();
}

class ChatMessage {
  final String userId;
  final String message;
  final String username;
  final Color userColor;
  final Timestamp timestamp;

  ChatMessage({
    required this.userId,
    required this.message,
    required this.username,
    required this.userColor,
    required this.timestamp,
  });

  Map<String, dynamic> toMap() {
    return {
      'userId': userId,
      'message': message,
      'username': username,
      'userColor': userColor.value,
      'timestamp': timestamp,
    };
  }

  factory ChatMessage.fromDocument(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return ChatMessage(
      userId: data['userId'],
      message: data['message'],
      username: data['username'],
      userColor: Color(data['userColor']),
      timestamp: data['timestamp'],
    );
  }
}

class LatencyTracker {
  final Map<int, int> _frameCaptureTimestamps = {};
  final Map<int, int> _frameRenderTimestamps = {};
  final List<double> _latencySamples = [];

  Timer? _cleanupTimer;
  Timer? _statsTimer;

  void start() {
    _cleanupTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _cleanup();
    });

    _statsTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _printCurrentStats();
    });

    print('[LATENCY_TRACKER] Started with cleanup and stats timers');
  }

  void stop() {
    _cleanupTimer?.cancel();
    _statsTimer?.cancel();
    _frameCaptureTimestamps.clear();
    _frameRenderTimestamps.clear();
    print('[LATENCY_TRACKER] Stopped and cleaned up');
  }

  void recordFrameCaptured(int frameId) {
    final captureTime = DateTime.now().millisecondsSinceEpoch;
    _frameCaptureTimestamps[frameId] = captureTime;
    print(
        '[LATENCY_TRACKER] DART: Frame captured with ID=$frameId at timestamp=$captureTime');
  }

  void recordFrameRendered(int frameId) {
    final renderTime = DateTime.now().millisecondsSinceEpoch;
    _frameRenderTimestamps[frameId] = renderTime;

    final captureTime = _frameCaptureTimestamps[frameId];
    if (captureTime != null) {
      final latency = (renderTime - captureTime).toDouble();
      if (latency > 0 && latency < 10000) {
        _latencySamples.add(latency);
        print(
            '[LATENCY_TRACKER] DART: E2E Latency for frame $frameId: ${latency.toStringAsFixed(2)}ms');
        print(
            '[LATENCY_TRACKER] Capture: $captureTime, Render: $renderTime, Latency: ${latency.toStringAsFixed(2)}ms');

        if (_latencySamples.length > 100) {
          _latencySamples.removeAt(0);
        }
      } else {
        print(
            '[LATENCY_TRACKER] Invalid latency for frame $frameId: ${latency}ms');
      }
    } else {
      print('[LATENCY_TRACKER] No capture timestamp for frame $frameId');
      print(
          '[LATENCY_TRACKER] Available capture frames: ${_frameCaptureTimestamps.keys.take(5).toList()}');
    }
  }

  void _cleanup() {
    final now = DateTime.now().millisecondsSinceEpoch;
    const maxAge = 60000;

    final captureCountBefore = _frameCaptureTimestamps.length;
    final renderCountBefore = _frameRenderTimestamps.length;

    _frameCaptureTimestamps
        .removeWhere((_, timestamp) => now - timestamp > maxAge);
    _frameRenderTimestamps
        .removeWhere((_, timestamp) => now - timestamp > maxAge);

    final captureCountAfter = _frameCaptureTimestamps.length;
    final renderCountAfter = _frameRenderTimestamps.length;

    print(
        '[LATENCY_TRACKER] Cleanup: Capture $captureCountBeforeâ†’$captureCountAfter, Render $renderCountBeforeâ†’$renderCountAfter');
  }

  void _printCurrentStats() {
    if (_latencySamples.isEmpty) {
      print(
          '[LATENCY_TRACKER] No latency samples yet. Captures: ${_frameCaptureTimestamps.length}, Renders: ${_frameRenderTimestamps.length}');
      return;
    }

    final sortedSamples = List<double>.from(_latencySamples)..sort();
    final avg = sortedSamples.reduce((a, b) => a + b) / sortedSamples.length;
    final median = sortedSamples[sortedSamples.length ~/ 2];
    final p95 = sortedSamples[(sortedSamples.length * 0.95).toInt()];

    print('\n [DART REALTIME LATENCY STATS] Samples: ${sortedSamples.length}');
    print('   Average: ${avg.toStringAsFixed(2)}ms');
    print('   Median: ${median.toStringAsFixed(2)}ms');
    print('   95th percentile: ${p95.toStringAsFixed(2)}ms');
    print('   Captures tracked: ${_frameCaptureTimestamps.length}');
    print('   Renders tracked: ${_frameRenderTimestamps.length}\n');
  }

  Map<String, double> getCurrentStats() {
    if (_latencySamples.isEmpty) return {};

    final sortedSamples = List<double>.from(_latencySamples)..sort();
    return {
      'samples': sortedSamples.length.toDouble(),
      'average': sortedSamples.reduce((a, b) => a + b) / sortedSamples.length,
      'median': sortedSamples[sortedSamples.length ~/ 2],
      'min': sortedSamples.first,
      'max': sortedSamples.last,
      'p95': sortedSamples[(sortedSamples.length * 0.95).toInt()],
      'p99': sortedSamples[(sortedSamples.length * 0.99).toInt()],
    };
  }
}

class FrameBuffer {
  Uint8List? _latestFrame;
  int _latestFrameId = 0;
  bool _isProcessing = false;

  void updateFrame(Uint8List frame, int frameId) {
    // Always keep only the LATEST frame
    if (frameId > _latestFrameId && !_isProcessing) {
      _latestFrame = frame;
      _latestFrameId = frameId;
    }
  }

  Uint8List? consumeLatestFrame() {
    if (_latestFrame != null) {
      _isProcessing = true;
      final frame = _latestFrame;
      _latestFrame = null; // Clear after consuming
      return frame;
    }
    return null;
  }

  void setProcessingComplete() {
    _isProcessing = false;
  }
}

Future<Uint8List> _isolateDecryptFrame(Map<String, dynamic> params) async {
  try {
    final Uint8List encrypted = params['encrypted'];
    final Uint8List aesKey = params['aesKey'];
    final Uint8List nonce = params['nonce'];
    final String streamId = params['streamId'];
    final int timestamp = params['timestamp'];

    print('[ISOLATE_DECRYPT] Starting Dart decryption...');
    print('[ISOLATE_DECRYPT] Parameters:');
    print('  - encrypted.length: ${encrypted.length}');
    print('  - aesKey.length: ${aesKey.length}');
    print('  - nonce.length: ${nonce.length}');
    print('  - streamId: $streamId');
    print('  - timestamp: $timestamp');

    final aad = StreamCryptoService.buildAad(streamId, timestamp);
    print('[ISOLATE_DECRYPT] AAD: ${utf8.decode(aad)}');

    final cipher =
        StreamCryptoService.createAesGcmCipher(false, aesKey, nonce, aad: aad);
    final decrypted = cipher.process(encrypted);

    print('[ISOLATE_DECRYPT] Decryption successful: ${decrypted.length} bytes');
    return decrypted;
  } catch (e, stackTrace) {
    print('[ISOLATE_DECRYPT] Decryption failed: $e');
    print('[ISOLATE_DECRYPT] Stack trace: $stackTrace');
    rethrow;
  }
}

class _LiveStreamPageState extends State<LiveStreamPage> {
  final GlobalKey _previewContainerKey = GlobalKey();
  final Map<String, Uint8List?> _cachedKeys = {};
  final LiveKitService _liveKitService = LiveKitService();
  final Set<String> _connectedViewers = {};
  final Map<int, Map<int, Uint8List>> _frameChunks = {};
  final Map<int, int> _expectedChunks = {};
  late CameraController _cameraController;
  Widget? _cameraPreviewWidget;

  Timer? _keyRotationTimer;
  Timer? _fpsTimer;
  Uint8List? _currentFrame;

  bool _isImageStreamActive = false;

  bool _useNativePipeline = true;
  bool _nativePipelineActive = false;
  double _nativeFPS = 0.0;
  Timer? _nativeStatsTimer;

  int _viewerFramesReceived = 0;
  double _viewerFPS = 0.0;

  Timer? _audioDelayTimer;
  bool _audioPublished = false;
  LocalAudioTrack? _pendingAudioTrack;

  final LatencyTracker _latencyTracker = LatencyTracker();
  bool _latencyTestEnabled = true;
  Timer? _latencyStatsTimer;
  Map<String, double> _currentLatencyStats = {};

  final FrameBuffer _frameBuffer = FrameBuffer();
  Timer? _renderTimer;

  bool _entropyTestEnabled = false;
  Timer? _entropyTestTimer;
  Map<String, dynamic> _entropyStats = {};

  bool _isLoading = true;
  bool _hasError = false;
  bool _remoteVideoConnected = false;
  bool _isDisposed = false;
  bool _isEncryptionReady = false;

  StreamSubscription? _streamStatusSubscription;
  StreamSubscription? _chatSubscription;

  List<ChatMessage> chatMessages = [];

  final TextEditingController _chatController = TextEditingController();
  final FocusNode _chatFocusNode = FocusNode();

  final Map<String, Color> _userColors = {};

  @override
  void initState() {
    super.initState();
    _useNativePipeline = true;

    if (FirebaseAuth.instance.currentUser != null) {
      _initializeStream();
      _setupKeyRotation();
      _listenToStreamStatus();
      _initializeChat();
      _startFPSMonitoring();

      if (_latencyTestEnabled) {
        _initializeLatencyTesting();
      }

      if (!widget.isStreamer) {
        _preloadViewerKey();
      }

      if (NativeVideoPlugin.isAvailable) {
        _initializeNativePipeline();
      } else {
        setState(() {
          _hasError = true;
        });
      }
    } else {
      Navigator.pushReplacementNamed(context, '/login');
    }
  }

  void _initializeLatencyTesting() {
    print('[LATENCY_TEST] Initializing end-to-end latency testing...');

    _latencyTracker.start();

    _latencyStatsTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
      final nativeStats = await NativeVideoPlugin.getLatencyStats();
      final dartStats = _latencyTracker.getCurrentStats();

      setState(() {
        _currentLatencyStats = dartStats;
      });

      if (nativeStats != null && nativeStats.isNotEmpty) {
        print('\n [NATIVE LATENCY STATS]');
        NativeVideoPlugin.printLatencyStats(nativeStats);
      }

      if (dartStats.isNotEmpty) {
        print('\n [DART LATENCY STATS]');
        print('Samples: ${dartStats['samples']?.toInt()}');
        print('Average: ${dartStats['average']?.toStringAsFixed(2)}ms');
        print('Median: ${dartStats['median']?.toStringAsFixed(2)}ms');
        print('95th percentile: ${dartStats['p95']?.toStringAsFixed(2)}ms');
      }
    });

    print('[LATENCY_TEST] Latency testing initialized');
  }

  Future<void> _initializeNativePipeline() async {
    try {
      print('[NATIVE_PIPELINE] Initializing native video pipeline...');
      print('[NATIVE_PIPELINE] Setting up callbacks...');

      NativeVideoPlugin.onEncryptedFrame((data, viewerId, {frameId}) {
        print(
            '[NATIVE_HANDLER] RECEIVED encrypted frame for $viewerId: ${data.length} bytes');
        _handleNativeEncryptedFrame(data, viewerId);
      });

      NativeVideoPlugin.onFpsUpdate((fps) {
        print('[NATIVE_HANDLER] FPS update: $fps');
        if (mounted) {
          setState(() {
            _nativeFPS = fps.toDouble();
          });
        }
      });

      await NativeVideoPlugin.setTargetFPS(30);

      print('[NATIVE_PIPELINE] Native pipeline initialized successfully');
    } catch (e) {
      print('[NATIVE_PIPELINE] Failed to initialize: $e');
      _useNativePipeline = false;
    }
  }

  void _startFPSMonitoring() {
    _fpsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (widget.isStreamer) {
        print(
            '[NATIVE_FPS] Native pipeline: ${_nativeFPS.toStringAsFixed(1)}/sec');
      } else {
        _viewerFPS = (_viewerFramesReceived / 1.0);
        print(
            '[VIEWER_FPS] Frames received: ${_viewerFPS.toStringAsFixed(1)}/sec');
        _viewerFramesReceived = 0;
      }

      if (mounted) {
        setState(() {});
      }
    });
  }

  void _setupKeyRotation() {
    _keyRotationTimer = Timer.periodic(
      const Duration(hours: 1),
      (_) => _rotateStreamKey(),
    );
  }

  Future<void> _rotateStreamKey() async {
    if (mounted) {
      final result = await StreamKeyExchangeService.generateSharedSecret(
        FirebaseAuth.instance.currentUser!.uid,
        widget.streamerId,
        widget.isStreamer,
      );

      if (!result['success']) {
        print('Failed to rotate stream key: ${result['error']}');
      }
    }
  }

  Future<void> tryKeyExchangeWithViewer({
    required String streamerId,
    required String viewerId,
    required String streamId,
    int retries = 5,
    Duration delay = const Duration(seconds: 1),
  }) async {
    for (int attempt = 0; attempt < retries; attempt++) {
      final result = await StreamKeyExchangeService.generateSharedSecret(
        streamerId,
        viewerId,
        true,
        streamId: streamId,
      );

      if (result['success'] == true) {
        print('[KEY_EXCHANGE] Shared secret established for viewer: $viewerId');
        return;
      }

      final error = result['error']?.toString() ?? '';
      print(
          'Attempt $attempt: Failed to generate shared key for viewer $viewerId: $error');

      if (error.contains('public key not found')) {
        await Future.delayed(delay);
      } else {
        break;
      }
    }
    print(
        '[KEY_EXCHANGE][ERROR] Could not establish shared key for viewer $viewerId after retries');
  }

  Future<void> _initializeCameraPreview() async {
    CameraDescription? frontCamera = cameras.firstWhere(
      (camera) => camera.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    _cameraController = CameraController(
      frontCamera,
      ResolutionPreset.medium,
      enableAudio: true,
    );
    await _cameraController.initialize();

    setState(() {
      _cameraPreviewWidget = CameraPreview(_cameraController);
    });
  }

  Future<void> _initializeStream() async {
    try {
      final userId = FirebaseAuth.instance.currentUser!.uid;

      final response = await http.post(
        Uri.parse(
            'https://socket-server-production-23a9.up.railway.app/get-livekit-token'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'identity': userId,
          'roomName': widget.streamId,
          'isPublisher': widget.isStreamer,
        }),
      );

      if (response.statusCode != 200) {
        throw Exception(
            'Failed to fetch LiveKit token (${response.statusCode})');
      }

      final tokenJson = jsonDecode(response.body);
      final liveKitToken = tokenJson['token'];

      if (liveKitToken == null || liveKitToken.isEmpty) {
        throw Exception('Token is missing from server response');
      }

      if (widget.isStreamer) {
        await _liveKitService.connectAsStreamer(
            widget.liveKitUrl, liveKitToken);
        print('[LIVEKIT] Connected as streamer');

        await _initializeCameraPreview();
        print('[STREAMER] Camera initialized');

        _pendingAudioTrack = await LocalAudioTrack.create();
        print('[AUDIO_SYNC] Audio track created, will publish with delay');

        _liveKitService.room.events.listen((event) {
          if (event is ParticipantConnectedEvent) {
            final viewerId = event.participant.identity;
            print('[STREAMER] New viewer connected: $viewerId');

            _connectedViewers.add(viewerId);
            _onViewerConnected(viewerId);

            if (_connectedViewers.length == 1 && !_audioPublished) {
              _startAudioWithDelay();
            }

            if (_connectedViewers.length == 1 && _useNativePipeline) {
              _startNativePipeline();
            }
          }

          if (event is ParticipantDisconnectedEvent) {
            final viewerId = event.participant.identity;
            print('[STREAMER] Viewer disconnected: $viewerId');

            _connectedViewers.remove(viewerId);
            _onViewerDisconnected(viewerId);

            if (_connectedViewers.isEmpty && _nativePipelineActive) {
              _stopNativePipeline();
            }
          }
        });
      } else {
        print('[VIEWER] Starting as viewer...');

        if (widget.streamerId.isEmpty) {
          throw Exception('Streamer ID is missing or invalid');
        }

        await _liveKitService.connectAsViewer(widget.liveKitUrl, liveKitToken);
        print('[LIVEKIT] Connected as viewer');

        _liveKitService.onData((Uint8List data, RemoteParticipant participant) {
          final senderId = participant.identity;
          print('[VIEWER] Received data from: $senderId, size: ${data.length}');
          _handleEncryptedFrame(data, senderId);
        });

        _performKeyExchange();
      }

      setState(() {
        _isLoading = false;
      });

      print('[INIT] Stream initialization completed successfully');
    } catch (e) {
      print('Error in stream initialization: $e');
      setState(() {
        _hasError = true;
        _isLoading = false;
      });
    }
  }

  void _startAudioWithDelay() {
    if (_audioPublished || _pendingAudioTrack == null) return;

    _audioDelayTimer = Timer(const Duration(milliseconds: 300), () async {
      try {
        await _liveKitService.localParticipant
            ?.publishAudioTrack(_pendingAudioTrack!);
        _audioPublished = true;
        print('[AUDIO_SYNC] Audio published successfully with delay');
      } catch (e) {
        print('[AUDIO_SYNC] Error publishing delayed audio: $e');
      }
    });
  }

  Future<void> _onViewerConnected(String viewerId) async {
    try {
      print('[STREAMER] Processing viewer connection: $viewerId');

      await tryKeyExchangeWithViewer(
        streamerId: FirebaseAuth.instance.currentUser!.uid,
        viewerId: viewerId,
        streamId: widget.streamId,
      );

      final aesKey = await StreamKeyExchangeService.getStreamKey(
        widget.streamId,
        otherUserId: viewerId,
      );

      if (aesKey != null) {
        print('[NATIVE_PIPELINE] Adding viewer $viewerId with AES key');
        final success = await NativeVideoPlugin.addViewer(
          viewerId: viewerId,
          aesKey: aesKey,
        );
        print('[NATIVE_PIPELINE] Add viewer result: $success');

        if (success) {
          print('[NATIVE_PIPELINE] Added viewer with key: $viewerId');
          if (_connectedViewers.length == 1) {
            _startNativePipeline();
          }
        } else {
          print('[NATIVE_PIPELINE] Failed to add viewer: $viewerId');
        }
      } else {
        print('[NATIVE_PIPELINE] No AES key available for viewer: $viewerId');
      }
    } catch (e) {
      print('[STREAMER] Error handling viewer connection: $e');
    }
  }

  Future<void> _onViewerDisconnected(String viewerId) async {
    if (_useNativePipeline) {
      await NativeVideoPlugin.removeViewer(viewerId);
      print('[NATIVE_PIPELINE] Removed viewer: $viewerId');
    }
  }

  Future<void> _startNativePipeline() async {
    if (!NativeVideoPlugin.isAvailable) {
      print('[NATIVE_PIPELINE] Native pipeline not available');
      setState(() {
        _hasError = true;
      });
      return;
    }

    try {
      print('[NATIVE_PIPELINE] Starting native video pipeline...');

      final success = await NativeVideoPlugin.startVideoStream(
        streamId: widget.streamId,
        viewers: _connectedViewers.toList(),
      );

      if (success && _cameraController.value.isInitialized) {
        _nativePipelineActive = true;

        if (!_isImageStreamActive) {
          print('[NATIVE_PIPELINE] Starting camera image stream...');

          _cameraController.startImageStream((CameraImage image) {
            if (_nativePipelineActive) {
              final frameId = DateTime.now().microsecondsSinceEpoch;
              if (_latencyTestEnabled) {
                _latencyTracker.recordFrameCaptured(frameId);
                print('[LATENCY_TEST] Dart: Frame captured $frameId');
              }

              NativeVideoPlugin.processFrame(image).catchError((error) {
                print('[NATIVE_PIPELINE] Frame processing error: $error');
              });
            }
          });
          _isImageStreamActive = true;
        }
      } else {
        throw Exception('Failed to start native video stream');
      }
    } catch (e) {
      print('[NATIVE_PIPELINE] Critical error: $e');
      setState(() {
        _hasError = true;
      });
    }
  }

  Future<void> _stopNativePipeline() async {
    if (!_nativePipelineActive) return;

    try {
      print('[NATIVE_PIPELINE] Stopping native video pipeline...');

      await NativeVideoPlugin.stopVideoStream();
      _nativePipelineActive = false;

      if (_isImageStreamActive && _cameraController.value.isInitialized) {
        try {
          _cameraController.stopImageStream();
          _isImageStreamActive = false;
        } catch (e) {
          print('[NATIVE_PIPELINE] Error stopping image stream: $e');
        }
      }

      print('[NATIVE_PIPELINE] Native pipeline stopped');
    } catch (e) {
      print('[NATIVE_PIPELINE] Error stopping native pipeline: $e');
    }
  }

  void _handleNativeEncryptedFrame(Uint8List data, String viewerId) {
    // Direct call, no timing overhead
    _liveKitService.publishVideoFrameImmediate(data,
        destinationIdentities: [viewerId]).catchError((error) {
      print('[FRAME_ERROR] Failed to send frame: $error');
    });
  }

  void _performKeyExchange() async {
    final userId = FirebaseAuth.instance.currentUser!.uid;

    print('[VIEWER] Starting key exchange with streamer: ${widget.streamerId}');

    bool keyExchangeSuccess = false;
    int attempts = 0;
    const maxAttempts = 10;

    while (!keyExchangeSuccess && attempts < maxAttempts && mounted) {
      attempts++;
      print('[VIEWER] Key exchange attempt $attempts/$maxAttempts');

      try {
        final keyExchange = await StreamKeyExchangeService.generateSharedSecret(
          userId,
          widget.streamerId,
          false,
          streamId: widget.streamId,
        );

        if (keyExchange['success'] == true) {
          print('[VIEWER] Key exchange successful');
          await _preloadViewerKey();

          if (mounted) {
            setState(() {
              _isEncryptionReady = true;
            });
          }
          keyExchangeSuccess = true;
          break;
        } else {
          print('[VIEWER] Key exchange failed: ${keyExchange['error']}');
          await Future.delayed(const Duration(seconds: 2));
        }
      } catch (e) {
        print('[VIEWER] Key exchange error: $e');
        await Future.delayed(const Duration(seconds: 2));
      }
    }

    if (!keyExchangeSuccess && mounted) {
      setState(() {
        _hasError = true;
      });
    }
  }

  Future<void> _handleEncryptedFrame(Uint8List payload, String senderId) async {
    try {
      if (payload.length >= 16) {
        final frameId = payload.buffer.asByteData().getUint64(0);
        final chunkIndex = payload.buffer.asByteData().getUint32(8);
        final totalChunks = payload.buffer.asByteData().getUint32(12);
        final currentTime = DateTime.now().millisecondsSinceEpoch;
        final timeDiff = (currentTime - frameId).abs();

        if (timeDiff < 10000 &&
            chunkIndex < 1000 &&
            totalChunks > 0 &&
            totalChunks < 1000 &&
            chunkIndex < totalChunks) {
          final chunkData = payload.sublist(16);

          print(
              '[VIEWER] Received chunk $chunkIndex/$totalChunks for frame $frameId');

          _frameChunks.putIfAbsent(frameId, () => {});
          _frameChunks[frameId]![chunkIndex] = chunkData;
          _expectedChunks[frameId] = totalChunks;

          final receivedChunks = _frameChunks[frameId]!.length;
          final completionRatio = receivedChunks / totalChunks;

          if (completionRatio >= 0.8 || receivedChunks == totalChunks) {
            final reconstructedBytes = <int>[];
            for (int i = 0; i < totalChunks; i++) {
              final chunk = _frameChunks[frameId]![i];
              if (chunk != null) {
                reconstructedBytes.addAll(chunk);
              } else {
                print('[VIEWER] Missing chunk $i, displaying partial frame');
                break;
              }
            }

            if (reconstructedBytes.isNotEmpty) {
              try {
                final frameData = Uint8List.fromList(reconstructedBytes);
                await _handleSingleFrame(frameData, senderId);
              } catch (e) {
                print('[VIEWER] Failed to process partial frame: $e');
              }
            }

            _frameChunks.remove(frameId);
            _expectedChunks.remove(frameId);
          }

          return;
        }
      }
      print(
          '[VIEWER] Received single frame from: $senderId, size: ${payload.length}');
      await _handleSingleFrame(payload, senderId);
    } catch (e) {
      print('[VIEWER] Frame handling error: $e');
      try {
        await _handleSingleFrame(payload, senderId);
      } catch (fallbackError) {
        print(
            '[VIEWER] Fallback single frame handling also failed: $fallbackError');
      }
    }
  }

  Future<void> _handleSingleFrame(Uint8List payload, String senderId) async {
    final receiveTime = DateTime.now().millisecondsSinceEpoch;

    try {
      print(
          '[VIEWER] Processing frame from $senderId, payload size: ${payload.length}');

      const minPayloadSize = StreamCryptoService.nonceLength + 4 + 8;
      if (payload.length < minPayloadSize) {
        print(
            '[VIEWER] Payload too short: ${payload.length} < $minPayloadSize bytes');
        return;
      }

      final nonce = payload.sublist(0, StreamCryptoService.nonceLength);
      print('[VIEWER] Extracted nonce: ${nonce.length} bytes');

      final timestampOffset = payload.length - 12;
      final timestamp = payload.buffer.asByteData().getInt32(timestampOffset);

      int? frameId;
      try {
        final frameIdOffset = payload.length - 8;
        frameId = payload.buffer.asByteData().getUint64(frameIdOffset);
      } catch (e) {
        frameId = receiveTime;
      }
      print(
          '[TIMING] VIEWER: Frame $frameId received at $receiveTime (${payload.length} bytes)');

      final encrypted =
          payload.sublist(StreamCryptoService.nonceLength, timestampOffset);
      print('[VIEWER] Extracted encrypted data: ${encrypted.length} bytes');

      Uint8List? aesKey = _cachedKeys[senderId];
      if (aesKey == null) {
        print('[VIEWER] Fetching AES key for sender: $senderId');
        aesKey = await StreamKeyExchangeService.getStreamKey(
          widget.streamId,
          otherUserId: senderId,
        );
        if (aesKey == null) {
          print('[VIEWER] No AES key available for sender: $senderId');
          return;
        }
        _cachedKeys[senderId] = aesKey;
      }

      final decryptStartTime = DateTime.now().millisecondsSinceEpoch;
      Uint8List? decrypted;

      try {
        print('[VIEWER] Starting native decryption for frameId: $frameId');

        decrypted = await NativeVideoPlugin.decryptFrame(
          encrypted: encrypted,
          aesKey: aesKey,
          nonce: nonce,
          streamId: widget.streamId,
          timestamp: timestamp,
          frameId: frameId,
        );
        print(
            '[VIEWER] Native decryption successful: ${decrypted.length} bytes');
      } catch (e) {
        print('[VIEWER] Native decryption failed: $e');

        try {
          print('[VIEWER] Trying Dart fallback decryption...');
          decrypted = await compute(_isolateDecryptFrame, {
            'encrypted': encrypted,
            'nonce': nonce,
            'aesKey': aesKey,
            'streamId': widget.streamId,
            'timestamp': timestamp,
          });
          print(
              '[VIEWER] Dart decryption successful: ${decrypted?.length} bytes');
        } catch (fallbackError) {
          print('[VIEWER] Dart decryption also failed: $fallbackError');
          return;
        }
      }

      if (decrypted == null) {
        print('[VIEWER] Decryption returned null');
        return;
      }

      _viewerFramesReceived++;

      final decryptDuration =
          DateTime.now().millisecondsSinceEpoch - decryptStartTime;
      final renderStartTime = DateTime.now().millisecondsSinceEpoch;

      _frameBuffer.updateFrame(decrypted, frameId ?? receiveTime);

      _startFrameRenderer();

      if (mounted) {
        try {
          // Keep existing latency tracking
          if (_latencyTestEnabled && frameId != null) {
            print(
                '[LATENCY_TEST] Recording frame rendered: $frameId at $renderStartTime');

            _latencyTracker.recordFrameRendered(frameId);

            try {
              final success =
                  await NativeVideoPlugin.recordFrameRendered(frameId);
              if (success) {
                print(
                    '[LATENCY_TEST] VIEWER: Frame rendered with ID=$frameId at timestamp=$renderStartTime');
              } else {
                print('[LATENCY_TEST] Failed to record in native: $frameId');
              }
            } catch (e) {
              print('[LATENCY_TEST] Native record error: $e');
            }
          }

          final decryptTime = DateTime.now().millisecondsSinceEpoch;
          final networkLatency = decryptTime - receiveTime;
          print(
              '[TIMING] VIEWER: Frame $frameId processed in ${networkLatency}ms');
        } catch (e) {
          print('[VIEWER] Error in frame processing: $e');
        }
      }
    } catch (e, stackTrace) {
      print(
          '[TIMING] VIEWER: Frame processing failed after ${DateTime.now().millisecondsSinceEpoch - receiveTime}ms: $e');
      print('[VIEWER] Critical error in frame handling: $e');
      print('[VIEWER] Stack trace: $stackTrace');
    }
  }

  void _startFrameRenderer() {
    if (_renderTimer != null) return; // Already running

    _renderTimer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      // 30 FPS max
      final frame = _frameBuffer.consumeLatestFrame();
      if (frame != null && mounted) {
        setState(() {
          _currentFrame = frame;
          _remoteVideoConnected = true;
        });

        // Complete the frame processing cycle
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _frameBuffer.setProcessingComplete();
        });
      }
    });
  }

  Future<void> _startEntropyTest() async {
    if (!widget.isStreamer) return; // Only streamer collects entropy

    print('[ENTROPY_TEST] Starting 60-second entropy collection...');

    final started = await NativeVideoPlugin.startEntropyTest();
    if (started) {
      setState(() {
        _entropyTestEnabled = true;
      });

      // Stop after 60 seconds
      _entropyTestTimer = Timer(const Duration(seconds: 60), () async {
        await _stopEntropyTest();
      });

      // Update stats every 5 seconds
      Timer.periodic(const Duration(seconds: 5), (timer) async {
        if (!_entropyTestEnabled) {
          timer.cancel();
          return;
        }

        final stats = await NativeVideoPlugin.getEntropyTestStats();
        if (stats != null) {
          setState(() {
            _entropyStats = stats;
          });
        }
      });
    }
  }

  Future<void> _stopEntropyTest() async {
    print('[ENTROPY_TEST] Stopping entropy collection...');

    final result = await NativeVideoPlugin.stopEntropyTest();
    _entropyTestTimer?.cancel();

    setState(() {
      _entropyTestEnabled = false;
    });

    if (result is Map<String, dynamic>) {
      final framesCollected = result['framesCollected'] ?? 0;
      final outputDir = result['outputDir'] ?? 'unknown';

      print('[ENTROPY_TEST] Collection complete:');
      print('  - Frames collected: $framesCollected');
      print('  - Output directory: $outputDir');

      // Show completion dialog
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Entropy Test Complete'),
            content: Text(
              'Collected $framesCollected encrypted frames.\n\n'
              'Files saved to:\n$outputDir\n\n'
              'Copy the "ciphertext" folder to your computer to run entropy analysis.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    }
  }

  Future<void> _preloadViewerKey() async {
    try {
      final aesKey = await StreamKeyExchangeService.getStreamKey(
        widget.streamId,
        otherUserId: widget.streamerId,
      );
      if (aesKey != null) {
        _cachedKeys[widget.streamerId] = aesKey;
        print('[VIEWER] Key cached for streamer: ${widget.streamerId}');
      }
    } catch (e) {
      print('[VIEWER] Failed to preload key: $e');
    }
  }

  void _listenToStreamStatus() {
    _streamStatusSubscription = FirebaseFirestore.instance
        .collection('streams')
        .doc(widget.streamId)
        .snapshots()
        .listen((snapshot) {
      if (!snapshot.exists || snapshot.data()?['isLive'] == false) {
        Navigator.pop(context);
      }
    });
  }

  void _endStream() async {
    try {
      await FirebaseFirestore.instance
          .collection('streams')
          .doc(widget.streamId)
          .update({'isLive': false});
    } catch (e) {
      print('Error ending stream: $e');
    }
  }

  @override
  void dispose() {
    _renderTimer?.cancel();

    _audioDelayTimer?.cancel();
    _pendingAudioTrack?.dispose();

    if (_latencyTestEnabled) {
      _latencyTracker.stop();
      _latencyStatsTimer?.cancel();
    }

    if (_nativePipelineActive) {
      NativeVideoPlugin.stopVideoStream();
    }

    if (_isImageStreamActive && _cameraController.value.isInitialized) {
      try {
        _cameraController.stopImageStream();
        _isImageStreamActive = false;
      } catch (e) {
        print('[STREAMER] Error stopping image stream: $e');
      }
    }

    _keyRotationTimer?.cancel();
    _fpsTimer?.cancel();
    _nativeStatsTimer?.cancel();

    _cameraController.dispose();
    _cachedKeys.clear();

    if (widget.isStreamer) {
      _endStream();
      StreamKeyExchangeService.cleanupStreamKeys(widget.streamId);
    }

    _isDisposed = true;
    _streamStatusSubscription?.cancel();
    _chatSubscription?.cancel();
    _chatController.dispose();
    _chatFocusNode.dispose();

    super.dispose();
  }

  void _initializeChat() {
    _chatSubscription = FirebaseFirestore.instance
        .collection('streams')
        .doc(widget.streamId)
        .collection('chat')
        .orderBy('timestamp', descending: false)
        .snapshots()
        .listen((snapshot) {
      setState(() {
        chatMessages =
            snapshot.docs.map((doc) => ChatMessage.fromDocument(doc)).toList();
      });
    });
  }

  Color _getRandomColor(String userId) {
    if (!_userColors.containsKey(userId)) {
      final random = Random();
      final hue = random.nextDouble() * 360;
      final saturation = 0.5 + random.nextDouble() * 0.5;
      final brightness = 0.8 + random.nextDouble() * 0.2;

      final color =
          HSLColor.fromAHSL(1.0, hue, saturation, brightness).toColor();
      _userColors[userId] = color;

      FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .set({'chatColor': color.value}, SetOptions(merge: true));
    }
    return _userColors[userId]!;
  }

  Future<void> _sendMessage() async {
    if (_chatController.text.isNotEmpty) {
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser != null) {
        try {
          final message = ChatMessage(
            userId: currentUser.uid,
            message: _chatController.text,
            username: currentUser.displayName ?? 'Unknown',
            userColor: _getRandomColor(currentUser.uid),
            timestamp: Timestamp.now(),
          );

          await FirebaseFirestore.instance
              .collection('streams')
              .doc(widget.streamId)
              .collection('chat')
              .add(message.toMap());

          _chatController.clear();
        } catch (e) {
          print('Error sending message: $e');
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to send message')),
          );
        }
      }
    }
  }

  Widget _buildChatSection() {
    return Container(
      color: const Color(0xFF1A1A1A),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Text(
                  'CHAT',
                  style: GoogleFonts.inter(
                    color: Colors.white70,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: chatMessages.isEmpty
                ? Center(
                    child: Text(
                      'No messages yet',
                      style: TextStyle(color: Colors.grey[600]),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: chatMessages.length,
                    itemBuilder: (context, index) {
                      final message = chatMessages[index];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: RichText(
                          text: TextSpan(
                            children: [
                              TextSpan(
                                text: "${message.username} ",
                                style: TextStyle(
                                  color: message.userColor,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              TextSpan(
                                text: message.message,
                                style: const TextStyle(color: Colors.white),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          Container(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _chatController,
                    cursorColor: Colors.white,
                    focusNode: _chatFocusNode,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'Type your message',
                      hintStyle: TextStyle(color: Colors.grey[400]),
                      filled: true,
                      fillColor: Colors.grey[900],
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                    ),
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.send, color: Colors.white),
                  onPressed: _sendMessage,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoDisplay() {
    if (widget.isStreamer) {
      if (_cameraController.value.isInitialized &&
          _cameraController.value.previewSize != null) {
        final previewSize = _cameraController.value.previewSize!;
        return FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: previewSize.height,
            height: previewSize.width,
            child: RepaintBoundary(
              key: _previewContainerKey,
              child: _cameraPreviewWidget!,
            ),
          ),
        );
      } else {
        return const Center(child: Text('Initializing camera...'));
      }
    } else {
      if (_currentFrame != null) {
        return RepaintBoundary(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: 426,
              height: 240,
              child: Image.memory(
                _currentFrame!,
                gaplessPlayback: true,
                fit: BoxFit.fill,
                filterQuality: FilterQuality.low,
                errorBuilder: (context, error, stackTrace) {
                  print('[VIEWER] Frame render error: $error');
                  return Container(color: Colors.black);
                },
              ),
            ),
          ),
        );
      } else {
        return Container(
          color: Colors.black,
          child: Center(
            child: _isEncryptionReady
                ? const Text(
                    'Connecting...',
                    style: TextStyle(color: Colors.white70, fontSize: 14),
                  )
                : const Text(
                    'Establishing connection...',
                    style: TextStyle(color: Colors.white70, fontSize: 14),
                  ),
          ),
        );
      }
    }
  }

  Widget _buildLatencyStatsOverlay() {
    if (!_latencyTestEnabled || _currentLatencyStats.isEmpty) {
      return const SizedBox.shrink();
    }

    return Positioned(
      top: 100,
      right: 16,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.7),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'E2E LATENCY',
              style: TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Avg: ${_currentLatencyStats['average']?.toStringAsFixed(1) ?? 'N/A'}ms',
              style: const TextStyle(color: Colors.white, fontSize: 9),
            ),
            Text(
              'P95: ${_currentLatencyStats['p95']?.toStringAsFixed(1) ?? 'N/A'}ms',
              style: const TextStyle(color: Colors.white, fontSize: 9),
            ),
            Text(
              'Samples: ${_currentLatencyStats['samples']?.toInt() ?? 0}',
              style: const TextStyle(color: Colors.white70, fontSize: 8),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEntropyTestUI() {
    if (!widget.isStreamer) return const SizedBox.shrink();

    return Positioned(
      top: 150,
      right: 16,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.8),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'ENTROPY TEST',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            if (_entropyTestEnabled) ...[
              Text(
                'Collecting...',
                style: const TextStyle(color: Colors.green, fontSize: 9),
              ),
              Text(
                'Frames: ${_entropyStats['framesCollected'] ?? 0}',
                style: const TextStyle(color: Colors.white, fontSize: 9),
              ),
            ] else ...[
              GestureDetector(
                onTap: _startEntropyTest,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.blue,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'START',
                    style: TextStyle(color: Colors.white, fontSize: 8),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_hasError) {
      return Scaffold(
        appBar: AppBar(title: const Text('Live Stream')),
        body: const Center(
          child: Text(
            'Connection failed. Please try again.',
            style: TextStyle(fontSize: 16),
          ),
        ),
      );
    }

    if (_isLoading) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: Colors.white),
              SizedBox(height: 16),
              Text(
                'Joining stream...',
                style: TextStyle(color: Colors.white),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFE5E5E5),
      body: Column(
        children: [
          Stack(
            children: [
              Container(
                color: Colors.black,
                child: SizedBox(
                    width: double.infinity,
                    height: MediaQuery.of(context).size.width * 9 / 16,
                    child: _buildVideoDisplay()),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                ),
              ),
              _buildLatencyStatsOverlay(),
              _buildEntropyTestUI(),
            ],
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            color: const Color(0xFFE5E5E5),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.streamTitle,
                        style: GoogleFonts.inter(
                          color: Colors.black,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          CircleAvatar(
                            radius: 12,
                            backgroundColor: Colors.black,
                            child: Text(
                              widget.streamerUsername[0].toUpperCase(),
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.white),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            widget.streamerUsername,
                            style: GoogleFonts.inter(
                              color: Colors.black87,
                              fontSize: 14,
                            ),
                          ),
                          const Spacer(),
                          if (widget.isStreamer)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: _getFpsColor(),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                '${_getCurrentFps().toStringAsFixed(0)} FPS',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          if (!widget.isStreamer &&
                              _currentLatencyStats.isNotEmpty)
                            Container(
                              margin: const EdgeInsets.only(left: 8),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: _getLatencyColor(
                                    _currentLatencyStats['average'] ?? 0),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                '${(_currentLatencyStats['average'] ?? 0).toStringAsFixed(0)}ms',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _buildChatSection(),
          ),
        ],
      ),
    );
  }

  Color _getLatencyColor(double latency) {
    if (latency <= 100) return Colors.green;
    if (latency <= 200) return Colors.orange;
    return Colors.red;
  }

  Color _getFpsColor() {
    final fps = _getCurrentFps();
    if (fps >= 25) return Colors.green;
    if (fps >= 15) return Colors.orange;
    return Colors.red;
  }

  double _getCurrentFps() {
    if (widget.isStreamer) {
      return _nativeFPS;
    } else {
      return _viewerFPS;
    }
  }
}
