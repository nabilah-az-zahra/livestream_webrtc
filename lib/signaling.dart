import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:firebase_auth/firebase_auth.dart';

class SignalingService {
  static final SignalingService _instance = SignalingService._internal();

  factory SignalingService() => _instance;

  late IO.Socket _socket;
  final String _serverUrl = 'http://192.168.1.10:3000';
  bool _isConnected = false;

  SignalingService._internal() {
    connect();
  }

  void connect() {
    if (_isConnected) return;

    _socket = IO.io(
        _serverUrl,
        IO.OptionBuilder()
            .setTransports(['websocket'])
            .enableReconnection()
            .setReconnectionAttempts(5)
            .setReconnectionDelay(3000)
            .enableForceNew()
            .build());

    _socket.onConnect((_) {
      print('Socket connected');
      _isConnected = true;
    });

    _socket.onDisconnect((_) {
      print('Socket disconnected');
      _isConnected = false;
    });

    _socket.onError((error) {
      print('Socket error: $error');
    });

    _socket.onConnectError((error) {
      print('Socket connection error: $error');
    });

    _socket.connect();
  }

  void joinStream(String streamId, bool isStreamer) {
    if (!_isConnected) {
      print('Socket not connected, attempting to reconnect...');
      connect();
    }
    final userId = FirebaseAuth.instance.currentUser?.uid;
    print('[SOCKET] join_stream for $userId');

    _socket.emit('join_stream', {
      'streamId': streamId,
      'isStreamer': isStreamer,
      'userId': userId,
    });
  }

  void onViewerJoined(Function(Map<String, dynamic>) callback) {
    _socket.on(
        'viewer_joined', (data) => callback(Map<String, dynamic>.from(data)));
  }

  void sendOffer(
      String streamId, String viewerId, RTCSessionDescription offer) {
    if (!_isConnected) return;

    _socket.emit('offer', {
      'streamId': streamId,
      'viewerId': viewerId,
      'offer': {
        'type': offer.type,
        'sdp': offer.sdp,
      }
    });
  }

  void sendAnswer(String streamId, RTCSessionDescription answer) {
    if (!_isConnected) {
      print('Socket not connected when trying to send answer');
      return;
    }

    print('Sending answer with SDP: ${answer.sdp}');
    _socket.emit('answer', {
      'streamId': streamId,
      'answer': {
        'type': answer.type,
        'sdp': answer.sdp,
      }
    });
  }

  void sendIceCandidate(String streamId, RTCIceCandidate candidate,
      {required String targetId}) {
    if (!_isConnected) return;

    print(
        '[SIGNALING] Sending ICE candidate to $targetId: ${candidate.candidate}');

    _socket.emit('ice_candidate', {
      'streamId': streamId,
      'targetId': targetId,
      'candidate': {
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex is int
            ? candidate.sdpMLineIndex
            : int.tryParse(candidate.sdpMLineIndex.toString()),
      }
    });
  }

  void onOffer(Function(Map<String, dynamic>) callback) {
    _socket.on('offer', (data) => callback(data));
  }

  void onAnswer(Function(Map<String, dynamic>) callback) {
    _socket.on('answer', (data) {
      final parsedData = Map<String, dynamic>.from(data);
      if (data is Map && data['socketId'] != null) {
        parsedData['socketId'] = data['socketId'];
      }
      callback(parsedData);
    });
  }

  void onIceCandidate(Function(Map<String, dynamic>) callback) {
    _socket.on('ice_candidate', (data) => callback(data));
  }

  void disconnect() {
    if (!_isConnected) return;
    _socket.disconnect();
    _socket.dispose();
    _isConnected = false;
  }
}
