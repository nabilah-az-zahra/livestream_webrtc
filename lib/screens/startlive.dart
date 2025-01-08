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
  final SignalingService _signalingService = SignalingService();
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
            'stun:stun2.l.google.com:19302'
          ]
        }
      ],
      'sdpSemantics': 'unified-plan'
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

      if (_localStream == null) {
        throw Exception('No local stream available');
      }

      _localStream!.getTracks().forEach((track) {
        _peerConnection?.addTrack(track, _localStream!);
      });

      _peerConnection?.onIceCandidate = (candidate) {
        if (candidate != null) {
          _signalingService.addIceCandidate(streamId, candidate);
        }
      };

      RTCSessionDescription offer = await _peerConnection!.createOffer({
        'offerToReceiveAudio': 0,
        'offerToReceiveVideo': 0,
      });

      await _peerConnection!.setLocalDescription(offer);

      await _signalingService.createStream(streamId);
      await _signalingService.setOffer(streamId, offer);
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
      const String streamerName = "Streamer Name";

      await FirebaseFirestore.instance.collection('streams').doc(streamId).set({
        'streamId': streamId,
        'streamTitle': streamTitle,
        'streamerName': streamerName,
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
              streamerName: streamerName,
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
