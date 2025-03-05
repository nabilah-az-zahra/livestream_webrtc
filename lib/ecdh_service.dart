import 'dart:typed_data';
import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class EcdhService {
  static final algorithm = X25519();
  static const secureStorage = FlutterSecureStorage();

  // Generate key pair with verification
  static Future<Map<String, dynamic>> generateKeyPair() async {
    try {
      final keyPair = await algorithm.newKeyPair();
      final publicKey = await keyPair.extractPublicKey();
      final privateKeyBytes = await keyPair.extractPrivateKeyBytes();

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

  // Save both private and public keys to Firebase
  static Future<Map<String, dynamic>> savePrivateKey(
      String userId, Uint8List privateKeyBytes) async {
    try {
      final privateKeyString = bytesToString(privateKeyBytes);

      await FirebaseFirestore.instance
          .collection('user_private_keys')
          .doc(userId)
          .set({
        'privateKey': privateKeyString,
        'updatedAt': FieldValue.serverTimestamp(),
        'keyLength': privateKeyBytes.length,
      });

      // Verify the key was saved
      final doc = await FirebaseFirestore.instance
          .collection('user_private_keys')
          .doc(userId)
          .get();

      if (!doc.exists || !doc.data()!.containsKey('privateKey')) {
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

      await FirebaseFirestore.instance.collection('users').doc(userId).set({
        'publicKey': publicKeyString,
        'publicKeyUpdatedAt': FieldValue.serverTimestamp(),
        'publicKeyLength': publicKeyBytes.length,
      }, SetOptions(merge: true));

      // Verify the key was saved
      final doc = await FirebaseFirestore.instance
          .collection('users')
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

  static Future<Map<String, dynamic>> verifyPrivateKey(String userId) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('user_private_keys')
          .doc(userId)
          .get();

      if (!doc.exists || !doc.data()!.containsKey('privateKey')) {
        return {'exists': false, 'error': 'No private key found for this user'};
      }

      final privateKeyString = doc.data()!['privateKey'];
      final privateKeyBytes = stringToBytes(privateKeyString);

      final prefix = privateKeyBytes.sublist(0, min(4, privateKeyBytes.length));
      final suffix = privateKeyBytes.sublist(
          max(0, privateKeyBytes.length - 4), privateKeyBytes.length);

      return {
        'exists': true,
        'keyLength': privateKeyBytes.length,
        'keyPreview': '${prefix.toString()}...${suffix.toString()}',
      };
    } catch (e) {
      return {'exists': false, 'error': e.toString()};
    }
  }

  // Get private key from Firebase
  static Future<String?> getPrivateKey(String userId) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('user_private_keys')
          .doc(userId)
          .get();

      if (!doc.exists || !doc.data()!.containsKey('privateKey')) {
        return null;
      }

      return doc.data()!['privateKey'];
    } catch (e) {
      print('Error getting private key: $e');
      return null;
    }
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
