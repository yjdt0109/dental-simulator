import 'package:dental_app/app_theme.dart';
import 'package:dental_app/simulator/compare_viewer.dart';
import 'package:dental_app/simulator/sim_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  for (final size in const [Size(390, 844), Size(1280, 900)]) {
    testWidgets('🪄 자동 선택: 탭 → 좌표 전달 · 더하기/빼기 획 · 기준점 끌기 · 취소/초기화 $size', (
      t,
    ) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final photo = img.encodePng(
        img.Image(width: 400, height: 300)..clear(img.ColorRgb8(200, 100, 100)),
      );
      final taps = <Offset>[];
      final strokes = <MaskStroke>[];
      final moved = <(int, bool, Offset)>[];
      var undo = 0, clear = 0;
      var marks = [
        (
          label: '#11',
          zenith: const Offset(0.45, 0.33),
          incisal: const Offset(0.45, 0.66),
        ),
      ];
      late StateSetter set;
      await t.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (c, s) {
                set = s;
                return SizedBox(
                  width: size.width,
                  height: 500,
                  child: RoiEditor(
                    bytes: photo,
                    imageSize: const Size(400, 300),
                    roi: kDefaultRoi,
                    onChanged: (_) {},
                    showRoi: false,
                    onSamTap: taps.add,
                    samCount: 1,
                    onSamUndo: () => undo++,
                    onSamClear: () => clear++,
                    onSamBrush: strokes.add,
                    samMarks: marks,
                    onSamMark: (i, inc, p) {
                      moved.add((i, inc, p));
                      set(
                        () => marks = [
                          (label: '#11', zenith: marks[0].zenith, incisal: p),
                        ],
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ),
      );
      final rect = t.getRect(find.byType(RoiEditor));
      // 사진(400x300)은 칸에 맞춰 가운데 → 가운데 탭 = 사진 (0.5, 0.5)
      await t.tap(
        find.byTooltip(
          '🪄 탭 한 번 자동 선택 (SAM) — 치아를 탭하면 윤곽을 자동으로 찾아요 (다시 탭하면 빠짐)',
        ),
      );
      await t.pump();
      await t.tapAt(rect.center);
      await t.pump();
      expect(taps.single.dx, closeTo(0.5, 0.02));
      expect(taps.single.dy, closeTo(0.5, 0.02));
      // 더하기 획
      await t.tap(find.byTooltip('선택 다듬기: 손으로 칠해 선택 영역 더하기'));
      await t.pump();
      await t.dragFrom(rect.center, const Offset(30, 0));
      await t.pump();
      expect(strokes.single.erase, isFalse);
      expect(strokes.single.pts.length, greaterThan(1));
      await t.tap(find.byTooltip('선택 다듬기: 손으로 문질러 선택 영역 빼기'));
      await t.pump();
      await t.dragFrom(rect.center, const Offset(0, 20));
      await t.pump();
      expect(strokes.last.erase, isTrue);
      // 기준점 끌기 (절단끝 0.66 → 아래로)
      await t.tap(find.byTooltip('📍 치아별 기준점(잇몸 꼭대기·절단끝) 옮기기'));
      await t.pump();
      final fit = applyBoxFit(
        BoxFit.contain,
        const Size(400, 300),
        rect.size,
      ).destination;
      final dest = Alignment.center.inscribe(fit, rect);
      final inc = Offset(
        dest.left + 0.45 * dest.width,
        dest.top + 0.66 * dest.height,
      );
      await t.dragFrom(inc, const Offset(0, 20));
      await t.pump();
      expect(moved, isNotEmpty);
      expect(moved.last.$2, isTrue);
      expect(moved.last.$3.dy, greaterThan(0.66));
      await t.tap(find.byTooltip('마지막 선택 취소'));
      await t.tap(find.byTooltip('선택 초기화'));
      expect(undo, 1);
      expect(clear, 1);
      expect(t.takeException(), isNull);
    });
  }
}
