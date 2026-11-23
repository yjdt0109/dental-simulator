import 'dart:convert';
import 'dart:typed_data';

import 'package:dental_app/ai/smile_match.dart';
import 'package:dental_app/app_theme.dart';
import 'package:dental_app/cast/cast_service.dart';
import 'package:dental_app/models/clinic_profile.dart';
import 'package:dental_app/simulator/compare_viewer.dart';
import 'package:dental_app/simulator/simulator_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

const _profile = ClinicProfile(
  clinicName: '미소드림치과',
  bizNo: '-',
  phone: '-',
  zipCode: '-',
  address: '-',
  role: '원장',
  provider: null,
);

Uint8List jpg(int r) => Uint8List.fromList(
  img.encodeJpg(
    img.Image(width: 120, height: 90)..clear(img.ColorRgb8(r, 90, 90)),
  ),
);

Future<void> _settle(WidgetTester t, {bool Function()? until}) async {
  for (var i = 0; i < 30; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await t.pump(const Duration(milliseconds: 500));
    if (until == null ? i >= 4 : until()) return;
  }
}

void main() {
  testWidgets('😊 원본 2장: 개구기 사진 변환 → 미소 사진에 자동 매칭 → 최종 미소 결과', (t) async {
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final smile = jpg(150), finalSmile = jpg(250);
    Uint8List? gotSmile, gotProsth;
    debugMatchOverride = (s, pr, step) async {
      gotSmile = s;
      gotProsth = pr;
      step('① 📍 정렬 중…');
      return MatchResult(
        align: AlignOut(
          alignedTeeth: Uint8List(0),
          mask: Uint8List(0),
          crop: Uint8List(0),
          residual: 0.004,
          eyes: true,
          scale: 1.0,
          degrees: 0.3,
        ),
        composite: jpg(10),
        stage1: jpg(20),
        finalImage: finalSmile,
      );
    };
    addTearDown(() => debugMatchOverride = null);
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: const SimulatorHomeScreen(profile: _profile),
      ),
    );
    await _settle(t, until: () => find.byType(RoiEditor).evaluate().isNotEmpty);
    // 미소 사진이 없으면 안내 + [미소 사진 넣기]
    expect(find.text('😊 미소 사진 넣기'), findsOneWidget);
    final send = CastService.instance.onRemoteCmd!;
    await t.runAsync(() async {
      send({'t': 'smilePhoto', 'v': base64Encode(smile)}); // 원본 2: 미소 사진
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await _settle(t);
    expect(find.textContaining('변환 후 미소 사진에 자동으로 맞추기'), findsOneWidget);
    send({'t': 'clearTeeth'});
    send({
      't': 'group',
      'v': [13, 12, 11, 21, 22, 23],
    });
    send({'t': 'tx', 'v': '미백'});
    send({'t': 'shade', 'v': 'B1'});
    await t.pump();
    send({'t': 'convert'}); // 원본 1: 개구기 사진 변환
    await _settle(
      t,
      until: () =>
          gotProsth != null && find.text('미소 미리보기').evaluate().isNotEmpty,
    );
    expect(gotSmile, isNotNull);
    expect(gotProsth, isNotNull); // 변환 결과(2번 단계)를 미소에 맞춤
    // 최종: 미소 ↔ 미소 미리보기 비교 화면
    expect(find.text('미소 미리보기'), findsWidgets);
    expect(t.takeException(), isNull);
  });

  testWidgets('PC 에서 자동 매칭 끄면 변환만', (t) async {
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    var called = false;
    debugMatchOverride = (s, pr, step) async {
      called = true;
      throw Exception('x');
    };
    addTearDown(() => debugMatchOverride = null);
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: const SimulatorHomeScreen(profile: _profile),
      ),
    );
    await _settle(t, until: () => find.byType(RoiEditor).evaluate().isNotEmpty);
    final send = CastService.instance.onRemoteCmd!;
    await t.runAsync(() async {
      send({'t': 'smilePhoto', 'v': base64Encode(jpg(150))});
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await _settle(t);
    send({'t': 'autoMatch', 'v': false});
    send({'t': 'clearTeeth'});
    send({
      't': 'group',
      'v': [11, 21],
    });
    send({'t': 'tx', 'v': '미백'});
    send({'t': 'shade', 'v': 'B1'});
    await t.pump();
    send({'t': 'convert'});
    await _settle(
      t,
      until: () => find.byType(StackedCompare).evaluate().isNotEmpty,
    );
    await _settle(t);
    expect(called, isFalse);
    expect(t.takeException(), isNull);
  });
}
