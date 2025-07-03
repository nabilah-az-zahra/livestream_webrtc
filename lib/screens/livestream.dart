import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/foundation.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:typed_data';
import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:livestream_webrtc/signaling.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:livestream_webrtc/exchange_service.dart';
import 'package:livestream_webrtc/e2ee_service.dart';
import 'package:livestream_webrtc/logger.dart';

class LiveStreamPage extends StatefulWidget {
  final String streamTitle;
  final String streamerId;
  final String streamerUsername;
  final String streamId;
  final bool isStreamer;

  const LiveStreamPage({
    super.key,
    required this.streamTitle,
    required this.streamerId,
    required this.streamerUsername,
    required this.streamId,
    required this.isStreamer,
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

class ConnectionMonitor {
  final RTCPeerConnection peerConnection;
  final String streamId;
  final Function() onConnectionLost;
  final Function() onConnectionRestored;
  Timer? _monitorTimer;
  Timer? _reconnectTimer;
  bool _wasConnected = false;
  int _reconnectAttempts = 0;
  static const int maxReconnectAttempts = 5;

  ConnectionMonitor({
    required this.peerConnection,
    required this.streamId,
    required this.onConnectionLost,
    required this.onConnectionRestored,
  }) {
    _setupConnectionMonitoring();
  }

  void _setupConnectionMonitoring() {
    peerConnection.onConnectionState = (RTCPeerConnectionState state) {
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _wasConnected = true;
          _reconnectAttempts = 0;
          onConnectionRestored();
          break;

        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          if (_wasConnected) {
            _handleDisconnection();
          }
          break;

        default:
          break;
      }
    };

    _monitorTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      _checkConnection();
    });
  }

  void _handleDisconnection() {
    onConnectionLost();

    if (_reconnectAttempts < maxReconnectAttempts) {
      _reconnectTimer = Timer(const Duration(seconds: 3), () {
        _attemptReconnection();
      });
    } else {
      // print('Max reconnection attempts reached');
    }
  }

  Future<void> _attemptReconnection() async {
    _reconnectAttempts++;

    try {
      final offer = await peerConnection.createOffer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': true,
        'iceRestart': true
      });

      await peerConnection.setLocalDescription(offer);

      await FirebaseFirestore.instance.collection('connection_logs').add({
        'streamId': streamId,
        'event': 'reconnection_attempt',
        'attempt': _reconnectAttempts,
        'timestamp': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print('Reconnection attempt failed: $e');

      if (_reconnectAttempts < maxReconnectAttempts) {
        _reconnectTimer = Timer(
            Duration(seconds: _reconnectAttempts * 2), _attemptReconnection);
      }
    }
  }

  Future<void> _checkConnection() async {
    if (peerConnection.connectionState ==
        RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
      final stats = await peerConnection.getStats();
      bool hasActiveDataChannel = false;

      stats.forEach((stat) {
        if (stat.type == 'data-channel' && stat.values['state'] == 'open') {
          hasActiveDataChannel = true;
        }
      });

      if (!hasActiveDataChannel) {
        _handleDisconnection();
      }
    }
  }

  void dispose() {
    _monitorTimer?.cancel();
    _reconnectTimer?.cancel();
  }
}

class _LiveStreamPageState extends State<LiveStreamPage> {
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final _signalingService = SignalingService();
  final Map<String, RTCPeerConnection> _peerConnections = {};
  final Map<String, bool> _connectionStates = {};
  final List<RTCIceCandidate> _pendingCandidates = [];
  final Map<String, RTCDataChannel> _viewerDataChannels = {};
  final GlobalKey _previewContainerKey = GlobalKey();
  final Map<String, Uint8List?> _cachedKeys = {};

  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _encryptedVideoChannel;
  Timer? _frameTimer;
  Timer? _keyRotationTimer;
  Timer? _keyRefreshTimer;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  ConnectionMonitor? _connectionMonitor;
  Uint8List? _currentFrame;

  bool _isLoading = true;
  bool _hasError = false;
  bool _remoteVideoConnected = false;
  bool _isDisposed = false;
  bool _remoteDescriptionSet = false;
  bool _isEncryptionReady = false;
  bool _isFrameSendingActive = false;

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
      _initializeStream().then((_) {
        if (widget.isStreamer) {
          _startEncryptedFrameSender();

          Timer(const Duration(seconds: 1), () {
            print(
                '[STREAMER] 1-second check - Frame sending active: $_isFrameSendingActive');
            print(
                '[STREAMER] Connected viewers: ${_viewerDataChannels.length}');
          });

          Timer(const Duration(seconds: 3), () {
            _isFrameSendingActive = true;
            print('[STREAMER] Frame sending activated after 3 seconds');
            print('[STREAMER] Data channels status:');
            _viewerDataChannels.forEach((viewerId, dc) {
              print('  - $viewerId: ${dc.state}');
            });
          });

          Timer(const Duration(seconds: 5), () {
            if (!_isFrameSendingActive) {
              _isFrameSendingActive = true;
              print('[STREAMER] Frame sending force-activated after 5 seconds');
            }
          });
        }
      });
      _listenToStreamStatus();
      _initializeChat();
      _setupKeyRotation();
    } else {
      Navigator.pushReplacementNamed(context, '/login');
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
        true, // isStreamer
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
        // Non-retryable error
        break;
      }
    }

    print(
        '[KEY_EXCHANGE][ERROR] Could not establish shared key for viewer $viewerId after retries');
  }

  Future<void> _setupEncryptedDataChannel(
      RTCPeerConnection pc, String viewerId, String socketId) async {
    if (widget.isStreamer && viewerId != null) {
      // Streamer creating data channel for specific viewer
      final dataChannelInit = RTCDataChannelInit()
        ..ordered = true
        ..protocol = 'video-e2ee'
        ..negotiated = false;

      try {
        final dataChannel =
            await pc.createDataChannel('video-e2ee', dataChannelInit);

        print('[STREAMER] Created data channel: ${dataChannel.label}');
        print(
            '[STREAMER] Data channel init params: ordered=${dataChannelInit.ordered}, protocol=${dataChannelInit.protocol}');

        dataChannel.onDataChannelState = (state) {
          print('[STREAMER] Data channel for $viewerId state: $state');
          if (state == RTCDataChannelState.RTCDataChannelOpen) {
            _viewerDataChannels[viewerId] = dataChannel;
            print('[STREAMER] Viewer $viewerId data channel is open');
          } else if (state == RTCDataChannelState.RTCDataChannelClosed ||
              state == RTCDataChannelState.RTCDataChannelClosing) {
            _viewerDataChannels.remove(viewerId);
            print('[STREAMER] Viewer $viewerId data channel closed');
          }
        };

        if (_localStream != null) {
          for (final track in _localStream!.getTracks()) {
            await pc.addTrack(track, _localStream!);
          }
        }

        final offer = await pc.createOffer({
          'offerToReceiveAudio': true,
          'offerToReceiveVideo': true,
          'iceRestart': true,
        });

        print('[SIGNALING] Offer sent to $socketId for viewerId: $viewerId');

        await pc.setLocalDescription(offer);
        await _waitForIceGathering(pc);

        print('[STREAMER] Sending offer to viewer: $viewerId');
        _signalingService.sendOffer(widget.streamId, socketId, offer);
      } catch (e) {
        print('[ERROR] Exception creating DataChannel for $viewerId: $e');
      }
      // _viewerDataChannels[viewerId] = dataChannel;
    } else {
      print('[VIEWER] Data channel setup handled via onDataChannel callback');
    }
  }

  Future<void> _initializeStream() async {
    try {
      await _remoteRenderer.initialize();

      if (widget.isStreamer) {
        await _initializeStreamer();
      } else {
        if (widget.streamerId.isEmpty) {
          throw Exception('Streamer ID is missing or invalid');
        }

        // For viewer, exchange keys with streamer
        final keyExchange = await StreamKeyExchangeService.generateSharedSecret(
          FirebaseAuth.instance.currentUser!.uid,
          widget.streamerId,
          false,
          streamId: widget.streamId,
        );

        if (!keyExchange['success']) {
          throw Exception('Failed to exchange keys: ${keyExchange['error']}');
        }

        if (keyExchange['exchangeId'] == null ||
            keyExchange['exchangeId'].isEmpty) {
          print('Error: exchangeId is null or empty');
          throw Exception('Exchange ID is invalid');
        }

        print(
            'Key exchange successful - Exchange ID: ${keyExchange['exchangeId']}');

        final verification = await StreamKeyExchangeService.verifyKeyExchange(
          keyExchange['exchangeId'],
          streamId: widget.streamId,
        );

        if (verification['verified']) {
          // print('Exchange verified successfully');
          // print('Exchange details: ${verification['exchange']}');
          // print('Exchange logs: ${verification['logs']}');
        } else {
          throw Exception('Key exchange verification failed');
        }

        await _initializeViewer();
      }

      setState(() {
        _isLoading = false;
      });
    } catch (e) {
      print('Error in stream initialization: $e');
      setState(() {
        _hasError = true;
      });
    }
  }

  Future<bool> _isRepaintBoundaryReady() async {
    try {
      await Future.delayed(Duration(milliseconds: 500));
      final boundary = _previewContainerKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) return false;

      // Try to capture a test image
      final image = await boundary.toImage(pixelRatio: 1.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      return byteData != null;
    } catch (e) {
      print('[STREAMER] RepaintBoundary not ready: $e');
      return false;
    }
  }

  void _startEncryptedFrameSender() {
    _keyRefreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _cachedKeys.clear();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      Timer.periodic(const Duration(milliseconds: 100), (checkTimer) async {
        if (await _isRepaintBoundaryReady()) {
          checkTimer.cancel();
          print('[STREAMER] RepaintBoundary is ready, starting frame timer');

          _frameTimer =
              Timer.periodic(const Duration(milliseconds: 500), (_) async {
            try {
              if (!_isFrameSendingActive) {
                print('[STREAMER] Frame sending not active, skipping frame');
                return;
              }

              final List<String> connectedViewers = [];

              _viewerDataChannels.forEach((viewerId, dataChannel) {
                final state = dataChannel.state;
                print('[STREAMER] Viewer $viewerId data channel state: $state');
                if (state == RTCDataChannelState.RTCDataChannelOpen) {
                  connectedViewers.add(viewerId);
                }
              });

              if (connectedViewers.isEmpty) {
                print('[STREAMER] No connected viewers found, skipping frame');
                return;
              }

              print('[STREAMER] Connected viewers: ${connectedViewers.length}');

              final boundary = _previewContainerKey.currentContext
                  ?.findRenderObject() as RenderRepaintBoundary?;
              if (boundary == null) {
                print('[STREAMER] Boundary is null, skipping frame');
                return;
              }

              final image = await boundary.toImage(pixelRatio: 1.0);
              final byteData =
                  await image.toByteData(format: ui.ImageByteFormat.png);
              if (byteData == null || byteData.lengthInBytes == 0) {
                print('[DEBUG] Captured image is empty or null');
              }

              final bytes = byteData?.buffer.asUint8List();
              if (bytes == null) {
                print('[STREAMER] Failed to get image bytes, skipping frame');
                return;
              }

              print('[STREAMER] Captured frame: ${bytes.length} bytes');

              if (!kIsWeb && Platform.isAndroid) {
                try {
                  final dir = await getApplicationDocumentsDirectory();
                  final file = File(
                      '${dir.path}/debug_frame_${DateTime.now().millisecondsSinceEpoch}.png');
                  await file.writeAsBytes(bytes);
                  print(
                      '[DEBUG] Streamer saved captured frame to: ${file.path}');
                } catch (e) {
                  print('[DEBUG] Could not save frame to file: $e');
                }
              }

              for (final viewerId in connectedViewers) {
                await _sendEncryptedFrame(viewerId, bytes);
              }
            } catch (e) {
              print('[STREAMER] Frame encryption/send error: $e');
            }
          });
        } else {
          print('[STREAMER] Waiting for RepaintBoundary to be ready...');
        }
      });
    });
  }

  Future<void> _dumpEncrypted(Uint8List encrypted) async {
    if (await Permission.storage.request().isDenied) return;

    final dir = await getDownloadsDirectory();
    final filePath =
        '${dir!.path}/cipher_${DateTime.now().millisecondsSinceEpoch}.bin';
    await File(filePath).writeAsBytes(encrypted, flush: true);
    print('[E2EE] Cipher dump → $filePath');
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

      final nonce = StreamCryptoService.generateNonce();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final aad = StreamCryptoService.buildAad(widget.streamId, timestamp);
      final cipher =
          StreamCryptoService.createAesGcmCipher(true, aesKey, nonce, aad: aad);

      final sw = Stopwatch()..start();
      final encrypted = cipher.process(bytes);
      sw.stop();
      final encMs = sw.elapsedMicroseconds / 1000.0;

      _dumpEncrypted(encrypted);

      EncryptionLogger.logCryptoTiming(
        streamId: widget.streamId,
        operation: 'encrypt',
        frameSize: bytes.length,
        durationMs: encMs,
        success: true,
      );

      final payload =
          Uint8List(StreamCryptoService.nonceLength + encrypted.length + 4);
      payload.setRange(0, StreamCryptoService.nonceLength, nonce);
      payload.setRange(StreamCryptoService.nonceLength,
          StreamCryptoService.nonceLength + encrypted.length, encrypted);
      payload.buffer.asByteData().setUint32(
          StreamCryptoService.nonceLength + encrypted.length, timestamp);

      final encoded = base64.encode(payload);
      print('[STREAMER] Frame details for $viewerId:');
      print('  - Original bytes: ${bytes.length}');
      print('  - Encrypted bytes: ${encrypted.length}');
      print('  - Payload bytes: ${payload.length}');
      print('  - Encoded length: ${encoded.length}');
      print('  - Data channel state: ${_viewerDataChannels[viewerId]?.state}');

      final dc = _viewerDataChannels[viewerId];
      if (dc != null && dc.state == RTCDataChannelState.RTCDataChannelOpen) {
        try {
          dc.send(RTCDataChannelMessage(encoded));
          print('[STREAMER] Frame sent successfully to viewer: $viewerId');
        } catch (sendError) {
          print('[STREAMER] Error sending frame to $viewerId: $sendError');
        }
      } else {
        print(
            '[STREAMER] Data channel not ready for $viewerId. State: ${dc?.state}');
      }
    } catch (e) {
      EncryptionLogger.logCryptoTiming(
        streamId: widget.streamId,
        operation: 'encrypt',
        frameSize: bytes.length,
        durationMs: 0,
        success: false,
        error: e.toString(),
      );
      print('[STREAMER] Error sending frame to $viewerId: $e');
    }
  }

  Future<void> _initializeStreamer() async {
    await _localRenderer.initialize();

    _localStream = await navigator.mediaDevices.getUserMedia({
      'video': {
        'facingMode': 'user',
        'width': {'ideal': 1920},
        'height': {'ideal': 1080},
      },
      'audio': true,
    });

    _localRenderer.srcObject = _localStream;
    print(
        '[STREAMER] Local stream tracks: ${_localStream?.getTracks().map((t) => t.kind)}');

    final currentUserId = FirebaseAuth.instance.currentUser?.uid;
    if (currentUserId == null) throw Exception('Not logged in');

    final encryptionVerified = await StreamCryptoService.verifyEncryption(
      widget.streamId,
      currentUserId,
    );
    if (!encryptionVerified) {
      throw Exception('Failed to verify stream encryption');
    }

    await _setupStreamerConnection();
  }

  Future<void> _initializeViewer() async {
    final currentUserId = FirebaseAuth.instance.currentUser?.uid;
    if (currentUserId == null) throw Exception('Not logged in');

    final encryptionVerified = await StreamCryptoService.verifyEncryption(
        widget.streamId, widget.streamerId);
    if (!encryptionVerified) {
      throw Exception('Failed to verify stream encryption');
    }

    await _setupViewerConnection();
  }

  Future<RTCPeerConnection> _createPeerConnection() async {
    if (_isDisposed) {
      throw Exception('Cannot create connection after disposal');
    }

    final configuration = {
      'iceServers': [
        {
          'urls': [
            'stun:stun.l.google.com:19302',
            'stun:stun1.l.google.com:19302',
            'stun:stun2.l.google.com:19302',
            'stun:stun3.l.google.com:19302',
            'stun:stun4.l.google.com:19302',
          ],
        }
      ],
      'sdpSemantics': 'unified-plan',
      'iceTransportPolicy': 'all',
      'bundlePolicy': 'max-bundle',
      'rtcpMuxPolicy': 'require',
    };

    final conn = await createPeerConnection(configuration);
    if (conn == null) {
      throw Exception('Failed to create peer connection');
    }
    return conn;
  }

  Future<RTCPeerConnection?> _initPeerConnection(String viewerId) async {
    if (_isDisposed) return null;

    print('Creating new peer connection for viewer: $viewerId');

    try {
      final configuration = {
        'iceServers': [
          {
            'urls': [
              'stun:stun.l.google.com:19302',
              'stun:stun1.l.google.com:19302',
              'stun:stun2.l.google.com:19302',
              'stun:stun3.l.google.com:19302',
              'stun:stun4.l.google.com:19302',
            ],
          }
        ],
        'sdpSemantics': 'unified-plan',
        'iceTransportPolicy': 'all',
        'bundlePolicy': 'max-bundle',
        'rtcpMuxPolicy': 'require',
      };

      final peerConnection = await createPeerConnection(configuration);
      if (peerConnection == null) return null;

      // Set up connection state monitoring
      peerConnection.onConnectionState = (RTCPeerConnectionState state) {
        // print('Connection state for $viewerId: $state');
        if (state ==
                RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
          _cleanupPeerConnection(viewerId);
        }
      };

      peerConnection.onSignalingState = (RTCSignalingState state) {
        print('[SIGNALING] Signaling state for $viewerId: $state');
      };

      peerConnection.onIceConnectionState = (RTCIceConnectionState state) {
        print('[ICE] ICE connection state for $viewerId: $state');
      };

      peerConnection.onIceCandidate = (RTCIceCandidate? candidate) {
        if (candidate != null &&
            !_isDisposed &&
            _connectionStates[viewerId] == true) {
          _signalingService.sendIceCandidate(
            widget.streamId,
            candidate,
            targetId: viewerId,
          );
        }
      };

      return peerConnection;
    } catch (e) {
      print('Error initializing peer connection: $e');
      return null;
    }
  }

  Future<void> _setupStreamerConnection() async {
    try {
      _signalingService.connect();
      _signalingService.joinStream(widget.streamId, true);

      _signalingService.onViewerJoined((data) async {
        final firebaseUserId = data['firebaseUserId'];
        final socketId = data['socketId'];

        final currentUserId = FirebaseAuth.instance.currentUser?.uid;
        if (currentUserId == null || firebaseUserId == null) return;
        print('Setting up connection for viewer: $firebaseUserId');

        final result = await StreamKeyExchangeService.generateSharedSecret(
          currentUserId,
          firebaseUserId,
          true,
          streamId: widget.streamId,
        );

        if (!result['success']) {
          print(
              'Failed to generate shared key for viewer $firebaseUserId: ${result['error']}');
          return;
        }

        await Future.delayed(const Duration(milliseconds: 500));

        if (_peerConnections.containsKey(firebaseUserId)) {
          print(
              '[WARN] Peer connection for $firebaseUserId already exists. Skipping.');
          return;
        }

        final peerConnection = await _initPeerConnection(firebaseUserId);
        if (peerConnection == null) {
          print(
              '[ERROR] Failed to initialize peer connection for $firebaseUserId');
          return;
        }

        print('Creating new peer connection for viewer: $firebaseUserId');
        _peerConnections[firebaseUserId] = peerConnection;
        _connectionStates[firebaseUserId] = true;

        await _setupEncryptedDataChannel(
            peerConnection, firebaseUserId, socketId);
      });

      _signalingService.onAnswer((data) async {
        final viewerId = data['viewerId'];
        final socketId = data['socketId'];
        print(
            '[SIGNALING] Received answer from viewerId: $viewerId, socketId: $socketId');

        if (_isDisposed || _connectionStates[viewerId] != true) return;

        final peerConnection = _peerConnections[viewerId];
        if (peerConnection == null) return;

        try {
          if (peerConnection.signalingState !=
              RTCSignalingState.RTCSignalingStateClosed) {
            print('[SIGNALING] Received answer from viewerId: $viewerId');
            print(
                '[SIGNALING] Current keys in _peerConnections: ${_peerConnections.keys}');

            final answer = RTCSessionDescription(
              data['answer']['sdp'],
              data['answer']['type'],
            );
            await peerConnection.setRemoteDescription(answer);
            print('[SIGNALING] Remote description set for viewerId: $viewerId');
            print(
                '[SIGNALING] Current ICE connection state: ${peerConnection.iceConnectionState}');
            print(
                '[SIGNALING] Current signaling state: ${peerConnection.signalingState}');
          }
        } catch (e) {
          print('Error handling answer from $viewerId: $e');
          await _cleanupPeerConnection(viewerId);
        }
      });

      _signalingService.onIceCandidate((data) async {
        final viewerId = data['viewerId'];
        if (_isDisposed || _connectionStates[viewerId] != true) return;

        final peerConnection = _peerConnections[viewerId];
        if (peerConnection == null) return;

        try {
          if (peerConnection.signalingState !=
              RTCSignalingState.RTCSignalingStateClosed) {
            final candidateData = data['candidate'];
            final candidate = RTCIceCandidate(
              candidateData['candidate'],
              candidateData['sdpMid'],
              int.parse(candidateData['sdpMLineIndex']?.toString() ?? '0'),
            );
            await peerConnection.addCandidate(candidate);
          }
        } catch (e) {
          print('Error handling ICE candidate for $viewerId: $e');
        }
      });
    } catch (e) {
      print('Error in setupStreamerConnection: $e');
      rethrow;
    }
  }

  Future<void> _waitForIceGathering(RTCPeerConnection peerConnection) async {
    final completer = Completer<void>();

    if (peerConnection.iceGatheringState ==
        RTCIceGatheringState.RTCIceGatheringStateComplete) {
      print('[ICE] Gathering already complete');
      completer.complete();
    } else {
      peerConnection.onIceGatheringState = (state) {
        print('[ICE] Gathering state changed to: $state');
        if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) {
          peerConnection.onIceGatheringState = null;
          if (!completer.isCompleted) completer.complete();
        }
      };
      Future.delayed(const Duration(seconds: 10), () {
        if (!completer.isCompleted) {
          print('[ICE] Gathering timeout — continuing anyway');
          peerConnection.onIceGatheringState = null;
          completer.complete();
        }
      });
    }
    return completer.future;
  }

  Future<void> _setupViewerConnection() async {
    try {
      String? _streamerSocketId;

      _peerConnection = await _createPeerConnection();

      _signalingService.connect();
      _signalingService.joinStream(widget.streamId, false);

      _signalingService.onOffer((data) async {
        if (data['type'] != null && data['sdp'] != null) {
          try {
            _streamerSocketId = data['streamerId'];
            if (_streamerSocketId == null) {
              print('[ERROR] streamerId missing in offer data');
              return;
            }

            print('[VIEWER] Binding onDataChannel callback...');

            _peerConnection?.onDataChannel = (RTCDataChannel channel) {
              print('[VIEWER] Data channel received: ${channel.label}');
              if (channel.label == 'video-e2ee') {
                _encryptedVideoChannel = channel;

                _encryptedVideoChannel?.onDataChannelState = (state) {
                  print('[VIEWER] Data channel state changed to: $state');
                  if (state == RTCDataChannelState.RTCDataChannelOpen) {
                    print(
                        '[VIEWER] Data channel is open and ready to receive frames');
                    setState(() {
                      _isEncryptionReady = true;
                      print(
                          '[VIEWER] _isEncryptionReady = $_isEncryptionReady');
                    });
                    _preloadViewerKey();
                  }
                };

                _encryptedVideoChannel?.onMessage =
                    (RTCDataChannelMessage message) {
                  print(
                      '[VIEWER] Received encrypted frame data: ${message.text.length} characters');
                  _handleEncryptedFrame(message.text);
                };
              }
            };

            final offer = RTCSessionDescription(data['sdp'], data['type']);
            print('[VIEWER] Setting remote description...');
            await _peerConnection?.setRemoteDescription(offer);
            print('[VIEWER] Remote description set!');
            _remoteDescriptionSet = true;

            if (_pendingCandidates.isNotEmpty) {
              for (var candidate in _pendingCandidates) {
                await _peerConnection?.addCandidate(candidate);
              }
              _pendingCandidates.clear();
            }

            print('[VIEWER] Received offer. Creating and sending answer...');
            final answer = await _peerConnection?.createAnswer({
              'offerToReceiveAudio': true,
              'offerToReceiveVideo': true,
            });

            if (answer != null) {
              await _peerConnection?.setLocalDescription(answer);
              _signalingService.sendAnswer(widget.streamId, answer);
            }
          } catch (e) {
            print('Error handling offer: $e');
          }
        }
      });

      _signalingService.onIceCandidate((data) async {
        try {
          if (data['candidate'] != null) {
            final candidateData = data['candidate'];
            final candidate = RTCIceCandidate(
              candidateData['candidate'],
              candidateData['sdpMid'],
              candidateData['sdpMLineIndex'],
            );

            if (_remoteDescriptionSet) {
              await _peerConnection?.addCandidate(candidate);
            } else {
              _pendingCandidates.add(candidate);
            }
          }
        } catch (e) {
          print('Error handling ICE candidate: $e');
        }
      });

      _peerConnection?.onIceCandidate = (candidate) {
        if (candidate != null && _streamerSocketId != null) {
          print('Viewer sending ICE candidate: ${candidate.candidate}');
          _signalingService.sendIceCandidate(
            widget.streamId,
            candidate,
            targetId: _streamerSocketId!,
          );
        }
      };

      _peerConnection?.onTrack = (RTCTrackEvent event) {
        if (event.streams.isNotEmpty) {
          setState(() {
            _remoteStream = event.streams[0];
            _remoteRenderer.srcObject = _remoteStream;
            if (event.track.kind == 'video') {
              _remoteVideoConnected = true;
            }
          });
        }
      };

      _connectionMonitor = ConnectionMonitor(
        peerConnection: _peerConnection!,
        streamId: widget.streamId,
        onConnectionLost: () {
          setState(() {
            _remoteVideoConnected = false;
          });
        },
        onConnectionRestored: () {
          setState(() {
            _remoteVideoConnected = true;
          });
        },
      );
    } catch (e) {
      print('Error in setupViewerConnection: $e');
      rethrow;
    }
  }

  Future<void> _handleEncryptedFrame(String encodedFrame) async {
    try {
      if (encodedFrame.isEmpty) {
        print('[VIEWER] Received empty frame data');
        return;
      }

      final payload = base64.decode(encodedFrame);
      if (payload.length < StreamCryptoService.nonceLength + 4) {
        print('[VIEWER] Payload too short: ${payload.length}');
        return;
      }

      final nonce = payload.sublist(0, StreamCryptoService.nonceLength);
      final timestamp =
          payload.buffer.asByteData().getUint32(payload.length - 4);
      final encrypted =
          payload.sublist(StreamCryptoService.nonceLength, payload.length - 4);

      print(
          '[VIEWER] Processing frame - nonce: ${nonce.length}, encrypted: ${encrypted.length}, timestamp: $timestamp');

      Uint8List? aesKey = _cachedKeys[widget.streamerId];
      if (aesKey == null) {
        aesKey = await StreamKeyExchangeService.getStreamKey(widget.streamId,
            otherUserId: widget.streamerId);
        if (aesKey == null) {
          print('[VIEWER] No AES key available');
          return;
        }
        _cachedKeys[widget.streamerId] = aesKey;
        print('[VIEWER] AES key retrieved and cached');
      }

      final aad = StreamCryptoService.buildAad(widget.streamId, timestamp);
      final cipher = StreamCryptoService.createAesGcmCipher(
          false, aesKey, nonce,
          aad: aad);

      final sw = Stopwatch()..start();
      final decrypted = cipher.process(encrypted);
      sw.stop();
      final decMs = sw.elapsedMicroseconds / 1000.0;

      EncryptionLogger.logCryptoTiming(
        streamId: widget.streamId,
        operation: 'decrypt',
        frameSize: decrypted.length,
        durationMs: decMs,
        success: true,
      );

      print('[VIEWER] Frame decrypted successfully: ${decrypted.length} bytes');

      try {
        ui.decodeImageFromList(decrypted, (image) async {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          canvas.drawImage(image, Offset.zero, Paint());

          final picture = recorder.endRecording();
          final img = await picture.toImage(image.width, image.height);
          final byteData = await img.toByteData(format: ui.ImageByteFormat.png);

          if (byteData != null && mounted) {
            setState(() {
              _currentFrame = byteData.buffer.asUint8List();
              _remoteVideoConnected = true;
            });
            print('[VIEWER] Canvas-drawn frame rendered');
          }
        });
      } catch (e) {
        print('[DEBUG] PNG decode failed: $e');
      }
    } catch (e) {
      EncryptionLogger.logCryptoTiming(
        streamId: widget.streamId,
        operation: 'decrypt',
        frameSize: 0,
        durationMs: 0,
        success: false,
        error: e.toString(),
      );
      print('[VIEWER] Frame decryption error: $e');
      print('[VIEWER] Stack trace: ${StackTrace.current}');
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

  Future<void> _cleanupPeerConnection(String viewerId) async {
    _connectionStates[viewerId] = false;
    final peerConnection = _peerConnections[viewerId];
    if (peerConnection != null) {
      try {
        await peerConnection.close();
        await peerConnection.dispose();
        // print('Cleaned up connection for viewer: $viewerId');
      } catch (e) {
        print('Error cleaning up connection for $viewerId: $e');
      }
      _peerConnections.remove(viewerId);
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

  @override
  void dispose() {
    _keyRotationTimer?.cancel();
    _keyRefreshTimer?.cancel();
    _isFrameSendingActive = false;
    _cachedKeys.clear();
    _encryptedVideoChannel?.close();
    if (widget.isStreamer) {
      _endStream();
      StreamKeyExchangeService.cleanupStreamKeys(widget.streamId);
    }
    _isDisposed = true;
    for (final viewerId in _peerConnections.keys.toList()) {
      _cleanupPeerConnection(viewerId);
    }
    _frameTimer?.cancel();
    _viewerDataChannels.forEach((_, dc) => dc.close());
    _viewerDataChannels.clear();

    _signalingService.disconnect();
    _pendingCandidates.clear();
    _streamStatusSubscription?.cancel();
    _localStream?.getTracks().forEach((track) => track.stop());
    _localStream?.dispose();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    _peerConnection?.close();
    _peerConnection?.dispose();
    _chatSubscription?.cancel();
    _chatController.dispose();
    _chatFocusNode.dispose();
    super.dispose();
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

    // final screenSize = MediaQuery.of(context).size;
    // final videoHeight = screenSize.height * 0.4;

    return Scaffold(
      backgroundColor: const Color(0xFFE5E5E5),
      // appBar: AppBar(
      //   backgroundColor: Colors.transparent,
      //   elevation: 0,
      //   leading: IconButton(
      //     icon: const Icon(Icons.arrow_back, color: Colors.black),
      //     onPressed: () => Navigator.pop(context),
      //   ),
      //   actions: [
      //     IconButton(
      //       icon: const Icon(Icons.settings, color: Colors.black),
      //       onPressed: () {},
      //     ),
      //   ],
      // ),
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
                          child: RTCVideoView(
                            _localRenderer,
                            objectFit: RTCVideoViewObjectFit
                                .RTCVideoViewObjectFitCover,
                            mirror: true,
                          ),
                        )
                      : _currentFrame != null
                          ? Container(
                              decoration: BoxDecoration(
                                  border: Border.all(color: Colors.red)),
                              child: Image.memory(
                                _currentFrame!,
                                fit: BoxFit.contain,
                                gaplessPlayback: true,
                                key: ValueKey(
                                    DateTime.now().millisecondsSinceEpoch),
                                frameBuilder: (context, child, frame, wasSync) {
                                  if (frame == null) {
                                    return const Center(
                                      child: CircularProgressIndicator(
                                          color: Colors.white),
                                    );
                                  }
                                  return child;
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
                      // IconButton(
                      //   icon: const Icon(Icons.fullscreen, color: Colors.white),
                      //   onPressed: () {
                      //     //  fullscreen toggle
                      //   },
                      // ),
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
