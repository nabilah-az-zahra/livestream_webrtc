import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';
import 'dart:math' as math;
import 'dart:convert';
import 'package:livestream_webrtc/exchange_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class StreamCryptoService {
  static const int nonceLength = 12; // 96 bits GCM
  static const int tagLength = 16; // 128 bits authentication tag
  static const int keyRotationInterval = 3600000; // 1 hour
  static const int maxRetries = 3;

  static Map<String, dynamic> _stats = {
    'framesProcessed': 0,
    'encryptionErrors': 0,
    'decryptionErrors': 0,
    'lastKeyRotation': DateTime.now().millisecondsSinceEpoch,
  };

  static Uint8List buildAad(String streamId, int timestamp) {
    final combined = '$streamId:$timestamp';
    final aadBytes = utf8.encode(combined);

    print('[DEBUG] Dart streamId: $streamId');
    print('[DEBUG] Dart timestamp: $timestamp');
    print('[DEBUG] Dart AAD string: $combined');
    print('[DEBUG] Dart AAD bytes: $aadBytes');

    return Uint8List.fromList(aadBytes);
  }

  static GCMBlockCipher createAesGcmCipher(
      bool forEncryption, Uint8List key, Uint8List nonce,
      {Uint8List? aad}) {
    final cipher = GCMBlockCipher(AESEngine());
    final params = AEADParameters(
        KeyParameter(key), tagLength * 8, nonce, aad ?? Uint8List(0));
    cipher.init(forEncryption, params);
    return cipher;
  }

  static Uint8List generateNonce() {
    final secureRandom = SecureRandom('Fortuna')
      ..seed(KeyParameter(Uint8List.fromList(
          List.generate(32, (n) => math.Random.secure().nextInt(256)))));
    return secureRandom.nextBytes(nonceLength);
  }

  static Future<bool> rotateStreamKey(String streamId, String userId,
      String otherUserId, bool isStreamer) async {
    try {
      final result = await StreamKeyExchangeService.generateSharedSecret(
        userId,
        otherUserId,
        isStreamer,
      );

      if (result['success']) {
        _stats['lastKeyRotation'] = DateTime.now().millisecondsSinceEpoch;
        return true;
      }
      return false;
    } catch (e) {
      print('Error rotating stream key: $e');
      return false;
    }
  }

  static Map<String, dynamic> getStats() {
    return {
      ..._stats,
      'errorRate': _stats['framesProcessed'] > 0
          ? (_stats['encryptionErrors'] + _stats['decryptionErrors']) /
              _stats['framesProcessed']
          : 0,
    };
  }

  static void resetStats() {
    _stats = {
      'framesProcessed': 0,
      'encryptionErrors': 0,
      'decryptionErrors': 0,
      'lastKeyRotation': DateTime.now().millisecondsSinceEpoch,
    };
  }

  static Future<bool> verifyEncryption(
    String streamId,
    String viewerId,
  ) async {
    try {
      final aesKey = await StreamKeyExchangeService.getStreamKey(streamId,
          otherUserId: viewerId);
      if (aesKey == null) {
        print(
            'Verification failed: No encryption key found for stream $streamId');
        return false;
      }

      if (aesKey.length != 32) {
        print('Verification failed: Invalid key length ${aesKey.length} bytes');
        return false;
      }

      final testData = Uint8List.fromList(List.generate(32, (i) => i % 256));
      final nonce = generateNonce();
      if (nonce.length != nonceLength) {
        print(
            'Verification failed: Invalid nonce length ${nonce.length} bytes');
        return false;
      }
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final testAad = buildAad(streamId, timestamp);
      final encryptCipher =
          createAesGcmCipher(true, aesKey, nonce, aad: testAad);
      final encrypted = encryptCipher.process(testData);
      final decryptCipher =
          createAesGcmCipher(false, aesKey, nonce, aad: testAad);
      final decrypted = decryptCipher.process(encrypted);

      if (!listEquals(testData, decrypted)) {
        print('Verification failed: Data mismatch after decryption');
        return false;
      }

      await StreamCryptoLogger.logFrame(
        streamId: streamId,
        operation: 'verify_encryption',
        frameSize: testData.length,
        success: true,
        additionalData: {
          'originalSize': testData.length,
          'encryptedSize': encrypted.length,
          'decryptedSize': decrypted.length,
        },
      );

      return true;
    } catch (e, stack) {
      print('Encryption verification failed with error: $e');
      print('Verification failed: $e\n$stack');

      await StreamCryptoLogger.logFrame(
        streamId: streamId,
        operation: 'verify_encryption',
        frameSize: 0,
        success: false,
        error: e.toString(),
        additionalData: {'stackTrace': stack.toString()},
      );
      return false;
    }
  }
}

class StreamCryptoLogger {
  static final _cryptoLogsRef =
      FirebaseFirestore.instance.collection('crypto_logs');

  static Future<void> logFrame({
    required String streamId,
    required String operation,
    required int frameSize,
    required bool success,
    String? error,
    Map<String, dynamic>? additionalData,
  }) async {
    try {
      await _cryptoLogsRef.add({
        'streamId': streamId,
        'operation': operation,
        'frameSize': frameSize,
        'success': success,
        'error': error,
        'timestamp': FieldValue.serverTimestamp(),
        'additionalData': additionalData,
      });
    } catch (e) {
      print('Error logging crypto operation: $e');
    }
  }
}
