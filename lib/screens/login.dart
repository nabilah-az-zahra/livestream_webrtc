import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:livestream_webrtc/screens/homepage.dart';
import 'package:livestream_webrtc/screens/register.dart';
import 'package:livestream_webrtc/ecdh_service.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController emailController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();
  bool isObscure = true;
  bool isLoggingIn = false;

  Future<void> loginUser() async {
    if (isLoggingIn) return;

    setState(() {
      isLoggingIn = true;
    });

    try {
      final userCredential =
          await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: emailController.text.trim(),
        password: passwordController.text.trim(),
      );

      final userId = userCredential.user!.uid;
      final password = passwordController.text.trim();

      final uid = FirebaseAuth.instance.currentUser?.uid ?? 'unknown';
      final username = FirebaseAuth.instance.currentUser?.displayName ?? uid;

      final verifyResult = await EcdhService.verifyPrivateKey(userId);
      if (!verifyResult['exists']) {
        throw Exception('Private key not found. Please register again.');
      }

      Uint8List? privateKeyBytes;

      if (verifyResult['source'] == 'local_storage') {
        privateKeyBytes = await EcdhService.getPrivateKeyFromStorage(userId);
      } else {
        privateKeyBytes =
            await EcdhService.getPrivateKey(userId, password: password);
      }

      if (privateKeyBytes == null) {
        throw Exception(
            'Failed to retrieve private key. Please register again.');
      }

      await FirebaseFirestore.instance.collection('users').doc(userId).update({
        'userMetadata': {
          'lastLogin': FieldValue.serverTimestamp(),
          'isOnline': true,
        },
        'keyStatus': {
          'lastVerificationTime': FieldValue.serverTimestamp(),
          'privateKeyStatus': 'Verified on Login',
        }
      });

      print('Login successful for user: $username');

      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        await EcdhService.ensureUserHasKeyPair(user.uid);
      }

      await Future.delayed(const Duration(milliseconds: 500));

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Login Successful!')),
      );

      Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => const HomePage()),
      );
    } catch (e) {
      print('Login error: $e');

      String errorMessage = 'Login Failed';
      if (e is FirebaseAuthException) {
        print('FirebaseAuthException: ${e.code} - ${e.message}');
        if (e.code == 'user-not-found') {
          errorMessage = 'No user found with this email';
        } else if (e.code == 'wrong-password') {
          errorMessage = 'Incorrect password';
        } else if (e.code == 'invalid-email') {
          errorMessage = 'Invalid email format';
        } else {
          errorMessage = e.message ?? 'Authentication failed';
        }
      } else if (e.toString().contains('Private key not found')) {
        errorMessage = 'Private key missing. Please register again.';
      } else if (e.toString().contains('cannot be decrypted')) {
        errorMessage = 'Private key decryption failed. Please register again.';
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(errorMessage)),
      );
    } finally {
      setState(() {
        isLoggingIn = false;
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
                  Text('Login',
                      style: GoogleFonts.kanit(
                        color: const Color(0xFF1E1E1E),
                        fontSize: 28,
                        fontWeight: FontWeight.w500,
                      )),
                  const SizedBox(
                    height: 140,
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
                    height: 120,
                  ),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton(
                      onPressed: isLoggingIn
                          ? null
                          : () async {
                              await loginUser();
                            },
                      style: ElevatedButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.symmetric(
                          vertical: 8,
                        ),
                        backgroundColor: const Color(0xFF1E1E1E),
                        disabledBackgroundColor:
                            const Color(0xFF1E1E1E).withOpacity(0.6),
                      ),
                      child: isLoggingIn
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2.0,
                              ),
                            )
                          : Text(
                              'Login',
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
                        'Dont have an account? ',
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
                              builder: (context) => const RegisterPage(),
                            ),
                          );
                        },
                        child: Text(
                          'Register',
                          style: GoogleFonts.kanit(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                    ],
                  ),
                  // const SizedBox(
                  //   height: 4,
                  // ),
                  // SizedBox(
                  //   width: double.infinity,
                  //   height: 52,
                  //   child: ElevatedButton(
                  //     onPressed: () => (),
                  //     style: ElevatedButton.styleFrom(
                  //       padding: const EdgeInsets.symmetric(
                  //         vertical: 12,
                  //       ),
                  //       backgroundColor: Colors.white,
                  //       side: const BorderSide(
                  //         color: Color(0xFF011A41),
                  //       ),
                  //     ),
                  //     child: const Row(
                  //       mainAxisAlignment: MainAxisAlignment.center,
                  //       children: [
                  //         Image(
                  //           width: 19,
                  //           image: AssetImage(
                  //             'assets/images/Group.png',
                  //           ),
                  //         ),
                  //         SizedBox(
                  //           width: 5,
                  //         ),
                  //         Text(
                  //           'Masuk dengan google',
                  //           style: TextStyle(
                  //             color: Color(0xFF011A41),
                  //             fontSize: 16,
                  //             fontWeight: FontWeight.w400,
                  //           ),
                  //         ),
                  //       ],
                  //     ),
                  //   ),
                  // ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
