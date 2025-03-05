import 'dart:async';
import 'dart:math';
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
  static const int MAX_RECONNECT_ATTEMPTS = 5;

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
      print('Connection state changed to: $state');

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
    print('Connection lost, attempting to recover...');
    onConnectionLost();

    if (_reconnectAttempts < MAX_RECONNECT_ATTEMPTS) {
      _reconnectTimer = Timer(const Duration(seconds: 3), () {
        _attemptReconnection();
      });
    } else {
      print('Max reconnection attempts reached');
    }
  }

  Future<void> _attemptReconnection() async {
    _reconnectAttempts++;
    print(
        'Attempting reconnection (${_reconnectAttempts}/${MAX_RECONNECT_ATTEMPTS})');

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

      if (_reconnectAttempts < MAX_RECONNECT_ATTEMPTS) {
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
        print('Data channel appears to be closed, attempting recovery...');
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
  final _signalingService = SignalingService('http://localhost:3000');
  final Map<String, RTCPeerConnection> _peerConnections = {};
  final Map<String, bool> _connectionStates = {};
  final List<RTCIceCandidate> _pendingCandidates = [];

  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _encryptedVideoChannel;
  Timer? _keyRotationTimer;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  ConnectionMonitor? _connectionMonitor;

  bool _isLoading = true;
  bool _hasError = false;
  bool _remoteVideoConnected = false;
  bool _isDisposed = false;
  bool _remoteDescriptionSet = false;
  bool _isEncryptionReady = false;

  StreamSubscription? _streamStatusSubscription;
  StreamSubscription? _chatSubscription;

  String _currentQuality = 'high';
  final Map<String, String> _viewerQualityPreferences = {};

  List<ChatMessage> chatMessages = [];

  final TextEditingController _chatController = TextEditingController();
  final FocusNode _chatFocusNode = FocusNode();

  final Map<String, Color> _userColors = {};

  @override
  void initState() {
    super.initState();
    if (FirebaseAuth.instance.currentUser != null) {
      _initializeStream();
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

  Future<void> _setupEncryptedDataChannel(RTCPeerConnection pc) async {
    final dataChannelInit = RTCDataChannelInit()
      ..ordered = true
      ..protocol = 'video-e2ee';

    _encryptedVideoChannel =
        await pc.createDataChannel('video-e2ee', dataChannelInit);

    if (widget.isStreamer) {
      await StreamCryptoService.encryptRtpSender(
        _encryptedVideoChannel!,
        widget.streamId,
        FirebaseAuth.instance.currentUser!.uid,
        widget.streamerId,
        true,
      );
    } else {
      await StreamCryptoService.decryptRtpReceiver(
        _encryptedVideoChannel!,
        widget.streamId,
        FirebaseAuth.instance.currentUser!.uid,
        widget.streamerId,
        false,
      );
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
          print('Exchange verified successfully');
          print('Exchange details: ${verification['exchange']}');
          print('Exchange logs: ${verification['logs']}');
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

    final encryptionVerified =
        await StreamCryptoService.verifyEncryption(widget.streamId);
    if (!encryptionVerified) {
      throw Exception('Failed to verify stream encryption');
    }

    setState(() {
      _isEncryptionReady = true;
    });

    await _setupStreamerConnection();
  }

  Future<void> _initializeViewer() async {
    final encryptionVerified =
        await StreamCryptoService.verifyEncryption(widget.streamId);
    if (!encryptionVerified) {
      throw Exception('Failed to verify stream encryption');
    }

    setState(() {
      _isEncryptionReady = true;
    });

    await _setupViewerConnection();

    _peerConnection?.onConnectionState = (RTCPeerConnectionState state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected &&
          _encryptedVideoChannel == null) {
        _setupEncryptedDataChannel(_peerConnection!);
      }

      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        setState(() {
          _remoteVideoConnected = true;
        });
      } else if (state ==
              RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        setState(() {
          _remoteVideoConnected = false;
        });
      }
    };

    if (!widget.isStreamer) {
      _currentQuality = 'high';
    }
  }

  Future<RTCPeerConnection> _createPeerConnection() async {
    if (_isDisposed) {
      throw Exception('Cannot create connection after disposal');
    }

    final configuration = {
      'iceServers': [
        {
          'urls': [
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

    try {
      final configuration = {
        'iceServers': [
          {
            'urls': [
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

      peerConnection.onConnectionState = (RTCPeerConnectionState state) {
        print('Connection state for $viewerId: $state');
        if (state ==
                RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
          _cleanupPeerConnection(viewerId);
        }
      };

      peerConnection.onIceGatheringState = (RTCIceGatheringState state) {
        print('ICE gathering state for $viewerId: $state');
      };

      peerConnection.onSignalingState = (RTCSignalingState state) {
        print('Signaling state for $viewerId: $state');
      };

      peerConnection.onIceCandidate = (RTCIceCandidate? candidate) {
        if (candidate != null &&
            !_isDisposed &&
            _connectionStates[viewerId] == true) {
          _signalingService.sendIceCandidate(widget.streamId, candidate);
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

      _setupQualityHandling();

      _signalingService.onViewerJoined((viewerId) async {
        print('Setting up connection for viewer: $viewerId');

        final peerConnection = await _initPeerConnection(viewerId);
        if (peerConnection == null) return;

        _peerConnections[viewerId] = peerConnection;
        _connectionStates[viewerId] = true;

        await _setupEncryptedDataChannel(peerConnection);
        await Future.delayed(const Duration(milliseconds: 1000));

        if (_localStream != null) {
          print('Adding local stream tracks');
          for (final track in _localStream!.getTracks()) {
            await peerConnection.addTrack(track, _localStream!);
          }
        }

        try {
          final offer = await peerConnection.createOffer({
            'offerToReceiveAudio': true,
            'offerToReceiveVideo': true,
            'iceRestart': true
          });

          print('Created offer, setting local description');
          await peerConnection.setLocalDescription(offer);

          await _waitForIceGathering(peerConnection);

          print('Sending offer to viewer: $viewerId');
          _signalingService.sendOffer(widget.streamId, viewerId, offer);
        } catch (e) {
          print('Error in connection setup: $e');
          await _cleanupPeerConnection(viewerId);
        }
      });

      _signalingService.onAnswer((data) async {
        final viewerId = data['viewerId'];
        print('Received answer from viewer: $viewerId');

        if (_isDisposed || _connectionStates[viewerId] != true) return;

        final peerConnection = _peerConnections[viewerId];
        if (peerConnection == null) return;

        try {
          if (peerConnection.signalingState !=
              RTCSignalingState.RTCSignalingStateClosed) {
            final answer = RTCSessionDescription(
              data['answer']['sdp'],
              data['answer']['type'],
            );
            await peerConnection.setRemoteDescription(answer);
            print('Remote description set for viewer: $viewerId');
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
            print('ICE candidate added for viewer: $viewerId');
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

  Future<void> _waitForIceGathering(RTCPeerConnection peerConnection) {
    final completer = Completer<void>();

    if (peerConnection.iceGatheringState ==
        RTCIceGatheringState.RTCIceGatheringStateComplete) {
      completer.complete();
    } else {
      peerConnection.onIceGatheringState = (RTCIceGatheringState state) {
        if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) {
          completer.complete();
        }
      };
    }

    return completer.future.timeout(const Duration(seconds: 5),
        onTimeout: () => print('ICE gathering timed out'));
  }

  Future<void> _setupViewerConnection() async {
    try {
      _peerConnection = await _createPeerConnection();
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
      await _setupEncryptedDataChannel(_peerConnection!);

      print('Setting up viewer connection');

      _peerConnection?.onIceCandidate = (candidate) {
        if (candidate != null) {
          print('Viewer sending ICE candidate: ${candidate.candidate}');
          _signalingService.sendIceCandidate(widget.streamId, candidate);
        }
      };

      _peerConnection?.onTrack = (RTCTrackEvent event) {
        print('Received track: ${event.track.kind}');
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

      _signalingService.connect();
      _signalingService.joinStream(widget.streamId, false);

      _signalingService.onOffer((data) async {
        print('Received offer from streamer');
        if (data['type'] != null && data['sdp'] != null) {
          try {
            final offer = RTCSessionDescription(data['sdp'], data['type']);
            await _peerConnection?.setRemoteDescription(offer);
            _remoteDescriptionSet = true;

            if (_pendingCandidates.isNotEmpty) {
              print('Adding ${_pendingCandidates.length} pending candidates');
              for (var candidate in _pendingCandidates) {
                await _peerConnection?.addCandidate(candidate);
              }
              _pendingCandidates.clear();
            }

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
            print('Received ICE candidate from streamer');
            final candidateData = data['candidate'];
            final candidate = RTCIceCandidate(
              candidateData['candidate'],
              candidateData['sdpMid'],
              candidateData['sdpMLineIndex'],
            );

            if (_remoteDescriptionSet) {
              await _peerConnection?.addCandidate(candidate);
            } else {
              print('Storing ICE candidate for later');
              _pendingCandidates.add(candidate);
            }
          }
        } catch (e) {
          print('Error handling ICE candidate: $e');
        }
      });

      _encryptedVideoChannel?.onMessage = (RTCDataChannelMessage message) {
        try {
          final data = jsonDecode(message.text);
          if (data['type'] == 'quality_changed' &&
              data['viewerId'] == FirebaseAuth.instance.currentUser!.uid) {
            print('Quality changed successfully to: ${data['quality']}');
            setState(() {
              _remoteVideoConnected = true;
            });
          }
        } catch (e) {
          print('Error processing data channel message: $e');
        }
      };
    } catch (e) {
      print('Error in setupViewerConnection: $e');
      rethrow;
    }
  }

  Future<void> _cleanupPeerConnection(String viewerId) async {
    _connectionStates[viewerId] = false;
    final peerConnection = _peerConnections[viewerId];
    if (peerConnection != null) {
      try {
        await peerConnection.close();
        await peerConnection.dispose();
        print('Cleaned up connection for viewer: $viewerId');
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

  void _showQualitySelectionDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1A1A1A),
          title: Text(
            'Video Quality',
            style: GoogleFonts.inter(color: Colors.white),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildQualityOption('Low (240p-480p)', 'low'),
              _buildQualityOption('Medium (720p)', 'medium'),
              _buildQualityOption('High (1080p)', 'high'),
            ],
          ),
        );
      },
    );
  }

  Widget _buildQualityOption(String label, String quality) {
    final isSelected = _currentQuality == quality;

    return ListTile(
      title: Text(
        label,
        style: GoogleFonts.inter(
          color: Colors.white,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      leading: isSelected
          ? const Icon(Icons.check, color: Colors.blue)
          : const SizedBox(width: 24),
      onTap: () {
        Navigator.of(context).pop();
        _changeVideoQuality(quality);
      },
    );
  }

  Future<void> _changeVideoQuality(String quality) async {
    if (_currentQuality == quality) return;

    setState(() {
      _currentQuality = quality;
      _remoteVideoConnected = false;
    });

    await _requestQualityChange(quality);

    Future.delayed(const Duration(seconds: 5), () {
      if (mounted && !_remoteVideoConnected) {
        setState(() {
          _remoteVideoConnected = true;
        });
      }
    });
  }

  Future<void> _requestQualityChange(String quality) async {
    bool dataSent = false;

    if (_encryptedVideoChannel != null &&
        _encryptedVideoChannel!.state ==
            RTCDataChannelState.RTCDataChannelOpen) {
      try {
        final message = jsonEncode({
          'type': 'quality_request',
          'quality': quality,
          'viewerId': FirebaseAuth.instance.currentUser!.uid,
        });

        _encryptedVideoChannel!.send(RTCDataChannelMessage(message));

        dataSent = true;

        print('Sent quality request via data channel: $quality');
      } catch (e) {
        print('Error sending quality request via data channel: $e');
      }
    } else {
      print('Data channel not available: ${_encryptedVideoChannel?.state}');
    }
    try {
      _signalingService.sendQualityRequest(
        widget.streamId,
        quality,
        FirebaseAuth.instance.currentUser!.uid,
      );
      dataSent = true;
      print('Sent quality request via signaling: $quality');
    } catch (e) {
      print('Error sending quality request via signaling: $e');
    }

    if (!dataSent) {
      print('Failed to send quality request through any channel');
      setState(() {
        _remoteVideoConnected = true;
      });
    }
  }

  void _setupQualityHandling() {
    if (widget.isStreamer) {
      _encryptedVideoChannel?.onMessage = (RTCDataChannelMessage message) {
        try {
          final data = jsonDecode(message.text);
          if (data['type'] == 'quality_request') {
            _handleQualityRequest(data['quality'], data['viewerId']);
          }
        } catch (e) {
          print('Error processing data channel message: $e');
        }
      };

      _signalingService.onQualityRequest((data) {
        _handleQualityRequest(data['quality'], data['viewerId']);
      });
    }
  }

  void _handleQualityRequest(String quality, String viewerId) {
    print('Received quality request: $quality from $viewerId');
    _viewerQualityPreferences[viewerId] = quality;

    final peerConnection = _peerConnections[viewerId];
    if (peerConnection != null) {
      print('Found peer connection for viewer, adjusting parameters');
      _adjustSenderParameters(peerConnection, quality).then((_) {
        try {
          if (_encryptedVideoChannel != null &&
              _encryptedVideoChannel!.state ==
                  RTCDataChannelState.RTCDataChannelOpen) {
            final confirmMessage = jsonEncode({
              'type': 'quality_changed',
              'quality': quality,
              'viewerId': viewerId
            });
            _encryptedVideoChannel!.send(RTCDataChannelMessage(confirmMessage));
          }
        } catch (e) {
          print('Error sending quality confirmation: $e');
        }
      });
    } else {
      print('No peer connection found for viewer: $viewerId');
    }
  }

  Future<void> _adjustSenderParameters(
      RTCPeerConnection peerConnection, String quality) async {
    if (_localStream == null) return;

    final senders = await peerConnection.getSenders();
    for (var sender in senders) {
      if (sender.track?.kind == 'video') {
        final parameters = sender.parameters;
        if (parameters.encodings != null) {
          switch (quality) {
            case 'low':
              _setLowQualityParameters(parameters.encodings!);
              break;
            case 'medium':
              _setMediumQualityParameters(parameters.encodings!);
              break;
            case 'high':
              _setHighQualityParameters(parameters.encodings!);
              break;
          }
          await sender.setParameters(parameters);
          print("Quality changed successfully to: $quality");
        }
      }
    }
  }

  void _setLowQualityParameters(List<RTCRtpEncoding> encodings) {
    for (var encoding in encodings) {
      encoding.maxBitrate = 1000000;
      encoding.maxFramerate = 24;
      encoding.scaleResolutionDownBy = 4.0; // Down to 480p or less
    }
  }

  void _setMediumQualityParameters(List<RTCRtpEncoding> encodings) {
    for (var encoding in encodings) {
      encoding.maxBitrate = 2500000; // 2.5 Mbps
      encoding.maxFramerate = 30;
      encoding.scaleResolutionDownBy = 2.0; // Down to 720p
    }
  }

  void _setHighQualityParameters(List<RTCRtpEncoding> encodings) {
    for (var encoding in encodings) {
      encoding.maxBitrate = 4000000; // 4 Mbps
      encoding.maxFramerate = 30;
      encoding.scaleResolutionDownBy = 1.0; // Full resolution (1080p)
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
    _encryptedVideoChannel?.close();
    if (widget.isStreamer) {
      _endStream();
      StreamKeyExchangeService.cleanupStreamKeys(widget.streamId);
    }
    _isDisposed = true;
    for (final viewerId in _peerConnections.keys.toList()) {
      _cleanupPeerConnection(viewerId);
    }
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
          child: CircularProgressIndicator(),
        ),
      );
    }

    final screenSize = MediaQuery.of(context).size;
    final videoHeight = screenSize.height * 0.4;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          if (!widget.isStreamer)
            IconButton(
              icon: const Icon(Icons.settings, color: Colors.white),
              onPressed: _showQualitySelectionDialog,
            ),
        ],
      ),
      body: Column(
        children: [
          SizedBox(
            height: videoHeight,
            width: double.infinity,
            child: Stack(
              children: [
                Container(
                  color: Colors.black,
                  child: widget.isStreamer
                      ? RTCVideoView(
                          _localRenderer,
                          objectFit:
                              RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                          mirror: true,
                        )
                      : RTCVideoView(
                          _remoteRenderer,
                          objectFit:
                              RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                          mirror: false,
                        ),
                ),
                if (!widget.isStreamer && !_remoteVideoConnected)
                  const Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  ),
                Positioned(
                  left: 16,
                  bottom: 16,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.streamTitle,
                        style: GoogleFonts.inter(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Row(
                        children: [
                          CircleAvatar(
                            radius: 12,
                            backgroundColor: Colors.grey[800],
                            child: Text(
                              widget.streamerUsername[0].toUpperCase(),
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            widget.streamerUsername,
                            style: GoogleFonts.inter(
                              color: Colors.white70,
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
