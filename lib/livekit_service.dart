import 'package:livekit_client/livekit_client.dart';
import 'dart:typed_data';
import 'dart:async';

class LiveKitService {
  late Room room;
  LocalParticipant? localParticipant;
  EventsListener<RoomEvent>? _eventsListener;
  Function(Uint8List data, RemoteParticipant participant)? _onDataHandler;

  final Map<String, StreamController<Uint8List>> _participantStreams = {};

  final StreamController<ConnectionState> _connectionStateController =
      StreamController<ConnectionState>.broadcast();

  int _framesSent = 0;
  int _framesDropped = 0;
  int _lastStatsTime = DateTime.now().millisecondsSinceEpoch;

  Future<void> connectAsStreamer(String url, String token) async {
    room = Room();
    _setupEventListener();

    await room.connect(url, token,
        roomOptions: const RoomOptions(
          adaptiveStream: false,
          dynacast: false,
          e2eeOptions: null,
        ));

    localParticipant = room.localParticipant;

    print('[LIVEKIT] Connected as streamer');
  }

  Future<void> connectAsViewer(String url, String token) async {
    room = Room();
    _setupEventListener();

    await room.connect(url, token,
        roomOptions: const RoomOptions(
          adaptiveStream: false,
          e2eeOptions: null,
        ));

    localParticipant = room.localParticipant;
    await room.setSpeakerOn(true);

    print('[LIVEKIT] Connected as viewer');
  }

  void _setupEventListener() {
    _eventsListener = room.createListener();

    _eventsListener!
      ..on<RoomConnectedEvent>((event) {
        print('[LIVEKIT] Room connected');
        localParticipant = room.localParticipant;
        _connectionStateController.add(room.connectionState);
      })
      ..on<RoomDisconnectedEvent>((event) {
        print('[LIVEKIT] Room disconnected');
        _connectionStateController.add(room.connectionState);
        _cleanup();
      })
      ..on<DataReceivedEvent>((event) {
        _handleDataReceived(event);
      })
      ..on<ParticipantConnectedEvent>((event) {
        print('[LIVEKIT] Participant connected: ${event.participant.identity}');
        _onParticipantConnected(event.participant);
      })
      ..on<ParticipantDisconnectedEvent>((event) {
        print(
            '[LIVEKIT] Participant disconnected: ${event.participant.identity}');
        _onParticipantDisconnected(event.participant);
      })
      ..on<TrackPublishedEvent>((event) {
        print('[LIVEKIT] Track published: ${event.publication.name}');
      })
      ..on<TrackUnpublishedEvent>((event) {
        print('[LIVEKIT] Track unpublished: ${event.publication.name}');
      });
  }

  void _onParticipantConnected(Participant participant) {
    if (participant is RemoteParticipant) {
      _participantStreams[participant.identity] =
          StreamController<Uint8List>.broadcast();
      if (_onDataHandler != null) {
        _participantStreams[participant.identity]!.stream.listen((data) {
          _onDataHandler!(data, participant);
        });
      }
    }
  }

  void _onParticipantDisconnected(Participant participant) {
    if (participant is RemoteParticipant) {
      _participantStreams[participant.identity]?.close();
      _participantStreams.remove(participant.identity);
    }
  }

  void _handleDataReceived(DataReceivedEvent event) {
    if (event.participant is RemoteParticipant) {
      final participant = event.participant as RemoteParticipant;
      final data = Uint8List.fromList(event.data);
      final streamController = _participantStreams[participant.identity];

      if (streamController != null && !streamController.isClosed) {
        streamController.add(data);
      } else if (_onDataHandler != null) {
        _onDataHandler!(data, participant);
      }
    }
  }

  Future<bool> publishVideoFrameImmediate(
    Uint8List bytes, {
    List<String>? destinationIdentities,
  }) async {
    if (localParticipant == null) {
      print('[LIVEKIT] Local participant not available');
      return false;
    }

    try {
      final startTime = DateTime.now().microsecondsSinceEpoch;

      await localParticipant!.publishData(
        bytes,
        reliable: false,
        destinationIdentities: destinationIdentities,
      );

      final endTime = DateTime.now().microsecondsSinceEpoch;
      final duration = (endTime - startTime) / 1000;

      _framesSent++;

      if (_framesSent % 30 == 0) {
        print(
            '[LIVEKIT] Frame sent in ${duration.toStringAsFixed(2)}ms (total: $_framesSent)');
      }

      return true;
    } catch (e) {
      _framesDropped++;
      print('[LIVEKIT] Error in immediate video send: $e');

      if (_framesDropped > 10 && _framesSent > 0) {
        final errorRate = _framesDropped / (_framesSent + _framesDropped);
        if (errorRate > 0.1) {
          print(
              '[LIVEKIT] High error rate detected: ${(errorRate * 100).toStringAsFixed(1)}%');
        }
      }

      return false;
    }
  }

  Future<bool> publishData(
    Uint8List bytes,
    bool reliable, {
    List<String>? destinationIdentities,
  }) async {
    if (localParticipant == null) {
      print('[LIVEKIT] Local participant not available');
      return false;
    }

    try {
      await localParticipant!.publishData(
        bytes,
        reliable: reliable,
        destinationIdentities: destinationIdentities,
      );
      return true;
    } catch (e) {
      print('[LIVEKIT] Error publishing data: $e');
      return false;
    }
  }

  Future<bool> publishDataBulk(
    Map<String, Uint8List> recipientData,
    bool reliable,
  ) async {
    if (localParticipant == null) {
      print('[LIVEKIT] Local participant not available');
      return false;
    }

    try {
      final futures = recipientData.entries.map((entry) async {
        try {
          await localParticipant!.publishData(
            entry.value,
            reliable: reliable,
            destinationIdentities: [entry.key],
          );
          return true;
        } catch (e) {
          print('[LIVEKIT] Error sending to ${entry.key}: $e');
          return false;
        }
      });

      final results = await Future.wait(futures);
      final successCount = results.where((r) => r).length;

      print('[LIVEKIT] Bulk send: $successCount/${results.length} successful');
      return successCount == results.length;
    } catch (e) {
      print('[LIVEKIT] Error in bulk publish: $e');
      return false;
    }
  }

  void onData(
      void Function(Uint8List data, RemoteParticipant participant) handler) {
    _onDataHandler = handler;
    for (final entry in _participantStreams.entries) {
      final participantId = entry.key;
      final streamController = entry.value;

      final participant = room.remoteParticipants[participantId];
      if (participant != null && !streamController.isClosed) {
        streamController.stream.listen((data) {
          handler(data, participant);
        });
      }
    }
  }

  Map<String, dynamic> getRoomStats() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final timeDiff = (now - _lastStatsTime) / 1000.0;

    final stats = {
      'connected': room.connectionState == ConnectionState.connected,
      'participants': room.remoteParticipants.length,
      'localParticipant': localParticipant?.identity,
      'roomName': room.name,
      'roomSid': room.metadata,
      'participantStreams': _participantStreams.length,
      'connectionQuality': room.connectionState.toString(),
      'framesSent': _framesSent,
      'framesDropped': _framesDropped,
      'avgFPS': timeDiff > 0 ? _framesSent / timeDiff : 0,
      'errorRate':
          _framesSent > 0 ? _framesDropped / (_framesSent + _framesDropped) : 0,
    };

    final participantStats = <String, Map<String, dynamic>>{};
    for (final participant in room.remoteParticipants.values) {
      participantStats[participant.identity] = {
        'connectionQuality': participant.connectionQuality.toString(),
        'audioTracks': participant.audioTrackPublications.length,
        'videoTracks': participant.videoTrackPublications.length,
        'hasStream': _participantStreams.containsKey(participant.identity),
      };
    }
    stats['participantDetails'] = participantStats;

    return stats;
  }

  Stream<ConnectionState> get connectionStateStream {
    return _connectionStateController.stream;
  }

  Map<String, int> getPerformanceStats() {
    return {
      'framesSent': _framesSent,
      'framesDropped': _framesDropped,
      'participantStreams': _participantStreams.length,
      'activeParticipants': room.remoteParticipants.length,
    };
  }

  void resetPerformanceStats() {
    _framesSent = 0;
    _framesDropped = 0;
    _lastStatsTime = DateTime.now().millisecondsSinceEpoch;
    print('[LIVEKIT] Performance stats reset');
  }

  void _cleanup() {
    for (final streamController in _participantStreams.values) {
      streamController.close();
    }
    _participantStreams.clear();
  }

  Future<void> disconnect() async {
    _cleanup();
    _eventsListener?.dispose();
    _connectionStateController.close();
    await room.disconnect();

    final errorRate = _framesSent > 0
        ? (_framesDropped / (_framesSent + _framesDropped)) * 100
        : 0;
    print(
        '[LIVEKIT] Disconnected final stats: ${_framesSent} frames sent, ${_framesDropped} dropped (${errorRate.toStringAsFixed(1)}% error rate)');
  }
}

class DataMessage {
  final Uint8List data;
  final bool reliable;
  final List<String>? destinationIdentities;

  DataMessage({
    required this.data,
    required this.reliable,
    this.destinationIdentities,
  });
}
