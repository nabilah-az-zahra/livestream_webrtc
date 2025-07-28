import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:camera/camera.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:livekit_client/livekit_client.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:livestream_webrtc/main.dart';
import 'package:livestream_webrtc/livekit_service.dart';
import 'package:livestream_webrtc/exchange_service.dart';
import 'package:livestream_webrtc/e2ee_service.dart';
import 'package:livestream_webrtc/logger.dart';

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

Uint8List isolateConvertYUV420ToJPEG(Map<String, dynamic> params) {
  final CameraImage image = params['image'];
  final int width = image.width;
  final int height = image.height;

  final int uvRowStride = image.planes[1].bytesPerRow;
  final int uvPixelStride = image.planes[1].bytesPerPixel!;

  final img.Image imgImage = img.Image(width: width, height: height);

  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final int yIndex = y * image.planes[0].bytesPerRow + x;
      final int uvIndex = (y ~/ 2) * uvRowStride + (x ~/ 2) * uvPixelStride;

      final int yValue = image.planes[0].bytes[yIndex];
      final int uValue = image.planes[1].bytes[uvIndex];
      final int vValue = image.planes[2].bytes[uvIndex];

      final int r = (yValue + 1.402 * (vValue - 128)).round().clamp(0, 255);
      final int g =
          (yValue - 0.344136 * (uValue - 128) - 0.714136 * (vValue - 128))
              .round()
              .clamp(0, 255);
      final int b = (yValue + 1.772 * (uValue - 128)).round().clamp(0, 255);

      imgImage.setPixelRgba(x, y, r, g, b, 255);
    }
  }

  final rotatedImage = img.copyRotate(imgImage, angle: -90);
  return Uint8List.fromList(img.encodeJpg(rotatedImage, quality: 80));
}

Future<Uint8List> isolateEncryptFrame(Map<String, dynamic> params) async {
  final Uint8List frameBytes = params['frameBytes'];
  final Uint8List aesKey = params['aesKey'];
  final String streamId = params['streamId'];
  final int timestamp = params['timestamp'];

  final nonce = StreamCryptoService.generateNonce();
  final aad = StreamCryptoService.buildAad(streamId, timestamp);
  final cipher =
      StreamCryptoService.createAesGcmCipher(true, aesKey, nonce, aad: aad);

  final encrypted = cipher.process(frameBytes);

  final payload =
      Uint8List(StreamCryptoService.nonceLength + encrypted.length + 4);
  payload.setRange(0, StreamCryptoService.nonceLength, nonce);
  payload.setRange(StreamCryptoService.nonceLength,
      StreamCryptoService.nonceLength + encrypted.length, encrypted);
  payload.buffer
      .asByteData()
      .setUint32(StreamCryptoService.nonceLength + encrypted.length, timestamp);

  return payload;
}

Future<Uint8List> _isolateDecryptFrame(Map<String, dynamic> params) async {
  final Uint8List encrypted = params['encrypted'];
  final Uint8List aesKey = params['aesKey'];
  final Uint8List nonce = params['nonce'];
  final String streamId = params['streamId'];
  final int timestamp = params['timestamp'];

  final aad = StreamCryptoService.buildAad(streamId, timestamp);
  final cipher =
      StreamCryptoService.createAesGcmCipher(false, aesKey, nonce, aad: aad);

  return cipher.process(encrypted);
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

  Timer? _frameTimer;
  Timer? _keyRotationTimer;
  Timer? _keyRefreshTimer;
  Timer? _fpsTimer;
  Uint8List? _currentFrame;

  bool _isImageStreamActive = false;
  Uint8List? _latestFrameBytes;

  bool _isStreamingActive = false;
  final Queue<Uint8List> _frameQueue = Queue<Uint8List>();
  Timer? _displayTimer;

  int _streamerFramesSent = 0;
  int _viewerFramesReceived = 0;
  double _streamerFPS = 0.0;
  double _viewerFPS = 0.0;
  DateTime _lastFpsUpdate = DateTime.now();

  bool _isLoading = true;
  bool _hasError = false;
  bool _remoteVideoConnected = false;
  bool _isDisposed = false;
  bool _remoteDescriptionSet = false;
  bool _isEncryptionReady = false;
  bool _isFrameSendingActive = false;
  bool _isCapturing = false;

  StreamSubscription? _streamStatusSubscription;
  StreamSubscription? _chatSubscription;

  List<ChatMessage> chatMessages = [];

  final TextEditingController _chatController = TextEditingController();
  final FocusNode _chatFocusNode = FocusNode();

  final Map<String, Color> _userColors = {};

  @override
  void initState() {
    super.initState();
    if (FirebaseAuth.instance.currentUser != null) {
      _initializeStream();
      _setupKeyRotation();
      _listenToStreamStatus();
      _initializeChat();
      _startFPSMonitoring();
      if (!widget.isStreamer) {
        _preloadViewerKey();
      }
    } else {
      Navigator.pushReplacementNamed(context, '/login');
    }
  }

  void _startFPSMonitoring() {
    final stopwatch = Stopwatch()..start();

    _fpsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final elapsedSeconds = stopwatch.elapsedMilliseconds / 1000.0;

      if (widget.isStreamer) {
        _streamerFPS = (_streamerFramesSent / elapsedSeconds);
        print(
            '[STREAMER FPS] Frames sent: ${_streamerFPS.toStringAsFixed(1)}/sec');
        _streamerFramesSent = 0;
      } else {
        _viewerFPS = (_viewerFramesReceived / elapsedSeconds);
        print(
            '[VIEWER FPS] Frames received: ${_viewerFPS.toStringAsFixed(1)}/sec');
        _viewerFramesReceived = 0;
      }

      stopwatch.reset();

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

        _liveKitService.room.events.listen((event) {
          if (event is ParticipantConnectedEvent &&
              event.participant is RemoteParticipant) {
            final viewerId = event.participant.identity;
            print('[STREAMER] New viewer connected: $viewerId');

            _connectedViewers.add(viewerId);

            if (_connectedViewers.length == 1 && !_isFrameSendingActive) {
              _startEncryptedFrameSender();
              _isFrameSendingActive = true;
              print('[STREAMER] Started frame sending for first viewer');
            }

            tryKeyExchangeWithViewer(
              streamerId: FirebaseAuth.instance.currentUser!.uid,
              viewerId: viewerId,
              streamId: widget.streamId,
            );
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

  void _startEncryptedFrameSender() {
    if (_frameTimer != null) {
      _frameTimer!.cancel();
    }

    _keyRefreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _cachedKeys.clear();
    });

    if (_cameraController == null || !_cameraController.value.isInitialized) {
      print('[STREAMER] Camera is not initialized');
      return;
    }

    if (!_isImageStreamActive) {
      _cameraController.startImageStream((CameraImage image) {
        if (!_isCapturing && _connectedViewers.isNotEmpty) {
          _convertCameraImageToBytes(image);
        }
      });
      _isImageStreamActive = true;
      print('[STREAMER] Image stream started');
    }

    _frameTimer = Timer.periodic(const Duration(milliseconds: 50), (_) async {
      if (_connectedViewers.isEmpty ||
          _isCapturing ||
          _latestFrameBytes == null) {
        return;
      }

      _isCapturing = true;
      try {
        print('[STREAMER] Starting frame capture...');

        final frameBytes = _latestFrameBytes!;
        print('[STREAMER] Using frame: ${frameBytes.length} bytes');

        final compressedBytes = await _compressImageForStreaming(frameBytes);
        print(
            '[STREAMER] Compressed frame: ${compressedBytes.length} bytes (original: ${frameBytes.length})');

        for (final viewerId in _connectedViewers) {
          await _sendEncryptedFrame(viewerId, compressedBytes);
        }

        _streamerFramesSent++;
      } catch (e) {
        print('[STREAMER] Frame encryption/send error: $e');
      } finally {
        _isCapturing = false;
      }
    });
  }

  Future<void> _convertCameraImageToBytes(CameraImage image) async {
    try {
      final bytes = await _cameraImageToBytes(image);
      _latestFrameBytes = bytes;
    } catch (e) {
      print('[STREAMER] Error converting camera image: $e');
    }
  }

  Future<Uint8List> _cameraImageToBytes(CameraImage image) async {
    try {
      if (image.format.group == ImageFormatGroup.yuv420) {
        return _convertYUV420ToJPEG(image);
      } else if (image.format.group == ImageFormatGroup.bgra8888) {
        return _convertBGRA8888ToJPEG(image);
      } else {
        throw Exception('Unsupported image format: ${image.format.group}');
      }
    } catch (e) {
      print('[STREAMER] Image conversion error: $e');
      rethrow;
    }
  }

  Future<Uint8List> _convertYUV420ToJPEG(CameraImage image) async {
    return await compute(
      isolateConvertYUV420ToJPEG,
      {'image': image},
    );
  }

  Uint8List _convertBGRA8888ToJPEG(CameraImage image) {
    final img.Image imgImage = img.Image.fromBytes(
      width: image.width,
      height: image.height,
      bytes: image.planes[0].bytes.buffer,
      format: img.Format.uint8,
    );

    final rotatedImage = img.copyRotate(imgImage, angle: -90);

    return Uint8List.fromList(img.encodeJpg(rotatedImage, quality: 80));
  }

  Future<Uint8List> _compressImageForStreaming(Uint8List imageBytes) async {
    try {
      final ui.Image image = await decodeImageFromList(imageBytes);

      const maxWidth = 426.0;
      const maxHeight = 240.0;

      const targetWidth = maxWidth;
      const targetHeight = maxHeight;

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);

      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        Rect.fromLTWH(0, 0, targetWidth, targetHeight),
        Paint()..filterQuality = FilterQuality.medium,
      );

      final picture = recorder.endRecording();
      final compressedImage =
          await picture.toImage(targetWidth.toInt(), targetHeight.toInt());

      final byteData =
          await compressedImage.toByteData(format: ui.ImageByteFormat.png);

      return byteData!.buffer.asUint8List();
    } catch (e) {
      print('[STREAMER] Image compression failed: $e');
      return imageBytes;
    }
  }

  Future<void> _sendEncryptedFrame(String viewerId, Uint8List bytes) async {
    try {
      Uint8List? aesKey = _cachedKeys[viewerId];
      if (aesKey == null) {
        aesKey = await StreamKeyExchangeService.getStreamKey(
          widget.streamId,
          otherUserId: viewerId,
        );
        if (aesKey == null) {
          print('[STREAMER] No AES key available for viewer: $viewerId');
          return;
        }
        _cachedKeys[viewerId] = aesKey;
      }

      final timestamp = DateTime.now().millisecondsSinceEpoch;

      final encryptedPayload = await compute(isolateEncryptFrame, {
        'frameBytes': bytes,
        'aesKey': aesKey,
        'streamId': widget.streamId,
        'timestamp': timestamp,
      });

      const maxChunkSize = 60000;

      if (encryptedPayload.length <= maxChunkSize) {
        final success =
            await _liveKitService.publishData(encryptedPayload, true);
        if (success) {
          print(
              '[STREAMER] Frame sent to $viewerId: ${encryptedPayload.length} bytes');
        }
      } else {
        final totalChunks = (encryptedPayload.length / maxChunkSize).ceil();
        final frameId = DateTime.now().millisecondsSinceEpoch;

        for (int i = 0; i < totalChunks; i++) {
          final start = i * maxChunkSize;
          final end = math.min(start + maxChunkSize, encryptedPayload.length);
          final chunk = encryptedPayload.sublist(start, end);

          final chunkPayload = Uint8List(16 + chunk.length);
          chunkPayload.buffer.asByteData().setUint64(0, frameId);
          chunkPayload.buffer.asByteData().setUint32(8, i);
          chunkPayload.buffer.asByteData().setUint32(12, totalChunks);
          chunkPayload.setRange(16, 16 + chunk.length, chunk);

          final success = await _liveKitService.publishData(chunkPayload, true);
          if (!success) {
            print(
                '[STREAMER] Failed to send chunk $i/$totalChunks to $viewerId');
            return;
          }
        }
      }
    } catch (e) {
      print('[STREAMER] Error sending frame to $viewerId: $e');
    }
  }

  Future<void> _handleEncryptedFrame(Uint8List payload, String senderId) async {
    try {
      if (payload.length < 16) {
        await _handleSingleFrame(payload, senderId);
        return;
      }

      final frameId = payload.buffer.asByteData().getUint64(0);
      final chunkIndex = payload.buffer.asByteData().getUint32(8);
      final totalChunks = payload.buffer.asByteData().getUint32(12);
      final chunkData = payload.sublist(16);

      if (frameId == 0) {
        await _handleSingleFrame(payload, senderId);
        return;
      }

      print(
          '[VIEWER] Received chunk $chunkIndex/$totalChunks for frame $frameId');

      _frameChunks.putIfAbsent(frameId, () => {});
      _frameChunks[frameId]![chunkIndex] = chunkData;
      _expectedChunks[frameId] = totalChunks;

      if (_frameChunks[frameId]!.length == totalChunks) {
        final reconstructedBytes = <int>[];
        for (int i = 0; i < totalChunks; i++) {
          final chunk = _frameChunks[frameId]![i];
          if (chunk == null) {
            print('[VIEWER] Missing chunk $i for frame $frameId');
            return;
          }
          reconstructedBytes.addAll(chunk);
        }

        try {
          final frameData = Uint8List.fromList(reconstructedBytes);
          await _handleSingleFrame(frameData, senderId);
        } catch (e) {
          print('[VIEWER] Failed to process frame data: $e');
        } finally {
          _frameChunks.remove(frameId);
          _expectedChunks.remove(frameId);
        }
      }
    } catch (e) {
      print('[VIEWER] Frame handling error: $e');
    }
  }

  Future<void> _handleSingleFrame(Uint8List payload, String senderId) async {
    try {
      if (payload.length < StreamCryptoService.nonceLength + 4) {
        print('[VIEWER] Payload too short: ${payload.length}');
        return;
      }

      final nonce = payload.sublist(0, StreamCryptoService.nonceLength);
      final timestamp =
          payload.buffer.asByteData().getUint32(payload.length - 4);
      final encrypted =
          payload.sublist(StreamCryptoService.nonceLength, payload.length - 4);

      Uint8List? aesKey = _cachedKeys[senderId];
      if (aesKey == null) {
        aesKey = await StreamKeyExchangeService.getStreamKey(widget.streamId,
            otherUserId: senderId);
        if (aesKey == null) {
          print('[VIEWER] No AES key available for sender: $senderId');
          return;
        }
        _cachedKeys[senderId] = aesKey;
      }

      final decrypted = await compute(_isolateDecryptFrame, {
        'encrypted': encrypted,
        'aesKey': aesKey,
        'nonce': nonce,
        'streamId': widget.streamId,
        'timestamp': timestamp,
      });

      print('[VIEWER] Frame decrypted successfully: ${decrypted.length} bytes');

      _frameQueue.add(decrypted);
      _viewerFramesReceived++;

      while (_frameQueue.length > 3) {
        _frameQueue.removeFirst();
      }

      if (_displayTimer == null && mounted) {
        _startFrameDisplay();
      }
    } catch (e) {
      print('[VIEWER] Frame decryption error: $e');
    }
  }

  void _startFrameDisplay() {
    _displayTimer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      if (_frameQueue.isNotEmpty && mounted) {
        final frame = _frameQueue.removeFirst();
        setState(() {
          _currentFrame = frame;
          _remoteVideoConnected = true;
        });
      }
    });
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
    if (_isImageStreamActive && _cameraController.value.isInitialized) {
      try {
        _cameraController.stopImageStream();
        _isImageStreamActive = false;
      } catch (e) {
        print('[STREAMER] Error stopping image stream: $e');
      }
    }

    _displayTimer?.cancel();
    _frameTimer?.cancel();
    _keyRotationTimer?.cancel();
    _keyRefreshTimer?.cancel();
    _fpsTimer?.cancel();

    _frameQueue.clear();

    _cameraController.dispose();
    _isFrameSendingActive = false;
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

  @override
  Widget build(BuildContext context) {
    if (_hasError) {
      return Scaffold(
        appBar: AppBar(title: const Text('Live Stream')),
        body: const Center(
          child: Text(
            'Error loading the stream. Please try again later.',
            style: TextStyle(fontSize: 18),
          ),
        ),
      );
    }

    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Live Stream')),
        body: const Center(
          child: CircularProgressIndicator(
            color: Colors.white,
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
              AspectRatio(
                aspectRatio: 16 / 9,
                child: Container(
                  color: Colors.black,
                  child: widget.isStreamer
                      ? RepaintBoundary(
                          key: _previewContainerKey,
                          child: _cameraPreviewWidget ??
                              const Center(
                                  child: Text('Initializing camera...')),
                        )
                      : _currentFrame != null
                          ? Container(
                              decoration: BoxDecoration(
                                  border: Border.all(color: Colors.red)),
                              child: Image.memory(
                                _currentFrame!,
                                fit: BoxFit.contain,
                                gaplessPlayback: true,
                                frameBuilder: (context, child, frame, wasSync) {
                                  if (frame == null) {
                                    return const Center(
                                      child: CircularProgressIndicator(
                                          color: Colors.white),
                                    );
                                  }
                                  return AnimatedSwitcher(
                                    duration: const Duration(milliseconds: 50),
                                    child: child,
                                  );
                                },
                                errorBuilder: (context, error, stackTrace) {
                                  return const Center(
                                    child: Text(
                                      'Failed to render frame',
                                      style: TextStyle(color: Colors.red),
                                    ),
                                  );
                                },
                              ),
                            )
                          : Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const CircularProgressIndicator(
                                      color: Colors.white),
                                  const SizedBox(height: 16),
                                  Text(
                                    _isEncryptionReady
                                        ? 'Waiting for encrypted frames...'
                                        : 'Establishing secure connection...',
                                    style: const TextStyle(color: Colors.white),
                                  ),
                                ],
                              ),
                            ),
                ),
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
              SafeArea(
                child: Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: IconButton(
                      icon: const Icon(Icons.settings, color: Colors.white),
                      onPressed: () {
                        //  settings
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
          // if (!widget.isStreamer && !_remoteVideoConnected)
          //   const Center(
          //     child: CircularProgressIndicator(color: Colors.white),
          //   ),
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
}
