import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:camera/camera.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart';
import 'package:livestream_webrtc/e2ee_service.dart';
import 'package:livestream_webrtc/exchange_service.dart';
import 'package:livestream_webrtc/livekit_service.dart';
import 'package:livestream_webrtc/main.dart';
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

class FrameBuffer {
  Uint8List? _latestFrame;
  int _latestFrameId = 0;
  bool _isProcessing = false;

  void updateFrame(Uint8List frame, int frameId) {
    if (frameId > _latestFrameId && !_isProcessing) {
      _latestFrame = frame;
      _latestFrameId = frameId;
    }
  }

  Uint8List? consumeLatestFrame() {
    if (_latestFrame != null) {
      _isProcessing = true;
      final frame = _latestFrame;
      _latestFrame = null;
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

    final aad = StreamCryptoService.buildAad(streamId, timestamp);
    final cipher =
        StreamCryptoService.createAesGcmCipher(false, aesKey, nonce, aad: aad);
    final decrypted = cipher.process(encrypted);

    return decrypted;
  } catch (e, stackTrace) {
    print('[ISOLATE_DECRYPT] Decryption failed: $e');
    print('[ISOLATE_DECRYPT] Stack trace: $stackTrace');
    rethrow;
  }
}

class _LiveStreamPageState extends State<LiveStreamPage> {
  final GlobalKey _previewContainerKey = GlobalKey();
  final LiveKitService _liveKitService = LiveKitService();
  final Map<int, int> _expectedChunks = {};
  final Map<int, Map<int, Uint8List>> _frameChunks = {};
  final Map<String, Uint8List?> _cachedKeys = {};
  final Set<String> _connectedViewers = {};

  bool _isImageStreamActive = false;
  bool _useNativePipeline = true;
  bool _nativePipelineActive = false;

  late CameraController _cameraController;
  Widget? _cameraPreviewWidget;

  int _viewerFramesReceived = 0;
  Timer? _keyRotationTimer;
  Uint8List? _currentFrame;

  bool _audioPublished = false;
  LocalAudioTrack? _pendingAudioTrack;
  Timer? _audioDelayTimer;

  final FrameBuffer _frameBuffer = FrameBuffer();
  Timer? _renderTimer;

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

  Future<void> _initializeNativePipeline() async {
    try {
      NativeVideoPlugin.onEncryptedFrame((data, viewerId) {
        _handleNativeEncryptedFrame(data, viewerId);
      });
    } catch (e) {
      print('[NATIVE_PIPELINE] Failed to initialize: $e');
      _useNativePipeline = false;
    }
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

      print(
          '[DEBUG] Request URL: https://socket-server-eight-eta.vercel.app/get-livekit-token');
      print('[DEBUG] User ID: $userId');
      print('[DEBUG] Stream ID: ${widget.streamId}');
      print('[DEBUG] Is Streamer: ${widget.isStreamer}');

      final response = await http.post(
        Uri.parse(
            'https://socket-server-eight-eta.vercel.app/get-livekit-token'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'identity': userId,
          'roomName': widget.streamId,
          'isPublisher': widget.isStreamer,
        }),
      );

      print('[DEBUG] Response status: ${response.statusCode}');
      print('[DEBUG] Response body: ${response.body}');

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

        await _initializeCameraPreview();

        _pendingAudioTrack = await LocalAudioTrack.create();

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
        if (widget.streamerId.isEmpty) {
          throw Exception('Streamer ID is missing or invalid');
        }

        await _liveKitService.connectAsViewer(widget.liveKitUrl, liveKitToken);

        _liveKitService.onData((Uint8List data, RemoteParticipant participant) {
          final senderId = participant.identity;
          _handleEncryptedFrame(data, senderId);
        });

        _performKeyExchange();
      }

      setState(() {
        _isLoading = false;
      });
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
      } catch (e) {
        print('[AUDIO_SYNC] Error publishing delayed audio: $e');
      }
    });
  }

  Future<void> _onViewerConnected(String viewerId) async {
    try {
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
        final success = await NativeVideoPlugin.addViewer(
          viewerId: viewerId,
          aesKey: aesKey,
        );

        if (success && _connectedViewers.length == 1) {
          _startNativePipeline();
        }
      }
    } catch (e) {
      print('[STREAMER] Error handling viewer connection: $e');
    }
  }

  Future<void> _onViewerDisconnected(String viewerId) async {
    if (_useNativePipeline) {
      await NativeVideoPlugin.removeViewer(viewerId);
    }
  }

  Future<void> _startNativePipeline() async {
    if (!NativeVideoPlugin.isAvailable) {
      setState(() {
        _hasError = true;
      });
      return;
    }

    try {
      final success = await NativeVideoPlugin.startVideoStream(
        streamId: widget.streamId,
        viewers: _connectedViewers.toList(),
      );

      if (success && _cameraController.value.isInitialized) {
        _nativePipelineActive = true;

        if (!_isImageStreamActive) {
          _cameraController.startImageStream((CameraImage image) {
            if (_nativePipelineActive) {
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
    } catch (e) {
      print('[NATIVE_PIPELINE] Error stopping native pipeline: $e');
    }
  }

  void _handleNativeEncryptedFrame(Uint8List data, String viewerId) {
    _liveKitService.publishVideoFrameImmediate(data,
        destinationIdentities: [viewerId]).catchError((error) {
      print('[FRAME_ERROR] Failed to send frame: $error');
    });
  }

  void _performKeyExchange() async {
    final userId = FirebaseAuth.instance.currentUser!.uid;

    bool keyExchangeSuccess = false;
    int attempts = 0;
    const maxAttempts = 10;

    while (!keyExchangeSuccess && attempts < maxAttempts && mounted) {
      attempts++;

      try {
        final keyExchange = await StreamKeyExchangeService.generateSharedSecret(
          userId,
          widget.streamerId,
          false,
          streamId: widget.streamId,
        );

        if (keyExchange['success'] == true) {
          await _preloadViewerKey();

          if (mounted) {
            setState(() {
              _isEncryptionReady = true;
            });
          }
          keyExchangeSuccess = true;
          break;
        } else {
          await Future.delayed(const Duration(seconds: 2));
        }
      } catch (e) {
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

      await _handleSingleFrame(payload, senderId);
    } catch (e) {
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
      const minPayloadSize = StreamCryptoService.nonceLength + 4 + 8;
      if (payload.length < minPayloadSize) {
        return;
      }

      final nonce = payload.sublist(0, StreamCryptoService.nonceLength);
      final timestampOffset = payload.length - 12;
      final timestamp = payload.buffer.asByteData().getInt32(timestampOffset);

      int? frameId;
      try {
        final frameIdOffset = payload.length - 8;
        frameId = payload.buffer.asByteData().getUint64(frameIdOffset);
      } catch (e) {
        frameId = receiveTime;
      }

      final encrypted =
          payload.sublist(StreamCryptoService.nonceLength, timestampOffset);

      Uint8List? aesKey = _cachedKeys[senderId];
      if (aesKey == null) {
        aesKey = await StreamKeyExchangeService.getStreamKey(
          widget.streamId,
          otherUserId: senderId,
        );
        if (aesKey == null) {
          return;
        }
        _cachedKeys[senderId] = aesKey;
      }

      Uint8List? decrypted;

      try {
        decrypted = await NativeVideoPlugin.decryptFrame(
          encrypted: encrypted,
          aesKey: aesKey,
          nonce: nonce,
          streamId: widget.streamId,
          timestamp: timestamp,
        );
      } catch (e) {
        try {
          decrypted = await compute(_isolateDecryptFrame, {
            'encrypted': encrypted,
            'nonce': nonce,
            'aesKey': aesKey,
            'streamId': widget.streamId,
            'timestamp': timestamp,
          });
        } catch (fallbackError) {
          print('[VIEWER] Dart decryption also failed: $fallbackError');
          return;
        }
      }

      if (decrypted == null) {
        return;
      }

      _viewerFramesReceived++;

      _frameBuffer.updateFrame(decrypted, frameId ?? receiveTime);
      _startFrameRenderer();

      if (mounted) {
        setState(() {
          _remoteVideoConnected = true;
        });
      }
    } catch (e, stackTrace) {
      print('[VIEWER] Critical error in frame handling: $e');
      print('[VIEWER] Stack trace: $stackTrace');
    }
  }

  void _startFrameRenderer() {
    if (_renderTimer != null) return;

    _renderTimer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      final frame = _frameBuffer.consumeLatestFrame();
      if (frame != null && mounted) {
        setState(() {
          _currentFrame = frame;
        });

        WidgetsBinding.instance.addPostFrameCallback((_) {
          _frameBuffer.setProcessingComplete();
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
                  child: _buildVideoDisplay(),
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
