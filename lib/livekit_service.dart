import 'package:livekit_client/livekit_client.dart';
import 'dart:typed_data';
import 'dart:async';

class LiveKitService {
  late Room room;
  LocalParticipant? localParticipant;
  EventsListener<RoomEvent>? _eventsListener;
  Function(Uint8List data, RemoteParticipant participant)? _onDataHandler;

  Future<void> connectAsStreamer(String url, String token) async {
    room = Room();

    _setupEventListener();

    await room.connect(url, token,
        roomOptions: const RoomOptions(
          adaptiveStream: false,
          dynacast: false,
        ));

    localParticipant = room.localParticipant;

    final audioTrack = await LocalAudioTrack.create();
    await localParticipant!.publishAudioTrack(audioTrack);

    print('Connected as streamer');
  }

  Future<void> connectAsViewer(String url, String token) async {
    room = Room();

    _setupEventListener();

    await room.connect(url, token,
        roomOptions: const RoomOptions(
          adaptiveStream: false,
        ));

    localParticipant = room.localParticipant;
    print('Connected as viewer');

    await room.setSpeakerOn(true);
  }

  void _setupEventListener() {
    _eventsListener = room.createListener();

    _eventsListener!
      ..on<RoomConnectedEvent>((event) {
        print('Room connected');
        localParticipant = room.localParticipant;
      })
      ..on<RoomDisconnectedEvent>((event) {
        print('Room disconnected');
      })
      ..on<DataReceivedEvent>((event) {
        if (_onDataHandler != null && event.participant is RemoteParticipant) {
          _onDataHandler!(Uint8List.fromList(event.data),
              event.participant as RemoteParticipant);
        }
      })
      ..on<ParticipantConnectedEvent>((event) {
        print('Participant connected: ${event.participant.identity}');
      })
      ..on<ParticipantDisconnectedEvent>((event) {
        print('Participant disconnected: ${event.participant.identity}');
      });
  }

  Future<bool> publishData(Uint8List bytes, bool reliable) async {
    if (localParticipant == null) {
      print('Local participant not available');
      return false;
    }
    try {
      await localParticipant!.publishData(
        bytes,
        reliable: reliable,
      );
      return true;
    } catch (e) {
      print('Error publishing data: $e');
      return false;
    }
  }

  void onData(
      void Function(Uint8List data, RemoteParticipant participant) handler) {
    _onDataHandler = handler;
  }

  Map<String, dynamic> getRoomStats() {
    return {
      'connected': room.connectionState == ConnectionState.connected,
      'participants': room.remoteParticipants.length,
      'localParticipant': localParticipant?.identity,
      'roomName': room.name,
      'roomSid': room.metadata,
    };
  }

  Future<void> disconnect() async {
    _eventsListener?.dispose();
    await room.disconnect();
  }
}
