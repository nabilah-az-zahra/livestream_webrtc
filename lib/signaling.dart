import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class SignalingService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  Future<void> createStream(String streamId) async {
    await _firestore.collection('streams').doc(streamId).set({
      'created': FieldValue.serverTimestamp(),
      'ice_candidates': [],
      'connectionState': 'new',
    }, SetOptions(merge: true));
  }

  Future<void> setOffer(String streamId, RTCSessionDescription offer) async {
    await _firestore.collection('streams').doc(streamId).set({
      'offer': {
        'type': offer.type,
        'sdp': offer.sdp,
      },
      'connectionState': 'offer-set',
    }, SetOptions(merge: true));
  }

  Future<void> setAnswer(String streamId, RTCSessionDescription answer) async {
    await _firestore.collection('streams').doc(streamId).set({
      'answer': {
        'type': answer.type,
        'sdp': answer.sdp,
      },
      'connectionState': 'answer-set',
    }, SetOptions(merge: true));
  }

  Future<void> addIceCandidate(
      String streamId, RTCIceCandidate candidate) async {
    await _firestore.collection('streams').doc(streamId).update({
      'ice_candidates': FieldValue.arrayUnion([
        {
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        }
      ]),
    });
  }

  Stream<Map<String, dynamic>?> getStreamData(String streamId) {
    return _firestore
        .collection('streams')
        .doc(streamId)
        .snapshots()
        .map((snap) => snap.data());
  }

  Future<void> updateConnectionState(String streamId, String state) async {
    await _firestore.collection('streams').doc(streamId).update({
      'connectionState': state,
    });
  }

  Future<void> clearIceCandidates(String streamId) async {
    await _firestore.collection('streams').doc(streamId).update({
      'ice_candidates': [],
    });
  }

  Stream<List<RTCIceCandidate>> getIceCandidates(String streamId) {
    return _firestore
        .collection('streams')
        .doc(streamId)
        .snapshots()
        .map((snap) => snap.data()?['ice_candidates'] ?? [])
        .map((candidates) => candidates.map<RTCIceCandidate>((candidate) {
              return RTCIceCandidate(
                candidate['candidate'],
                candidate['sdpMid'],
                candidate['sdpMLineIndex'],
              );
            }).toList());
  }
}
