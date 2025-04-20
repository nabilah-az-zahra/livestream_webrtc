import 'dart:typed_data';
import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:livestream_webrtc/logger.dart';

class EcdhService {
  static final algorithm = X25519();
  static const secureStorage = FlutterSecureStorage();
  static final aesGcm = AesGcm.with256bits();

  // Password-based key derivation function
  static SecretKey _deriveKeyFromPassword(String password, String salt) {
    final keyMaterial = utf8.encode(password + salt);
    final hash = crypto.sha256.convert(keyMaterial);
    return SecretKey(Uint8List.fromList(hash.bytes));
  }

  // Generate key pair with verification
  static Future<Map<String, dynamic>> generateKeyPair() async {
    try {
      final keyPair = await algorithm.newKeyPair();
      final publicKey = await keyPair.extractPublicKey();
      final privateKeyBytes = await keyPair.extractPrivateKeyBytes();

      EncryptionLogger.logKeyGeneration(
        userId: FirebaseAuth.instance.currentUser?.uid ?? 'unknown',
        publicKeyPreview: publicKey.bytes.take(8).toString(),
      );

      return {
        'keyPair': keyPair,
        'publicKeyBytes': publicKey.bytes,
        'privateKeyBytes': Uint8List.fromList(privateKeyBytes),
        'success': true
      };
    } catch (e) {
      print('Error generating key pair: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  // Get device encryption key - revised to support cross-device usage
  static Future<SecretKey> _getEncryptionKey(
      String userId, String password) async {
    try {
      // Derive a consistent key from the user's password and user ID
      return _deriveKeyFromPassword(password, userId);
    } catch (e) {
      print('Error getting encryption key: $e');
      throw e;
    }
  }

  // Encrypt private key using AES-256-GCM with password-derived key
  static Future<Map<String, dynamic>> encryptPrivateKey(
      String userId, String password, Uint8List privateKeyBytes) async {
    try {
      final encryptionKey = await _getEncryptionKey(userId, password);

      // Generate a random nonce
      final nonce = aesGcm.newNonce();

      // Additional authentication data (user ID)
      final aad = utf8.encode(userId);

      // Encrypt the private key
      final encryptionResult = await aesGcm.encrypt(
        privateKeyBytes,
        secretKey: encryptionKey,
        nonce: nonce,
        aad: aad,
      );

      return {
        'encryptedPrivateKey': encryptionResult.cipherText,
        'nonce': encryptionResult.nonce,
        'mac': encryptionResult.mac.bytes,
        'success': true,
      };
    } catch (e) {
      print('Error encrypting private key: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  // Decrypt private key using AES-256-GCM with password-derived key
  static Future<Map<String, dynamic>> decryptPrivateKey(
      String userId,
      String password,
      Uint8List encryptedPrivateKey,
      Uint8List nonce,
      Uint8List mac) async {
    try {
      final encryptionKey = await _getEncryptionKey(userId, password);

      // Additional authentication data (user ID)
      final aad = utf8.encode(userId);

      // Create the encrypted value with MAC
      final encryptedValue = SecretBox(
        encryptedPrivateKey,
        nonce: nonce,
        mac: Mac(mac),
      );

      // Decrypt the private key
      final decryptedPrivateKey = await aesGcm.decrypt(
        encryptedValue,
        secretKey: encryptionKey,
        aad: aad,
      );

      // Store the decrypted private key in local secure storage for future use
      await secureStorage.write(
        key: 'private_key_$userId',
        value: bytesToString(Uint8List.fromList(decryptedPrivateKey)),
      );

      return {
        'privateKeyBytes': decryptedPrivateKey,
        'success': true,
      };
    } catch (e) {
      print('Error decrypting private key: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  // Save both private and public keys to Firebase
  static Future<Map<String, dynamic>> savePrivateKey(
      String userId, String password, Uint8List privateKeyBytes) async {
    try {
      // Also save a copy in secure storage
      await secureStorage.write(
        key: 'private_key_$userId',
        value: bytesToString(privateKeyBytes),
      );

      final encryptionResult =
          await encryptPrivateKey(userId, password, privateKeyBytes);
      if (!encryptionResult['success']) {
        return {'success': false, 'error': 'Failed to encrypt private key'};
      }

      final user = FirebaseAuth.instance.currentUser;

      await FirebaseFirestore.instance.collection('user_keys').doc(userId).set({
        'email': user?.email,
        'encryptedPrivateKey':
            bytesToString(encryptionResult['encryptedPrivateKey']),
        'nonce': bytesToString(encryptionResult['nonce']),
        'mac': bytesToString(encryptionResult['mac']),
        'updatedAt': FieldValue.serverTimestamp(),
        'keyLength': privateKeyBytes.length,
        'algorithm': 'AES-256-GCM',
        'encryptionMethod': 'Password-derived key',
      }, SetOptions(merge: true));

      // Verify the key was saved
      final doc = await FirebaseFirestore.instance
          .collection('user_keys')
          .doc(userId)
          .get();

      if (!doc.exists || !doc.data()!.containsKey('encryptedPrivateKey')) {
        return {
          'success': false,
          'error': 'Private key was not saved properly'
        };
      }

      return {
        'success': true,
        'keyLength': privateKeyBytes.length,
      };
    } catch (e) {
      print('Error saving private key: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  // Save public key with verification
  static Future<Map<String, dynamic>> savePublicKey(
      String userId, Uint8List publicKeyBytes) async {
    try {
      final publicKeyString = bytesToString(publicKeyBytes);

      await FirebaseFirestore.instance.collection('user_keys').doc(userId).set({
        'publicKey': publicKeyString,
        'publicKeyUpdatedAt': FieldValue.serverTimestamp(),
        'publicKeyLength': publicKeyBytes.length,
      }, SetOptions(merge: true));

      // Verify the key was saved
      final doc = await FirebaseFirestore.instance
          .collection('user_keys')
          .doc(userId)
          .get();

      if (!doc.exists || !doc.data()!.containsKey('publicKey')) {
        return {
          'success': false,
          'error': 'Public key was not saved to Firebase'
        };
      }

      return {
        'success': true,
        'keyLength': publicKeyBytes.length,
      };
    } catch (e) {
      print('Error saving public key: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  // Check if private key exists in local storage first
  static Future<Uint8List?> getPrivateKeyFromStorage(String userId) async {
    try {
      final storedKey = await secureStorage.read(key: 'private_key_$userId');
      if (storedKey != null) {
        return stringToBytes(storedKey);
      }
      return null;
    } catch (e) {
      print('Error accessing local storage: $e');
      return null;
    }
  }

  // Verify private key accessibility
  static Future<Map<String, dynamic>> verifyPrivateKey(String userId) async {
    try {
      // First check local secure storage
      final localKey = await getPrivateKeyFromStorage(userId);
      if (localKey != null) {
        final prefix = localKey.sublist(0, min(4, localKey.length));
        final suffix =
            localKey.sublist(max(0, localKey.length - 4), localKey.length);

        return {
          'exists': true,
          'recoverable': true,
          'keyLength': localKey.length,
          'keyPreview': '${prefix.toString()}...${suffix.toString()}',
          'source': 'local_storage'
        };
      }

      // If not in local storage, check Firebase
      final doc = await FirebaseFirestore.instance
          .collection('user_keys')
          .doc(userId)
          .get();

      if (!doc.exists || !doc.data()!.containsKey('encryptedPrivateKey')) {
        return {'exists': false, 'error': 'No private key found for this user'};
      }

      // Key exists in Firebase but will need password to decrypt
      return {
        'exists': true,
        'recoverable': true,
        'keyLength': doc.data()!['keyLength'],
        'requiresPassword': true,
        'source': 'firebase'
      };
    } catch (e) {
      return {'exists': false, 'error': e.toString()};
    }
  }

  // Get private key - checks local storage first, then Firebase
  static Future<Uint8List?> getPrivateKey(String userId,
      {String? password}) async {
    try {
      // First check local secure storage
      final localKey = await getPrivateKeyFromStorage(userId);
      if (localKey != null) {
        return localKey;
      }

      // If not in local storage and no password provided, we can't proceed
      if (password == null) {
        print('Private key not in local storage and no password provided');
        return null;
      }

      // Try to retrieve from Firebase and decrypt with password
      final doc = await FirebaseFirestore.instance
          .collection('user_keys')
          .doc(userId)
          .get();

      if (!doc.exists || !doc.data()!.containsKey('encryptedPrivateKey')) {
        return null;
      }

      final encryptedPrivateKey =
          stringToBytes(doc.data()!['encryptedPrivateKey']);
      final nonce = stringToBytes(doc.data()!['nonce']);
      final mac = stringToBytes(doc.data()!['mac']);

      // Decrypt the private key using the password
      final decryptResult = await decryptPrivateKey(
          userId, password, encryptedPrivateKey, nonce, mac);

      if (!decryptResult['success']) {
        return null;
      }

      // The decryption method already stores the key in secure storage
      return decryptResult['privateKeyBytes'];
    } catch (e) {
      print('Error getting private key: $e');
      return null;
    }
  }

  // Helper methods
  static String bytesToString(Uint8List bytes) {
    return base64Encode(bytes);
  }

  static Uint8List stringToBytes(String str) {
    return base64Decode(str);
  }

  static String bytesToHex(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static Uint8List hexToBytes(String hex) {
    return Uint8List.fromList(List.generate(hex.length ~/ 2,
        (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16)));
  }

  static int min(int a, int b) => a < b ? a : b;
  static int max(int a, int b) => a > b ? a : b;
}
