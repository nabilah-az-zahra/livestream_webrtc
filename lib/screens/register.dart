import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:livestream_webrtc/screens/login.dart';
import 'package:livestream_webrtc/ecdh_service.dart';
import 'package:livestream_webrtc/logger.dart';

bool isObscure = false;

class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});
  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final TextEditingController nameController = TextEditingController();
  final TextEditingController emailController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();
  bool isObscure = true;
  bool isRegistering = false;

  Future<void> registerUser() async {
    if (isRegistering) return;

    setState(() {
      isRegistering = true;
    });

    try {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Registering and generating secure keys...')),
      );

      UserCredential userCredential =
          await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: emailController.text.trim(),
        password: passwordController.text.trim(),
      );

      final userId = userCredential.user!.uid;
      final username = nameController.text.trim();
      final password = passwordController.text.trim();

      // Generate and verify key pair
      final keyGenResult = await EcdhService.generateKeyPair();
      if (!keyGenResult['success']) {
        throw Exception('Failed to generate keys: ${keyGenResult['error']}');
      }

      // Extract private key bytes first
      final privateKeyBytes = keyGenResult['privateKeyBytes'];
      final publicKeyBytes = keyGenResult['publicKeyBytes'];

      // final keyPair = keyGenResult['keyPair'];

      // Save private key securely on device
      final privateKeyResult =
          await EcdhService.savePrivateKey(userId, password, privateKeyBytes);
      if (!privateKeyResult['success']) {
        throw Exception(
            'Failed to save private key: ${privateKeyResult['error']}');
      }

      // Save and verify public key
      final publicKeyResult =
          await EcdhService.savePublicKey(userId, publicKeyBytes);
      if (!publicKeyResult['success']) {
        throw Exception(
            'Failed to save public key: ${publicKeyResult['error']}');
      }

      // Verify private key was saved
      final verifyResult = await EcdhService.verifyPrivateKey(userId);
      if (!verifyResult['exists']) {
        throw Exception(
            'Private key verification failed: ${verifyResult['error']}');
      }

      // Log successful key generation and storage
      print('Key generation successful:');
      // print('- Private key length: ${privateKeyResult['keyLength']}');
      // print('- Private key preview: ${verifyResult['keyPreview']}');
      // print('- Public key length: ${publicKeyResult['keyLength']}');
      EncryptionLogger.logKeyGeneration(
          userId: userId, publicKeyPreview: publicKeyBytes.take(8).join(','));

      await FirebaseFirestore.instance.collection('users').doc(userId).set({
        'username': username,
        'email': emailController.text.trim(),
        'keyStatus': {
          'privateKeyGenerated': true,
          'privateKeyGenerationTime': FieldValue.serverTimestamp(),
          'privateKeyLength': verifyResult['keyLength'],
          'privateKeyStatus': 'Generated and Encrypted',
          'lastVerificationTime': FieldValue.serverTimestamp(),
        },
        'keyDetails': {
          'algorithm': 'X25519',
          'publicKeyLength': publicKeyBytes.length,
          'privateKeyStorage': 'AES-256-GCM Encrypted',
          'createdAt': FieldValue.serverTimestamp(),
          'lastUpdated': FieldValue.serverTimestamp(),
        },
        'userMetadata': {
          'createdAt': FieldValue.serverTimestamp(),
          'lastLogin': FieldValue.serverTimestamp(),
          'isOnline': true
        }
      });

      // Update display name
      await userCredential.user?.updateDisplayName(nameController.text.trim());

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Registration Successful!')),
      );

      Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => const LoginPage()),
      );
    } catch (e) {
      String errorMessage = 'Registration Failed';
      if (e is FirebaseAuthException) {
        if (e.code == 'email-already-in-use') {
          errorMessage = 'Email already in use';
        } else if (e.code == 'weak-password') {
          errorMessage = 'Password should be at least 6 characters';
        }
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$errorMessage: ${e.toString()}')),
      );
    } finally {
      setState(() {
        isRegistering = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 42),
          child: Center(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  Text('Registration',
                      style: GoogleFonts.kanit(
                        color: const Color(0xFF1E1E1E),
                        fontSize: 28,
                        fontWeight: FontWeight.w500,
                      )),
                  const SizedBox(
                    height: 100,
                  ),
                  Container(
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFD9D9D9),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.2),
                          offset: const Offset(2, 2),
                          blurRadius: 4,
                        ),
                      ],
                    ),
                    child: TextField(
                      controller: nameController,
                      cursorColor: Colors.black,
                      decoration: InputDecoration(
                        hintText: 'Username',
                        hintStyle: GoogleFonts.kanit(
                            color: const Color(0xff1E1E1E).withOpacity(0.5)),
                        enabledBorder: OutlineInputBorder(
                          borderSide: BorderSide.none,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderSide:
                              const BorderSide(color: Colors.black, width: 2),
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(
                    height: 20,
                  ),
                  Container(
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFD9D9D9),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.2),
                          offset: const Offset(2, 2),
                          blurRadius: 4,
                        ),
                      ],
                    ),
                    child: TextField(
                      controller: emailController,
                      cursorColor: Colors.black,
                      decoration: InputDecoration(
                        hintText: 'Email',
                        hintStyle: GoogleFonts.kanit(
                            color: const Color(0xff1E1E1E).withOpacity(0.5)),
                        enabledBorder: OutlineInputBorder(
                          borderSide: BorderSide.none,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderSide:
                              const BorderSide(color: Colors.black, width: 2),
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(
                    height: 20,
                  ),
                  Container(
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFD9D9D9),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.2),
                          offset: const Offset(2, 2),
                          blurRadius: 4,
                        ),
                      ],
                    ),
                    child: TextField(
                      controller: passwordController,
                      cursorColor: Colors.black,
                      obscureText: isObscure,
                      decoration: InputDecoration(
                        hintText: 'Password',
                        hintStyle: GoogleFonts.kanit(
                            color: const Color(0xff1E1E1E).withOpacity(0.5)),
                        suffixIcon: GestureDetector(
                          onTap: () {
                            setState(() {
                              isObscure = !isObscure;
                            });
                          },
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: isObscure
                                ? const Icon(
                                    Icons.visibility_off_outlined,
                                    color: Color(0xFF1C1B1F),
                                  )
                                : const Icon(
                                    Icons.visibility_outlined,
                                    color: Color(0xFF1C1B1F),
                                  ),
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderSide: BorderSide.none,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderSide:
                              const BorderSide(color: Colors.black, width: 2),
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(
                    height: 100,
                  ),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton(
                      onPressed: isRegistering ? null : registerUser,
                      style: ElevatedButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.symmetric(
                          vertical: 8,
                        ),
                        backgroundColor: const Color(0xFF1E1E1E),
                      ),
                      child: isRegistering
                          ? const CircularProgressIndicator(
                              color: Colors.white,
                            )
                          : Text(
                              'Register',
                              style: GoogleFonts.kanit(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w400,
                                  color: const Color(0xFFFFFFFF)),
                            ),
                    ),
                  ),
                  const SizedBox(
                    height: 20,
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'Already have an account? ',
                        style: GoogleFonts.kanit(
                          fontSize: 16,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                      GestureDetector(
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => const LoginPage(),
                            ),
                          );
                        },
                        child: Text(
                          'Login',
                          style: GoogleFonts.kanit(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
