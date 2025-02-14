import 'dart:async';
import 'dart:math';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:livestream_webrtc/signaling.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

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

class _LiveStreamPageState extends State<LiveStreamPage> {
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final _signalingService = SignalingService('http://localhost:3000');
  final Map<String, RTCPeerConnection> _peerConnections = {};
  final Map<String, bool> _connectionStates = {};
  final List<RTCIceCandidate> _pendingCandidates = [];

  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;

  bool _isLoading = true;
  bool _hasError = false;
  bool _remoteVideoConnected = false;
  bool _isDisposed = false;
  bool _remoteDescriptionSet = false;

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
      _listenToStreamStatus();
      _initializeChat();
    } else {
      Navigator.pushReplacementNamed(context, '/login');
    }
  }

  Future<void> _initializeStream() async {
    try {
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

    _localStream = await navigator.mediaDevices.getUserMedia({
      'video': {
        'facingMode': 'user',
        'width': {'ideal': 1920},
        'height': {'ideal': 1080},
      },
      'audio': true,
    });

    _localRenderer.srcObject = _localStream;
    await _setupStreamerConnection();
  }

  Future<void> _initializeViewer() async {
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

      // Set up connection state monitoring
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

      _signalingService.onViewerJoined((viewerId) async {
        // if (_isDisposed) return;
        print('Setting up connection for viewer: $viewerId');

        // await _cleanupPeerConnection(viewerId);

        final peerConnection = await _initPeerConnection(viewerId);
        if (peerConnection == null) return;

        _peerConnections[viewerId] = peerConnection;
        _connectionStates[viewerId] = true;

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
    if (widget.isStreamer) {
      _endStream();
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
          IconButton(
            icon: const Icon(Icons.settings, color: Colors.white),
            onPressed: () {},
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
