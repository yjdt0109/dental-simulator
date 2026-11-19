// Before & After 치과 시뮬레이터 — 1단계 안드로이드 앱 (PC·웹 빌드도 같은 코드)
import 'package:flutter/material.dart';

import 'ai/ai_service.dart';
import 'ai/pipeline.dart';
import 'qa/archive.dart';
import 'qa/qa_agent.dart';
import 'qa/qa_session.dart';
import 'records/records.dart';
import 'app_theme.dart';
import 'cast/firebase_config.dart';
import 'screens/login_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initFirebase(); // 실패해도 앱은 동작 (큰 화면 연결만 비활성)
  await AiService.instance.init(); // 나노바나나 AI (App Check)
  await PipelineSettings.instance.load(); // 2단계 파이프라인 설정·API 키
  await TreatmentDefaults.instance.load(); // 보관함에서 정한 치료별 기본값
  await QaSettings.load(); // 자동 QA 채점 모델
  await QaSession.instance.loadPass(); // 자동 QA 목표 점수
  await PatientRecords.instance.load(); // 🗂 환자 기록
  runApp(const DentalApp());
}

class DentalApp extends StatelessWidget {
  const DentalApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Before & After 치과 시뮬레이터',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const LoginScreen(),
    );
  }
}
