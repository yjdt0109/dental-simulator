import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

/// Firebase 프로젝트(ai-yejundetallab) 연결 정보.
/// 앱이 어느 프로젝트에 연결되는지 알려주는 "주소표"이며 비밀번호가 아닙니다.
/// 실제 보안은 Realtime Database 보안 규칙이 담당합니다.
const kDatabaseUrl =
    'https://ai-yejundetallab-default-rtdb.asia-southeast1.firebasedatabase.app';

const _android = FirebaseOptions(
  apiKey: 'AIzaSyBSBNMGzGSoF9NuX9CIWvuKaquvW5JI6co',
  appId: '1:572066074232:android:dee75db2deebb5a6aba78d',
  messagingSenderId: '572066074232',
  projectId: 'ai-yejundetallab',
  databaseURL: kDatabaseUrl,
  storageBucket: 'ai-yejundetallab.firebasestorage.app',
);

const _web = FirebaseOptions(
  apiKey: 'AIzaSyBk4rSohjlS0WwfpCeczRgGI9TJyAnmiz4',
  appId: '1:572066074232:web:0f5730d8cb780c65aba78d',
  messagingSenderId: '572066074232',
  projectId: 'ai-yejundetallab',
  authDomain: 'ai-yejundetallab.firebaseapp.com',
  databaseURL: kDatabaseUrl,
  storageBucket: 'ai-yejundetallab.firebasestorage.app',
);

/// 지원 플랫폼(안드로이드·웹)이 아니면 null → 큰 화면 연결 기능만 꺼지고 앱은 정상 동작
FirebaseOptions? get currentFirebaseOptions {
  if (kIsWeb) return _web;
  if (defaultTargetPlatform == TargetPlatform.android) return _android;
  return null;
}

/// 앱 시작 시 한 번. 실패해도 앱은 계속 동작(큰 화면 연결만 비활성).
Future<bool> initFirebase() async {
  final options = currentFirebaseOptions;
  if (options == null) return false;
  try {
    if (Firebase.apps.isEmpty) await Firebase.initializeApp(options: options);
    return true;
  } catch (e) {
    debugPrint('Firebase 초기화 실패: $e');
    return false;
  }
}
