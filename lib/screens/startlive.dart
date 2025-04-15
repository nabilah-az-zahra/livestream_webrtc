import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:livestream_webrtc/exchange_service.dart';
import 'package:livestream_webrtc/screens/livestream.dart';
import 'package:livestream_webrtc/signaling.dart';
import 'package:livestream_webrtc/e2ee_service.dart';

class StartLivePage extends StatefulWidget {
  const StartLivePage({super.key});

  @override
  State<StartLivePage> createState() => _StartLivePageState();
}

class _StartLivePageState extends State<StartLivePage> {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final _signalingService = SignalingService('http://localhost:3000');
  final TextEditingController _titleController = TextEditingController();
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  RTCDataChannel? _encryptedVideoChannel;
  bool _isEncryptionReady = false;
  bool _isSettingUp = false;
  bool _isCameraInitialized = false;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    try {
      await _localRenderer.initialize();

      _localStream = await navigator.mediaDevices.getUserMedia({
        'video': {
          'facingMode': 'user',
          'width': {'ideal': 1920},
          'height': {'ideal': 1080},
          'aspectRatio': {'ideal': 16 / 9},
        },
        'audio': true,
      });

      _localRenderer.srcObject = _localStream;

      setState(() {
        _isCameraInitialized = true;
      });
    } catch (e) {
      print('Error initializing camera: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to initialize camera: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<RTCPeerConnection> _createPeerConnection() async {
    final Map<String, dynamic> configuration = {
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

  Future<void> _setupPeerConnection(String streamId) async {
    try {
      _peerConnection = await _createPeerConnection();

      final dataChannelInit = RTCDataChannelInit()
        ..ordered = true
        ..protocol = 'video-e2ee';

      _encryptedVideoChannel = await _peerConnection!
          .createDataChannel('video-e2ee', dataChannelInit);

      await StreamCryptoService.encryptRtpSender(
        _encryptedVideoChannel!,
        streamId,
        FirebaseAuth.instance.currentUser!.uid,
        FirebaseAuth.instance.currentUser!.uid,
        true,
      );

      // Verify encryption is working
      print('Attempting to verify stream encryption...');
      final encryptionVerified =
          await StreamCryptoService.verifyEncryption(streamId);
      if (!encryptionVerified) {
        throw Exception(
            'Stream encryption verification failed. Check logs for details.');
      }
      print('Stream encryption verified successfully');

      setState(() {
        _isEncryptionReady = true;
      });

      _peerConnection?.onIceCandidate = (candidate) {
        if (candidate != null) {
          _signalingService.sendIceCandidate(streamId, candidate);
        }
      };

      _localStream!.getTracks().forEach((track) {
        _peerConnection?.addTrack(track, _localStream!);
      });

      _signalingService.connect();
      _signalingService.joinStream(streamId, true);

      // Handle viewer connections
      _signalingService.onViewerJoined((viewerId) async {
        if (_peerConnection != null) {
          RTCSessionDescription offer = await _peerConnection!.createOffer();
          await _peerConnection!.setLocalDescription(offer);
          _signalingService.sendOffer(streamId, viewerId, offer);
        }
      });

      _signalingService.onAnswer((data) async {
        if (data['answer'] != null && _peerConnection != null) {
          final answer = RTCSessionDescription(
            data['answer']['sdp'],
            data['answer']['type'],
          );
          await _peerConnection?.setRemoteDescription(answer);
        }
      });
    } catch (e) {
      print('Error setting up connection: $e');
      rethrow;
    }
  }

  void _startLive() async {
    if (_titleController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a stream title')),
      );
      return;
    }

    setState(() => _isSettingUp = true);

    try {
      final String streamId = DateTime.now().millisecondsSinceEpoch.toString();
      final String streamTitle = _titleController.text;
      final User? currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser == null) {
        throw Exception('No user logged in');
      }
      final String streamerId = currentUser.uid;
      final String streamerUsername = currentUser.displayName ?? 'Unknown';

      print('Using streamId: $streamId for key exchange');

      // Generate and store the stream key first
      final keyExchange = await StreamKeyExchangeService.generateSharedSecret(
        currentUser.uid,
        currentUser.uid,
        true,
        streamId: streamId,
      );

      if (!keyExchange['success']) {
        throw Exception(
            'Failed to setup stream encryption: ${keyExchange['error']}');
      }

      // Verify key exchange
      final verification = await StreamKeyExchangeService.verifyKeyExchange(
        keyExchange['exchangeId'],
        streamId: streamId,
      );

      if (verification['verified']) {
      } else {
        throw Exception('Key exchange verification failed');
      }

      print('Exchange verified successfully');
      print('Exchange details: ${verification['exchange']}');
      print('Exchange logs: ${verification['logs']}');

      // Setup peer connection with encryption
      await _setupPeerConnection(streamId);

      await FirebaseFirestore.instance.collection('streams').doc(streamId).set({
        'streamId': streamId,
        'streamTitle': streamTitle,
        'streamerId': streamerId,
        'streamerUsername': streamerUsername,
        'isLive': true,
        'createdAt': FieldValue.serverTimestamp(),
        'viewerCount': 0,
        'encryptionReady': false,
      });

      await _setupPeerConnection(streamId);

      await FirebaseFirestore.instance
          .collection('streams')
          .doc(streamId)
          .update({
        'encryptionReady': true,
      });

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => LiveStreamPage(
              streamTitle: streamTitle,
              streamerId: streamerId,
              streamerUsername: streamerUsername,
              streamId: streamId,
              isStreamer: true,
            ),
          ),
        );
      }
    } catch (e) {
      print('Error starting stream: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to start stream: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSettingUp = false);
      }
    }
  }

  Future<Map<String, dynamic>?> getStreamInfo(String streamId) async {
    try {
      final streamDoc = await FirebaseFirestore.instance
          .collection('streams')
          .doc(streamId)
          .get();

      if (!streamDoc.exists) {
        return null;
      }

      return streamDoc.data();
    } catch (e) {
      print('Error fetching stream info: $e');
      return null;
    }
  }

  Future<bool> _checkFirestoreConnection() async {
    try {
      await FirebaseFirestore.instance.collection('streams').doc('test').get();
      return true;
    } catch (e) {
      print('Firestore connection test failed: $e');
      return false;
    }
  }

  @override
  void dispose() {
    _encryptedVideoChannel?.close();
    _signalingService.disconnect();
    _localStream?.getTracks().forEach((track) => track.stop());
    _localStream?.dispose();
    _localRenderer.dispose();
    _peerConnection?.dispose();
    _titleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.black),
                    onPressed: () => Navigator.pop(context),
                  ),
                  const SizedBox(width: 16.0),
                  Text(
                    'Start Live',
                    style: GoogleFonts.kanit(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: const Color(0xFF1E1E1E),
                    ),
                  ),
                ],
              ),
            ),
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Container(
                color: Colors.black,
                child: _isCameraInitialized
                    ? RTCVideoView(
                        _localRenderer,
                        objectFit:
                            RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                        mirror: true,
                      )
                    : const Center(
                        child: CircularProgressIndicator(
                          color: Colors.white,
                        ),
                      ),
              ),
            ),
            Padding(
              padding:
                  const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
              child: Container(
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: const Color(0xFFD9D9D9),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.2),
                      offset: const Offset(2, 2),
                      blurRadius: 4,
                    ),
                  ],
                ),
                child: TextField(
                  controller: _titleController,
                  cursorColor: Colors.black,
                  decoration: InputDecoration(
                    hintText: 'Enter Live Stream Title',
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide.none,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderSide:
                          const BorderSide(color: Colors.black, width: 2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    filled: true,
                    fillColor: Colors.white,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(20.0),
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.black,
                  padding:
                      const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: _isSettingUp
                    ? null
                    : () async {
                        bool hasConnection = await _checkFirestoreConnection();
                        if (!hasConnection) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                    'Unable to connect to server. Please check your internet connection.'),
                                backgroundColor: Colors.red,
                              ),
                            );
                          }
                          return;
                        }
                        _startLive();
                      },
                child: _isSettingUp
                    ? const CircularProgressIndicator(
                        color: Colors.black,
                      )
                    : Text(
                        'Start Live',
                        style: GoogleFonts.kanit(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
