import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart' as crypto;
import 'package:livestream_webrtc/ecdh_service.dart';
import 'package:livestream_webrtc/logger.dart';
import 'package:firebase_auth/firebase_auth.dart';

class StreamKeyExchangeService {
  static final algorithm = X25519();
  static const secureStorage = FlutterSecureStorage();

  static final _keyExchangeLogsRef =
      FirebaseFirestore.instance.collection('key_exchange_logs');

  static Future<Map<String, dynamic>> generateSharedSecret(
    String userId,
    String otherUserId,
    bool isStreamer, {
    String? streamId,
  }) async {
    if (otherUserId.isEmpty) {
      print('ERROR: otherUserId is empty in generateSharedSecret()');
      return {'success': false, 'error': 'Other user ID is missing'};
    }

    if (streamId == null || streamId.isEmpty) {
      print('ERROR: streamId is null or empty in generateSharedSecret()');
      return {'success': false, 'error': 'Stream ID is missing'};
    }

    String exchangeId =
        '${userId}_${otherUserId}_${DateTime.now().millisecondsSinceEpoch}';
    print(
        '[KEY_EXCHANGE] Generating shared secret with exchangeId: $exchangeId');

    try {
      final startTime = DateTime.now();
      await _logKeyExchange(exchangeId, {
        'status': 'started',
        'userId': userId,
        'otherUserId': otherUserId,
        'isStreamer': isStreamer,
        'streamId': streamId,
        'startTime': startTime,
        'timestamp': DateTime.now(),
      });

      // Get own private key
      final Uint8List? privateKeyBytes =
          await EcdhService.getPrivateKey(userId);
      if (privateKeyBytes == null) {
        await _logKeyExchange(exchangeId, {
          'status': 'failed',
          'error': 'Private key not found',
          'stage': 'private_key_retrieval'
        });
        return {'success': false, 'error': 'Private key not found'};
      }

      // Get other user's public key from Firestore
      final otherUserDoc = await FirebaseFirestore.instance
          .collection('user_keys')
          .doc(otherUserId)
          .get();

      if (!otherUserDoc.exists ||
          !otherUserDoc.data()!.containsKey('publicKey')) {
        await _logKeyExchange(exchangeId, {
          'status': 'failed',
          'error': 'Other user public key not found',
          'stage': 'public_key_retrieval'
        });
        return {'success': false, 'error': 'Other user public key not found'};
      }

      print(
          '[KEY_EXCHANGE] Retrieved public key for $otherUserId successfully.');

      // Convert keys
      final publicKeyBytes =
          EcdhService.stringToBytes(otherUserDoc.data()!['publicKey']);

      await _logKeyExchange(exchangeId, {
        'status': 'processing',
        'privateKeyLength': privateKeyBytes.length,
        'publicKeyLength': publicKeyBytes.length,
        'stage': 'key_conversion'
      });

      // Create key pairs
      final privateKey = await algorithm.newKeyPairFromSeed(privateKeyBytes);
      final publicKey =
          SimplePublicKey(publicKeyBytes, type: KeyPairType.x25519);

      final sharedSecret = await algorithm.sharedSecretKey(
        keyPair: privateKey,
        remotePublicKey: publicKey,
      );

      final sharedSecretBytes = await sharedSecret.extractBytes();
      final aesKey = crypto.sha256.convert(sharedSecretBytes).bytes;

      EncryptionLogger.logSharedSecretDerived(
        userId,
        streamId,
        aesKey.take(8).toString(),
      );

      final username = FirebaseAuth.instance.currentUser?.displayName ?? userId;
      print(
          '[KEY_EXCHANGE] [$username] AES-256 key derived (32 bytes) for stream $streamId');

      final streamKeyId = 'stream_key_${streamId}_$otherUserId';
      await secureStorage.write(key: streamKeyId, value: base64.encode(aesKey));
      print(
          '[KEY_EXCHANGE] [$username] AES-256 key stored in secure-storage under $streamKeyId');

      final storedKey = await secureStorage.read(key: streamKeyId);
      if (storedKey == null) {
        print('ERROR: Failed to verify AES key storage');
        return {'success': false, 'error': 'Failed to store AES key'};
      }

      print(
          '[KEY_EXCHANGE] AES key stored successfully for stream: $streamKeyId');

      await _storeExchangeVerification(
          exchangeId, userId, otherUserId, isStreamer, aesKey.length, streamId);

      await _logKeyExchange(exchangeId, {
        'status': 'completed',
        'endTime': DateTime.now(),
        'aesKeyLength': aesKey.length,
        'streamId': streamId,
        'stage': 'completion'
      });

      return {
        'success': true,
        'keyId': streamKeyId,
        'keyLength': aesKey.length,
        'exchangeId': exchangeId
      };
    } catch (e) {
      print('Error generating shared secret: $e');
      await _logKeyExchange(exchangeId, {
        'status': 'error',
        'error': e.toString(),
        'stage': 'unknown',
        'streamId': streamId
      });
      return {'success': false, 'error': e.toString()};
    }
  }

  static Future<void> _logKeyExchange(
      String exchangeId, Map<String, dynamic> data) async {
    try {
      await _keyExchangeLogsRef.doc(exchangeId).collection('steps').add({
        ...data,
        'timestamp': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print('Error logging key exchange: $e');
    }
  }

  static Future<void> _storeExchangeVerification(
    String exchangeId,
    String userId,
    String otherUserId,
    bool isStreamer,
    int keyLength,
    String streamId,
  ) async {
    try {
      await FirebaseFirestore.instance
          .collection('key_exchanges')
          .doc(exchangeId)
          .set({
        'exchangeId': exchangeId,
        'userId': userId,
        'otherUserId': otherUserId,
        'isStreamer': isStreamer,
        'keyLength': keyLength,
        'streamId': streamId,
        'timestamp': FieldValue.serverTimestamp(),
        'status': 'completed',
      });
    } catch (e) {
      print('Error storing exchange verification: $e');
      rethrow;
    }
  }

  static Future<Map<String, dynamic>> verifyKeyExchange(String exchangeId,
      {required String streamId}) async {
    if (exchangeId.isEmpty) {
      return {'verified': false, 'error': 'Invalid exchange ID'};
    }

    try {
      final exchangeDoc = await FirebaseFirestore.instance
          .collection('key_exchanges')
          .doc(exchangeId)
          .get();

      if (!exchangeDoc.exists) {
        return {'verified': false, 'error': 'Exchange record not found'};
      }

      final logs = await _keyExchangeLogsRef
          .doc(exchangeId)
          .collection('steps')
          .orderBy('timestamp')
          .get();

      return {
        'verified': true,
        'exchange': exchangeDoc.data(),
        'logs': logs.docs.map((doc) => doc.data()).toList(),
      };
    } catch (e) {
      return {'verified': false, 'error': e.toString()};
    }
  }

  static Future<Uint8List?> getStreamKey(String streamId,
      {required String otherUserId}) async {
    try {
      print('Retrieving AES key for stream: $streamId');
      final keyStr =
          await secureStorage.read(key: 'stream_key_${streamId}_$otherUserId');
      if (keyStr == null) {
        print(
            'ERROR: No stored AES key found for stream $streamId with $otherUserId');
        return null;
      }

      print('AES Key Retrieved Successfully: $keyStr');

      return base64.decode(keyStr);
    } catch (e) {
      print('Error getting stream key: $e');
      return null;
    }
  }

  static Future<void> cleanupStreamKeys(String streamId) async {
    try {
      await secureStorage.delete(key: 'stream_key_$streamId');
    } catch (e) {
      print('Error cleaning up stream keys: $e');
    }
  }
}
