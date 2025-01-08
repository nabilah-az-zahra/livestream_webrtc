import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:livestream_webrtc/signaling.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class LiveStreamPage extends StatefulWidget {
  final String streamTitle;
  final String streamerName;
  final String streamId;
  final bool isStreamer;

  const LiveStreamPage({
    super.key,
    required this.streamTitle,
    required this.streamerName,
    required this.streamId,
    required this.isStreamer,
  });

  @override
  State<LiveStreamPage> createState() => _LiveStreamPageState();
}

class _LiveStreamPageState extends State<LiveStreamPage> {
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final SignalingService _signalingService = SignalingService();
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;

  bool _isLoading = true;
  bool _hasError = false;
  bool _remoteVideoConnected = false;

  List<String> chatMessages = [];
  final TextEditingController _chatController = TextEditingController();

  StreamSubscription? _streamStatusSubscription;

  @override
  void initState() {
    super.initState();
    if (FirebaseAuth.instance.currentUser != null) {
      _initializeStream();
      _listenToStreamStatus();
    } else {
      Navigator.pushReplacementNamed(context, '/login');
    }
  }

  Future<void> _initializeStream() async {
    try {
      // Initialize remote renderer for all users
      await _remoteRenderer.initialize();

      if (widget.isStreamer) {
        await _initializeStreamer();
      } else {
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

    // Get user media stream
    _localStream = await navigator.mediaDevices.getUserMedia({
      'video': {
        'facingMode': 'user',
        'width': {'ideal': 1280},
        'height': {'ideal': 720},
      },
      'audio': true,
    });

    _localRenderer.srcObject = _localStream;
    await _setupStreamerConnection();
  }

  Future<void> _initializeViewer() async {
    await _setupViewerConnection();
  }

  Future<void> _setupStreamerConnection() async {
    final configuration = {
      'iceServers': [
        {
          'urls': [
            'stun:stun1.l.google.com:19302',
            'stun:stun2.l.google.com:19302',
          ],
        },
      ],
      'sdpSemantics': 'unified-plan',
    };

    _peerConnection = await createPeerConnection(configuration);

    // Add local stream tracks to peer connection
    _localStream?.getTracks().forEach((track) {
      _peerConnection?.addTrack(track, _localStream!);
    });

    _peerConnection?.onIceCandidate = (candidate) {
      if (candidate != null) {
        _signalingService.addIceCandidate(widget.streamId, candidate);
      }
    };

    // Create and set local offer
    RTCSessionDescription offer = await _peerConnection!.createOffer();
    await _peerConnection!.setLocalDescription(offer);
    await _signalingService.setOffer(widget.streamId, offer);

    // Listen for remote answer
    _signalingService.getStreamData(widget.streamId).listen((streamData) async {
      if (streamData != null && streamData['answer'] != null) {
        final answer = RTCSessionDescription(
          streamData['answer']['sdp'],
          streamData['answer']['type'],
        );
        await _peerConnection?.setRemoteDescription(answer);
      }
    });
  }

  Future<void> _setupViewerConnection() async {
    final configuration = {
      'iceServers': [
        {
          'urls': [
            'stun:stun1.l.google.com:19302',
            'stun:stun2.l.google.com:19302',
          ],
        },
      ],
      'sdpSemantics': 'unified-plan',
      'offerToReceiveVideo': true,
      'offerToReceiveAudio': true,
    };

    try {
      _peerConnection = await createPeerConnection(configuration);

      // Handle incoming tracks
      _peerConnection?.onTrack = (RTCTrackEvent event) {
        print("Received track: ${event.track.kind}");

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

      // Set up ICE candidate handling
      _peerConnection?.onIceCandidate = (candidate) {
        if (candidate != null) {
          print("Viewer sending ICE candidate");
          _signalingService.addIceCandidate(widget.streamId, candidate);
        }
      };

      // Get and set remote offer
      final streamData =
          await _signalingService.getStreamData(widget.streamId).first;
      if (streamData != null && streamData['offer'] != null) {
        print("Setting remote description from offer");
        final offer = RTCSessionDescription(
          streamData['offer']['sdp'],
          streamData['offer']['type'],
        );

        await _peerConnection?.setRemoteDescription(offer);

        print("Creating answer");
        final answer = await _peerConnection!.createAnswer({
          'offerToReceiveVideo': true,
          'offerToReceiveAudio': true,
        });

        print("Setting local description");
        await _peerConnection!.setLocalDescription(answer);

        print("Sending answer to streamer");
        await _signalingService.setAnswer(widget.streamId, answer);
      }

      // Listen for ICE candidates from streamer
      _signalingService.getIceCandidates(widget.streamId).listen((candidates) {
        print("Received ICE candidates from streamer: ${candidates.length}");
        for (var candidate in candidates) {
          _peerConnection?.addCandidate(candidate);
        }
      });
    } catch (e) {
      print("Error in viewer connection setup: $e");
      setState(() {
        _hasError = true;
      });
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

  void _sendMessage() {
    if (_chatController.text.isNotEmpty) {
      setState(() {
        chatMessages.add(_chatController.text);
        _chatController.clear();
      });
    }
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
    if (widget.isStreamer) {
      _endStream();
    }
    _streamStatusSubscription?.cancel();
    _localStream?.getTracks().forEach((track) => track.stop());
    _localStream?.dispose();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    _peerConnection?.close();
    _peerConnection?.dispose();
    _chatController.dispose();
    super.dispose();
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

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.isStreamer ? 'Broadcasting Live' : 'Watching Stream',
          style: GoogleFonts.kanit(color: Colors.black, fontSize: 20),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              flex: 3,
              child: Stack(
                children: [
                  Container(
                    color: Colors.black,
                    height: MediaQuery.of(context).size.height * 0.3,
                    child: widget.isStreamer
                        ? RTCVideoView(
                            _localRenderer,
                            objectFit: RTCVideoViewObjectFit
                                .RTCVideoViewObjectFitCover,
                            mirror: true,
                          )
                        : RTCVideoView(
                            _remoteRenderer,
                            objectFit: RTCVideoViewObjectFit
                                .RTCVideoViewObjectFitContain,
                            mirror: false,
                          ),
                  ),
                  if (!widget.isStreamer && !_remoteVideoConnected)
                    const Center(
                      child: CircularProgressIndicator(
                        color: Colors.white,
                      ),
                    ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(vertical: 12.0),
              child: Column(
                children: [
                  Text(
                    widget.streamTitle,
                    style: GoogleFonts.kanit(
                      color: Colors.black,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    'Streamer: ${widget.streamerName}',
                    style: GoogleFonts.kanit(
                      color: Colors.grey,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 2,
              child: ListView.builder(
                itemCount: chatMessages.length,
                itemBuilder: (context, index) {
                  return ListTile(
                    title: Text(chatMessages[index]),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _chatController,
                      decoration: const InputDecoration(
                        hintText: 'Type your message...',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.send),
                    onPressed: _sendMessage,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
