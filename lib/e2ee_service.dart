import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:pointycastle/export.dart';
import 'dart:math' as math;
import 'dart:convert';
import 'package:livestream_webrtc/exchange_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:livestream_webrtc/logger.dart';

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
    final streamBytes = utf8.encode(streamId);
    final tsBytes = ByteData(4)..setUint32(0, timestamp & 0xFFFFFFFF);
    return Uint8List.fromList(streamBytes + tsBytes.buffer.asUint8List());
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

  static Future<void> decryptRtpReceiver(
    RTCDataChannel channel,
    String streamId,
    String userId,
    String otherUserId,
    bool isStreamer, {
    void Function(Uint8List frameBytes)? onFrameDecrypted,
  }) async {
    channel.onMessage = (RTCDataChannelMessage message) async {
      try {
        print(
            '[E2EE] Viewer received data over channel: ${message.text.length} chars');

        final encryptedData = base64.decode(message.text);

        if (encryptedData.length < nonceLength)
          throw Exception('Invalid payload');

        final nonce = encryptedData.sublist(0, nonceLength);
        final timestampOffset = encryptedData.length - 4;
        if (timestampOffset < 0) throw Exception("Encrypted payload too short");
        final timestamp =
            ByteData.sublistView(encryptedData, timestampOffset).getUint32(0);
        final aad = buildAad(streamId, timestamp);

        final ciphertext = encryptedData.sublist(nonceLength, timestampOffset);

        print('[AAD] Viewer timestamp extracted from payload: $timestamp');

        final aesKey = await StreamKeyExchangeService.getStreamKey(streamId,
            otherUserId: otherUserId);
        if (aesKey == null) throw Exception('Decryption key not found');

        final stopwatch = Stopwatch()..start();

        final cipher = createAesGcmCipher(false, aesKey, nonce, aad: aad);
        final decryptedData = cipher.process(ciphertext);
        print('Decrypted Frame Received: ${decryptedData.length} bytes');

        stopwatch.stop();

        final durationMs = stopwatch.elapsedMilliseconds;
        if (onFrameDecrypted != null) {
          onFrameDecrypted(decryptedData);
        }
        EncryptionLogger.logDecryption(streamId, durationMs, success: true);

        _stats['framesProcessed'] += 1;
      } catch (e) {
        _stats['decryptionErrors'] += 1;
        print('Error decrypting frame: $e');
      }
    };
  }

  static Future<void> sendEncryptedFrame(
    RTCDataChannel channel,
    Uint8List frameBytes,
    String streamId,
    String viewerId,
  ) async {
    try {
      if (channel.state != RTCDataChannelState.RTCDataChannelOpen) {
        print('[WARN] Tried to send frame, but data channel is not open.');
        return;
      }

      final aesKey = await StreamKeyExchangeService.getStreamKey(streamId,
          otherUserId: viewerId);
      if (aesKey == null) throw Exception('Encryption key not found');

      final nonce = generateNonce();

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final aad = buildAad(streamId, timestamp);

      final cipher = createAesGcmCipher(true, aesKey, nonce, aad: aad);
      final cipherText = cipher.process(frameBytes);

      final payload = Uint8List(nonceLength + cipherText.length + 4)
        ..setRange(0, nonceLength, nonce)
        ..setRange(nonceLength, nonceLength + cipherText.length, cipherText)
        ..buffer
            .asByteData()
            .setUint32(nonceLength + cipherText.length, timestamp);

      print('[AAD] Streamer timestamp used in AAD: $timestamp');

      final stopwatch = Stopwatch()..start();
      channel.send(RTCDataChannelMessage(base64.encode(payload)));
      stopwatch.stop();

      _stats['framesProcessed'] += 1;

      EncryptionLogger.logEncryption(
        streamId,
        frameBytes.length,
        payload.length,
        stopwatch.elapsedMilliseconds,
        success: true,
      );
    } catch (e) {
      _stats['encryptionErrors'] += 1;
      print('Error encrypting frame: $e');
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
      if (decryptCipher == null) {
        print('Verification failed: Could not create decryption cipher');
        return false;
      }

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
