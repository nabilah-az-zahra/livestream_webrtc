import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.macOS:
        return macos;
      case TargetPlatform.windows:
        return windows;
      case TargetPlatform.linux:
        throw UnsupportedError(
          'DefaultFirebaseOptions have not been configured for linux - '
          'you can reconfigure this by running the FlutterFire CLI again.',
        );
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not supported for this platform.',
        );
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyAOt89kwMu_E44Dyei4jK-fEABpSFMthgA',
    appId: '1:766475877975:web:e2cc54745d3f1df9ad2d12',
    messagingSenderId: '766475877975',
    projectId: 'livestream-webrtc',
    authDomain: 'livestream-webrtc.firebaseapp.com',
    storageBucket: 'livestream-webrtc.firebasestorage.app',
    measurementId: 'G-78B4QV115D',
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyAh3Tp3NXekJu_Ok34ewlDbE29R_PSb8ds',
    appId: '1:766475877975:android:0b3b379291595f52ad2d12',
    messagingSenderId: '766475877975',
    projectId: 'livestream-webrtc',
    storageBucket: 'livestream-webrtc.firebasestorage.app',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyCaYyZUsiuZOQDk-jnwn4l5hqgilY8rIpk',
    appId: '1:766475877975:ios:d66fe6927961b2f2ad2d12',
    messagingSenderId: '766475877975',
    projectId: 'livestream-webrtc',
    storageBucket: 'livestream-webrtc.firebasestorage.app',
    iosBundleId: 'com.example.livestreamWebrtc',
  );

  static const FirebaseOptions macos = FirebaseOptions(
    apiKey: 'AIzaSyCaYyZUsiuZOQDk-jnwn4l5hqgilY8rIpk',
    appId: '1:766475877975:ios:d66fe6927961b2f2ad2d12',
    messagingSenderId: '766475877975',
    projectId: 'livestream-webrtc',
    storageBucket: 'livestream-webrtc.firebasestorage.app',
    iosBundleId: 'com.example.livestreamWebrtc',
  );

  static const FirebaseOptions windows = FirebaseOptions(
    apiKey: 'AIzaSyAOt89kwMu_E44Dyei4jK-fEABpSFMthgA',
    appId: '1:766475877975:web:6f62af84849efba4ad2d12',
    messagingSenderId: '766475877975',
    projectId: 'livestream-webrtc',
    authDomain: 'livestream-webrtc.firebaseapp.com',
    storageBucket: 'livestream-webrtc.firebasestorage.app',
    measurementId: 'G-RPSP008X3G',
  );
}
