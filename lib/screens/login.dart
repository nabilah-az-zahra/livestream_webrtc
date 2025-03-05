import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:livestream_webrtc/screens/homepage.dart';
import 'package:livestream_webrtc/screens/register.dart';
import 'package:livestream_webrtc/ecdh_service.dart';

bool isObscure = false;

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController emailController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();
  bool isObscure = true;

  Future<void> loginUser() async {
    try {
      final userCredential =
          await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: emailController.text.trim(),
        password: passwordController.text.trim(),
      );

      final userId = userCredential.user!.uid;

      // Verify private key exists on device
      final verifyResult = await EcdhService.verifyPrivateKey(userId);
      if (!verifyResult['exists']) {
        throw Exception('Private key not found. Please register again.');
      }

      // Update user status in Firestore
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

      print('Login successful for user: $userId');

      final privateKey = await EcdhService.getPrivateKey(userId);
      if (privateKey == null) {
        // Try restoring from Firestore
        final userDoc = await FirebaseFirestore.instance
            .collection('users')
            .doc(userId)
            .get();
        if (userDoc.exists && userDoc.data()!.containsKey('privateKey')) {
          final restoredKey = userDoc.data()!['privateKey'];
          await EcdhService.savePrivateKey(userId, restoredKey);
          print("Private key successfully restored.");
        } else {
          throw Exception('Private key not found. Please register again.');
        }
      }

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
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(errorMessage)),
      );
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
                  TextField(
                    controller: emailController,
                    decoration: InputDecoration(
                      hintText: 'Email',
                      hintStyle: GoogleFonts.kanit(
                          color: const Color(0xff1E1E1E).withOpacity(0.5)),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                  const SizedBox(
                    height: 30,
                  ),
                  TextField(
                    controller: passwordController,
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
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
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
                      onPressed: () async {
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
                      ),
                      child: Text(
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
