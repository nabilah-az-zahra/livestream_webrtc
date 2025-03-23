import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:livestream_webrtc/screens/myprofile.dart';
import 'package:livestream_webrtc/screens/startlive.dart';
import 'package:livestream_webrtc/screens/livestream.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:livestream_webrtc/screens/login.dart';
import 'package:livestream_webrtc/screens/register.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _isLoading = true;
  String? _errorMessage;
  User? _currentUser;

  @override
  void initState() {
    super.initState();
    _checkFirestoreAccess();
    _checkUserStatus();
  }

  Future<void> _checkUserStatus() async {
    _currentUser = FirebaseAuth.instance.currentUser;
    setState(() {});
  }

  Future<void> _checkFirestoreAccess() async {
    try {
      await FirebaseFirestore.instance.collection('streams').limit(1).get();
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = _getErrorMessage(e);
        });
      }
      print('Firestore access error: $e');
    }
  }

  String _getErrorMessage(dynamic error) {
    if (error.toString().contains('permission-denied')) {
      return 'Database access denied. Please check your Firebase configuration.';
    } else if (error.toString().contains('not-found')) {
      return 'Database not found. Please verify your Firebase setup.';
    }
    return 'Error connecting to database. Please try again later.';
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

  void joinStream(String streamId) async {
    if (_currentUser == null) {
      _showLoginRequiredPopup();
      return;
    }

    final streamInfo = await getStreamInfo(streamId);

    if (streamInfo == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Stream not found or no longer available')),
        );
      }
      return;
    }

    if (mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => LiveStreamPage(
            streamTitle: streamInfo['streamTitle'],
            streamerId: streamInfo['streamerId'],
            streamerUsername: streamInfo['streamerUsername'],
            streamId: streamId,
            isStreamer: false,
          ),
        ),
      );
    }
  }

  void _showLoginRequiredPopup() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Login Required', style: GoogleFonts.kanit()),
          content: Text('You need to register/login to watch live streams.',
              style: GoogleFonts.kanit()),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const LoginPage()),
                );
              },
              child: Text('Login', style: GoogleFonts.kanit()),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const RegisterPage()),
                );
              },
              child: Text('Register', style: GoogleFonts.kanit()),
            ),
          ],
        );
      },
    );
  }

  Widget _buildLiveStreamCard(DocumentSnapshot stream, int index) {
    final streamData = stream.data() as Map<String, dynamic>;

    return GestureDetector(
      onTap: () => joinStream(stream.id),
      child: Container(
        margin: const EdgeInsets.symmetric(
          vertical: 8.0,
          horizontal: 16.0,
        ),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.grey.withOpacity(0.2),
              spreadRadius: 1,
              blurRadius: 6,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Stack(
          children: [
            Container(
              height: 176.0,
              decoration: BoxDecoration(
                color: const Color(0xFFD9D9D9),
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            Positioned(
              top: 10.0,
              left: 10.0,
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12.0,
                      vertical: 6.0,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFAA4A4D),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      "LIVE ${index + 1}",
                      style: GoogleFonts.kanit(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.all(16.0),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.7),
                  borderRadius: const BorderRadius.only(
                    bottomLeft: Radius.circular(12),
                    bottomRight: Radius.circular(12),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      streamData['streamTitle'] ?? 'Untitled',
                      style: GoogleFonts.kanit(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "Streamer: ${streamData['streamerUsername'] ?? 'Unknown'}",
                      style: GoogleFonts.kanit(
                        fontSize: 14,
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.grey[100],
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.live_tv_outlined,
              size: 64,
              color: Colors.grey[400],
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'No Live Streams Available',
            style: GoogleFonts.kanit(
              fontSize: 20,
              fontWeight: FontWeight.w500,
              color: Colors.grey[800],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Be the first one to go live!',
            style: GoogleFonts.kanit(
              fontSize: 16,
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const StartLivePage(),
                ),
              );
            },
            icon: const Icon(Icons.add_box_outlined),
            label: Text(
              'Start Streaming',
              style: GoogleFonts.kanit(),
            ),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(
                horizontal: 24,
                vertical: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 16.0,
                vertical: 12.0,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  Text(
                    'Live Stream',
                    style: GoogleFonts.kanit(
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF1E1E1E),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.person_outline_outlined,
                      color: Colors.black,
                      size: 30.0,
                    ),
                    onPressed: _currentUser == null
                        ? null
                        : () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => const MyProfilePage(),
                              ),
                            );
                          },
                  ),
                ],
              ),
            ),
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('streams')
                    .where('isLive', isEqualTo: true)
                    .orderBy('createdAt', descending: true)
                    .snapshots(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  if (snapshot.hasError) {
                    return Center(
                      child: Text(
                        'Error loading streams: ${snapshot.error}',
                        style: const TextStyle(color: Colors.red),
                      ),
                    );
                  }

                  final streams = snapshot.data?.docs ?? [];

                  if (streams.isEmpty) {
                    return _buildEmptyState();
                  }

                  return ListView.builder(
                    itemCount: streams.length,
                    itemBuilder: (context, index) =>
                        _buildLiveStreamCard(streams[index], index),
                  );
                },
              ),
            ),
            Container(
              alignment: Alignment.center,
              margin: const EdgeInsets.symmetric(vertical: 8.0),
              child: ElevatedButton(
                onPressed: () {
                  if (_currentUser == null) {
                    _showLoginRequiredPopup();
                  } else {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const StartLivePage(),
                      ),
                    );
                  }
                },
                style: ElevatedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.all(4),
                  backgroundColor: Colors.black,
                ),
                child: const Icon(
                  Icons.add_box_outlined,
                  color: Colors.white,
                  size: 24.0,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
