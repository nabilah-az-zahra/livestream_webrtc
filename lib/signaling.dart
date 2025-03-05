import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:flutter_webrtc/flutter_webrtc.dart';

class SignalingService {
  late IO.Socket _socket;
  final String serverUrl;
  bool _isConnected = false;

  SignalingService(this.serverUrl) {
    connect();
  }

  void connect() {
    if (_isConnected) return;

    _socket = IO.io(
        serverUrl,
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
    _socket
        .emit('join_stream', {'streamId': streamId, 'isStreamer': isStreamer});
  }

  void onViewerJoined(Function(String) callback) {
    _socket.on('viewer_joined', (data) => callback(data['viewerId']));
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

  void sendIceCandidate(String streamId, RTCIceCandidate candidate) {
    if (!_isConnected) return;

    _socket.emit('ice_candidate', {
      'streamId': streamId,
      'candidate': {
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      }
    });
  }

  void onOffer(Function(Map<String, dynamic>) callback) {
    _socket.on('offer', (data) => callback(data));
  }

  void onAnswer(Function(Map<String, dynamic>) callback) {
    _socket.on('answer', (data) => callback(data));
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

  void sendQualityRequest(String streamId, String quality, String viewerId) {
    if (_socket != null && _socket!.connected) {
      _socket!.emit('quality_request', {
        'streamId': streamId,
        'quality': quality,
        'viewerId': viewerId,
      });
    }
  }

  void onQualityRequest(Function(Map<String, dynamic>) callback) {
    _socket?.on('quality_request', (data) {
      callback(data);
    });
  }
}
