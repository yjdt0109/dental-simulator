import 'dart:async';

import 'package:dental_app/simulator/simulator_screen.dart';

/// 모든 테스트 전에: 기존 테스트는 예전 화면 기준 (새 단계 화면 테스트는 직접 끔)
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  debugStepFlowOff = true;
  debugSamplePhotos = true; // 테스트는 예시 사진 3명으로
  await testMain();
}
