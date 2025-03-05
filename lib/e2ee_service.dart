import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:pointycastle/export.dart';
import 'dart:math' as math;
import 'dart:convert';
import 'package:livestream_webrtc/exchange_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class StreamCryptoService {
  static const int nonceLength = 12; // 96 bits for GCM
  static const int tagLength = 16; // 128 bits authentication tag
  static const int keyRotationInterval = 3600000; // 1 hour in milliseconds
  static const int maxRetries = 3;

  // Track encryption statistics
  static Map<String, dynamic> _stats = {
    'framesProcessed': 0,
    'encryptionErrors': 0,
    'decryptionErrors': 0,
    'lastKeyRotation': DateTime.now().millisecondsSinceEpoch,
  };

  // Create AES-GCM cipher instance
  static GCMBlockCipher _createAesGcmCipher(
      bool forEncryption, Uint8List key, Uint8List nonce,
      {Uint8List? aad}) {
    final cipher = GCMBlockCipher(AESEngine());
    final params = AEADParameters(
        KeyParameter(key), tagLength * 8, nonce, aad ?? Uint8List(0));
    cipher.init(forEncryption, params);
    return cipher;
  }

  // Generate secure random bytes
  static Uint8List _generateNonce() {
    final secureRandom = SecureRandom('Fortuna')
      ..seed(KeyParameter(Uint8List.fromList(
          List.generate(32, (n) => math.Random.secure().nextInt(256)))));
    return secureRandom.nextBytes(nonceLength);
  }

  // Rotate encryption key
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

  // Encrypt RTCRtpSender data
  static Future<void> encryptRtpSender(
    RTCDataChannel channel,
    String streamId,
    String userId,
    String otherUserId,
    bool isStreamer,
  ) async {
    channel.onMessage = (RTCDataChannelMessage message) async {
      try {
        final frameData = Uint8List.fromList(utf8.encode(message.text));

        // Log pre-encryption
        await StreamCryptoLogger.logFrame(
          streamId: streamId,
          operation: 'encrypt_start',
          frameSize: frameData.length,
          success: true,
          additionalData: {
            'userId': userId,
            'isStreamer': isStreamer,
          },
        );

        // Get AES key for encryption
        final aesKey = await StreamKeyExchangeService.getStreamKey(streamId);
        if (aesKey == null) throw Exception('Encryption key not found');

        // Generate a secure random nonce
        final nonce = _generateNonce();

        // Encrypt frame data
        final cipher = _createAesGcmCipher(true, aesKey, nonce);
        final encryptedData = cipher.process(frameData);

        // Append nonce + encrypted frame for transmission
        final encryptedFrame = Uint8List(nonceLength + encryptedData.length);
        encryptedFrame.setAll(0, nonce);
        encryptedFrame.setAll(nonceLength, encryptedData);

        // Encode encrypted frame as Base64 string before sending
        final encodedMessage = base64.encode(encryptedFrame);
        channel.send(RTCDataChannelMessage(encodedMessage));

        print('Encrypted Frame Sent: ${encryptedFrame.length} bytes');

        // Log successful encryption
        await StreamCryptoLogger.logFrame(
          streamId: streamId,
          operation: 'encrypt_complete',
          frameSize: encryptedFrame.length,
          success: true,
          additionalData: {
            'originalSize': frameData.length,
            'encryptedSize': encryptedFrame.length,
          },
        );
      } catch (e) {
        await StreamCryptoLogger.logFrame(
          streamId: streamId,
          operation: 'encrypt_error',
          frameSize: 0,
          success: false,
          error: e.toString(),
        );
        print('Error encrypting frame: $e');
      }
    };
  }

  // Decrypt RTCRtpReceiver data with retry mechanism
  static Future<void> decryptRtpReceiver(
    RTCDataChannel channel,
    String streamId,
    String userId,
    String otherUserId,
    bool isStreamer,
  ) async {
    channel.onMessage = (RTCDataChannelMessage message) async {
      try {
        // Decode Base64 string back to Uint8List
        final encryptedData = base64.decode(message.text);

        // Extract nonce and ciphertext
        final nonce = encryptedData.sublist(0, nonceLength);
        final ciphertext = encryptedData.sublist(nonceLength);

        // Get AES key for decryption
        final aesKey = await StreamKeyExchangeService.getStreamKey(streamId);
        if (aesKey == null) throw Exception('Decryption key not found');

        // Decrypt frame data
        final cipher = _createAesGcmCipher(false, aesKey, nonce);
        final decryptedData = cipher.process(ciphertext);

        print('Decrypted Frame Received: ${decryptedData.length} bytes');
      } catch (e) {
        print('Error decrypting frame: $e');
      }
    };
  }

  // Get encryption stats
  static Map<String, dynamic> getStats() {
    return {
      ..._stats,
      'errorRate': _stats['framesProcessed'] > 0
          ? (_stats['encryptionErrors'] + _stats['decryptionErrors']) /
              _stats['framesProcessed']
          : 0,
    };
  }

  // Reset stats
  static void resetStats() {
    _stats = {
      'framesProcessed': 0,
      'encryptionErrors': 0,
      'decryptionErrors': 0,
      'lastKeyRotation': DateTime.now().millisecondsSinceEpoch,
    };
  }

  // Helper to verify encryption is working with current key
  static Future<bool> verifyEncryption(String streamId) async {
    try {
      print('Verifying encryption for stream: $streamId');

      final aesKey = await StreamKeyExchangeService.getStreamKey(streamId);
      if (aesKey == null) {
        print(
            'Verification failed: No encryption key found for stream $streamId');
        return false;
      }

      // Verify key length
      if (aesKey.length != 32) {
        print('Verification failed: Invalid key length ${aesKey.length} bytes');
        return false;
      }

      // Create test data
      final testData =
          Uint8List.fromList(List.generate(32, (index) => index % 256));

      // Generate nonce for the test
      final nonce = _generateNonce();
      if (nonce.length != nonceLength) {
        print(
            'Verification failed: Invalid nonce length ${nonce.length} bytes');
        return false;
      }

      // Create authenticated data
      final aad = ByteData(12);
      aad.setUint32(0, 0);
      aad.setUint32(4, DateTime.now().millisecondsSinceEpoch & 0xFFFFFFFF);
      final aadBytes = aad.buffer.asUint8List();

      // Test encryption
      print('Attempting to encrypt test data...');
      final encryptCipher =
          _createAesGcmCipher(true, aesKey, nonce, aad: aadBytes);
      if (encryptCipher == null) {
        print('Verification failed: Could not create encryption cipher');
        return false;
      }

      print('Attempting to encrypt test data...');
      final encrypted = encryptCipher.process(testData);
      print(
          'Test encryption successful. Encrypted length: ${encrypted.length} bytes');

      // Test decryption
      print('Attempting to decrypt test data...');
      final decryptCipher =
          _createAesGcmCipher(false, aesKey, nonce, aad: aadBytes);
      if (decryptCipher == null) {
        print('Verification failed: Could not create decryption cipher');
        return false;
      }

      print('Attempting to decrypt test data...');
      final decrypted = decryptCipher.process(encrypted);
      print(
          'Test decryption successful. Decrypted length: ${decrypted.length} bytes');

      // Verify the round trip
      if (!listEquals(testData, decrypted)) {
        print('Verification failed: Data mismatch after decryption');
        return false;
      }

      // Log successful verification
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

      print('Encryption verification successful for stream $streamId');

      return true;
    } catch (e, stackTrace) {
      print('Encryption verification failed with error: $e');
      print('Stack trace: $stackTrace');

      // Log the failure
      await StreamCryptoLogger.logFrame(
        streamId: streamId,
        operation: 'verify_encryption',
        frameSize: 0,
        success: false,
        error: e.toString(),
        additionalData: {'stackTrace': stackTrace.toString()},
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
