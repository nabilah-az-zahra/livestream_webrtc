import 'package:cloud_firestore/cloud_firestore.dart';

class EncryptionLogger {
  static void logKeyGeneration(
      {required String userId, required String publicKeyPreview}) {
    print('[ECDH] [$userId] Public key generated: $publicKeyPreview');
    print('[ECDH] [$userId] Private key stored securely');
  }

  static void logKeyExchangeStart(
      String streamId, String userId, String peerId) {
    print(
        '[KEY_EXCHANGE] Stream: $streamId | User: $userId → $peerId | Exchange started');
  }

  static void logSharedSecretDerived(
      String userId, String streamId, String hashedKeyPreview) {
    print('[KEY_EXCHANGE] [$userId] Shared secret derived on stream $streamId');
    print('[KEY_EXCHANGE] [$userId] AES key hash preview: $hashedKeyPreview');
  }

  static void logEncryption(
    String streamId,
    int originalSize,
    int encryptedSize,
    int durationMs, {
    bool success = true,
  }) {
    final status = success ? 'Success' : 'Failed';
    print(
        '[ENCRYPT] Stream: $streamId | Size: $originalSize → $encryptedSize | Time: ${durationMs}ms | Status: $status');
  }

  static void logDecryption(
    String streamId,
    int durationMs, {
    bool success = true,
  }) {
    final status = success ? 'Success' : 'Failed';
    print(
        '[DECRYPT] Stream: $streamId | Status: $status | Time: ${durationMs}ms');
  }

  static Future<void> logCryptoTiming({
    required String streamId,
    required String operation,
    required int frameSize,
    required double durationMs,
    required bool success,
    String? error,
  }) async {
    await FirebaseFirestore.instance.collection('e2eetime_logs').add({
      'streamId': streamId,
      'operation': operation,
      'frameSize': frameSize,
      'durationMs': durationMs,
      'success': success,
      'error': error,
      'timestamp': FieldValue.serverTimestamp(),
    });
  }

  static void logEndToEndFlow(
      {required String streamerId, required String viewerId}) {
    print('[E2E] Viewer $viewerId successfully joined stream from $streamerId');
    print('[E2E] Encrypted frame transmitted and decrypted on viewer side');
  }

  static void logMessage(String message) {
    print('[LOG] $message');
  }
}
