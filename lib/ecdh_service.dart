import 'dart:typed_data';
import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:crypto/crypto.dart' as crypto;

class EcdhService {
  static final algorithm = X25519();
  static const secureStorage = FlutterSecureStorage();
  static final aesGcm = AesGcm.with256bits();

  static SecretKey _deriveKeyFromPassword(String password, String salt) {
    final keyMaterial = utf8.encode(password + salt);
    final hash = crypto.sha256.convert(keyMaterial);
    return SecretKey(Uint8List.fromList(hash.bytes));
  }

  static Future<Map<String, dynamic>> generateKeyPair() async {
    try {
      final keyPair = await algorithm.newKeyPair();
      final publicKey = await keyPair.extractPublicKey();
      final privateKeyBytes = await keyPair.extractPrivateKeyBytes();

      final uid = FirebaseAuth.instance.currentUser?.uid ?? 'unknown';
      final username = FirebaseAuth.instance.currentUser?.displayName ?? uid;

      print('[ECDH] [$username] Private key generated successfully');
      print('[ECDH] [$username] Public key generated successfully');

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

  static Future<SecretKey> _getEncryptionKey(
      String userId, String password) async {
    try {
      return _deriveKeyFromPassword(password, userId);
    } catch (e) {
      print('Error getting encryption key: $e');
      throw e;
    }
  }

  static Future<Map<String, dynamic>> encryptPrivateKey(
      String userId, String password, Uint8List privateKeyBytes) async {
    try {
      final encryptionKey = await _getEncryptionKey(userId, password);
      final nonce = aesGcm.newNonce();
      final aad = utf8.encode(userId);

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

  static Future<Map<String, dynamic>> decryptPrivateKey(
      String userId,
      String password,
      Uint8List encryptedPrivateKey,
      Uint8List nonce,
      Uint8List mac) async {
    try {
      final encryptionKey = await _getEncryptionKey(userId, password);
      final aad = utf8.encode(userId);

      final encryptedValue = SecretBox(
        encryptedPrivateKey,
        nonce: nonce,
        mac: Mac(mac),
      );

      final decryptedPrivateKey = await aesGcm.decrypt(
        encryptedValue,
        secretKey: encryptionKey,
        aad: aad,
      );

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
      final uid = FirebaseAuth.instance.currentUser?.uid ?? 'unknown';
      final username = FirebaseAuth.instance.currentUser?.displayName ?? uid;

      print('[ECDH] [$username] Private key stored securely');

      await FirebaseFirestore.instance.collection('user_keys').doc(userId).set({
        'email': user?.email,
        'encryptedPrivateKey':
            bytesToString(encryptionResult['encryptedPrivateKey']),
        'mac': bytesToString(encryptionResult['mac']),
        'nonce': bytesToString(encryptionResult['nonce']),
        'privateKeyLength': privateKeyBytes.length,
        'privateKeyUpdatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

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

      final uid = FirebaseAuth.instance.currentUser?.uid ?? 'unknown';
      final username = FirebaseAuth.instance.currentUser?.displayName ?? uid;

      print('[ECDH] [$username] Public key stored securely');

      return {
        'success': true,
        'keyLength': publicKeyBytes.length,
      };
    } catch (e) {
      print('Error saving public key: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

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

  static Future<Map<String, dynamic>> verifyPrivateKey(String userId) async {
    try {
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

      final doc = await FirebaseFirestore.instance
          .collection('user_keys')
          .doc(userId)
          .get();

      if (!doc.exists || !doc.data()!.containsKey('encryptedPrivateKey')) {
        return {'exists': false, 'error': 'No private key found for this user'};
      }
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

  static Future<Uint8List?> getPrivateKey(String userId,
      {String? password}) async {
    try {
      final localKey = await getPrivateKeyFromStorage(userId);
      if (localKey != null) {
        return localKey;
      }
      if (password == null) {
        print('Private key not in local storage and no password provided');
        return null;
      }
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
      final decryptResult = await decryptPrivateKey(
          userId, password, encryptedPrivateKey, nonce, mac);

      if (!decryptResult['success']) {
        return null;
      }
      return decryptResult['privateKeyBytes'];
    } catch (e) {
      print('Error getting private key: $e');
      return null;
    }
  }

  static Future<void> ensureUserHasKeyPair(String userId) async {
    final hasPrivate = await EcdhService.verifyPrivateKey(userId);
    final publicDoc = await FirebaseFirestore.instance
        .collection('user_keys')
        .doc(userId)
        .get();

    if (hasPrivate['exists'] && publicDoc.exists) {
      print('[ECDH] Key pair already exists for $userId');
      return;
    }

    print('[ECDH] Key pair missing. Generating now...');
    final result = await EcdhService.generateKeyPair();
    if (!result['success']) throw Exception(result['error']);

    await EcdhService.savePrivateKey(
        userId, 'default', result['privateKeyBytes']);
    await EcdhService.savePublicKey(userId, result['publicKeyBytes']);

    await FirebaseFirestore.instance.collection('user_keys').doc(userId).set(
        {'username': FirebaseAuth.instance.currentUser?.displayName ?? ''},
        SetOptions(merge: true));

    int retries = 0;
    const maxRetries = 5;
    const retryDelay = Duration(milliseconds: 300);

    while (retries < maxRetries) {
      final checkDoc = await FirebaseFirestore.instance
          .collection('user_keys')
          .doc(userId)
          .get();

      if (checkDoc.exists && checkDoc.data()!.containsKey('publicKey')) {
        print('[ECDH] Public key verified saved for $userId');
        return;
      }

      await Future.delayed(retryDelay);
      retries++;
    }
    throw Exception('[ECDH] Public key not confirmed after retries');
  }

  // Helper
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
