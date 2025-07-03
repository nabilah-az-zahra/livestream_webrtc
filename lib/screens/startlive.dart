import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:livestream_webrtc/exchange_service.dart';
import 'package:livestream_webrtc/screens/livestream.dart';
import 'package:livestream_webrtc/signaling.dart';
import 'package:livestream_webrtc/e2ee_service.dart';
import 'package:livestream_webrtc/logger.dart';

class StartLivePage extends StatefulWidget {
  const StartLivePage({super.key});

  @override
  State<StartLivePage> createState() => _StartLivePageState();
}

class _StartLivePageState extends State<StartLivePage> {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final _signalingService = SignalingService();
  final TextEditingController _titleController = TextEditingController();

  MediaStream? _localStream;
  bool _isSettingUp = false;
  bool _isCameraInitialized = false;
  final GlobalKey _captureKey = GlobalKey();

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

  void _startLive() async {
    if (_titleController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a stream title')),
      );
      return;
    }

    if (_isSettingUp) return;
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

      final verification = await StreamKeyExchangeService.verifyKeyExchange(
        keyExchange['exchangeId'],
        streamId: streamId,
      );

      if (verification['verified']) {
      } else {
        throw Exception('Key exchange verification failed');
      }

      EncryptionLogger.logMessage(
          '[KEY_EXCHANGE] Exchange verified successfully.');
      if (verification['logs'] != null && verification['logs'].isNotEmpty) {
        EncryptionLogger.logMessage(
            '[KEY_EXCHANGE] Log status: ${verification['logs'][0]['status']}');
      } else {
        EncryptionLogger.logMessage('[KEY_EXCHANGE] No logs available');
      }

      final encryptionVerified =
          await StreamCryptoService.verifyEncryption(streamId, currentUser.uid);
      if (!encryptionVerified) {
        throw Exception('Stream encryption verification failed');
      }

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
                    ? RepaintBoundary(
                        key: _captureKey,
                        child: RTCVideoView(
                          _localRenderer,
                          objectFit:
                              RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                          mirror: true,
                        ),
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
