import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:livestream_webrtc/screens/livestream.dart';
import 'package:livestream_webrtc/signaling.dart';

class StartLivePage extends StatefulWidget {
  const StartLivePage({super.key});

  @override
  State<StartLivePage> createState() => _StartLivePageState();
}

class _StartLivePageState extends State<StartLivePage> {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final _signalingService = SignalingService('http://localhost:3000');
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  final TextEditingController _titleController = TextEditingController();
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

      _signalingService.onViewerJoined((viewerId) async {
        RTCSessionDescription offer = await _peerConnection!.createOffer();
        await _peerConnection!.setLocalDescription(offer);
        _signalingService.sendOffer(streamId, viewerId, offer);
      });

      _signalingService.onAnswer((data) async {
        if (data['answer'] != null) {
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

      await FirebaseFirestore.instance.collection('streams').doc(streamId).set({
        'streamId': streamId,
        'streamTitle': streamTitle,
        'streamerId': streamerId,
        'streamerUsername': streamerUsername,
        'isLive': true,
        'createdAt': FieldValue.serverTimestamp(),
        'viewerCount': 0,
      });

      await _setupPeerConnection(streamId);

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
                  const SizedBox(width: 8.0),
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
                        child: CircularProgressIndicator(),
                      ),
              ),
            ),
            Padding(
              padding:
                  const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
              child: TextField(
                controller: _titleController,
                decoration: const InputDecoration(
                  labelText: 'Enter Live Stream Title',
                  border: OutlineInputBorder(),
                  filled: true,
                  fillColor: Colors.white,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: ElevatedButton(
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
                    ? const CircularProgressIndicator()
                    : Text(
                        'Start Live',
                        style: GoogleFonts.kanit(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
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
