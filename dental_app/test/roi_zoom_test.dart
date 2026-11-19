import 'dart:typed_data';

import 'package:dental_app/simulator/compare_viewer.dart';
import 'package:dental_app/simulator/line_tools.dart';
import 'package:dental_app/simulator/sim_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  testWidgets('치아 영역 화면: 확대 버튼 + 확대 상태에서 영역 이동', (t) async {
    final png = Uint8List.fromList(
      img.encodePng(img.Image(width: 400, height: 600)),
    );
    var roi = const Rect.fromLTWH(0.3, 0.6, 0.4, 0.2);
    var lines = <GuideLine>[];
    final history = <List<GuideLine>>[];
    void edit(void Function(void Function()) set, List<GuideLine> next) =>
        set(() {
          history.add(lines);
          lines = next;
        });
    await t.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (c, set) => Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 400,
              height: 600,
              child: RoiEditor(
                bytes: png,
                imageSize: const Size(400, 600),
                roi: roi,
                onChanged: (r) => set(() => roi = r),
                lines: lines,
                onLineAdd: (l) => edit(set, [...lines, l]),
                onLineErase: (path, r) =>
                    edit(set, LineTools.erase(lines, path, r, 1.5)),
                onLineUndo: history.isEmpty
                    ? null
                    : () => set(() => lines = history.removeLast()),
                onLineClear: () => edit(set, []),
                onLineSmooth: () => edit(set, LineTools.smooth(lines, 1.5)),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.textContaining('점선 영역을 끌어'), findsNothing); // 사진 위 안내문 제거됨
    await t.tap(find.byTooltip('영역'));
    await t.pump();
    await t.tap(find.byTooltip('확대'));
    await t.pump();
    await t.tap(find.byTooltip('확대'));
    await t.pump();
    expect(find.text('2.3배'), findsOneWidget);
    // 확대 상태에서 '치아 영역'을 끌면 사진 기준으로는 더 작게 움직여야 함 (정밀 조정)
    final before = roi.left;
    await t.drag(find.text('치아 영역'), const Offset(45, 0));
    await t.pump();
    final moved = roi.left - before;
    expect(moved, greaterThan(0));
    expect(moved, lessThan(45 / 400)); // 1배였다면 0.1125
    await t.tap(find.byTooltip('원래 크기'));
    await t.pump();
    expect(find.textContaining('배'), findsNothing);

    // 서비컬 라인: 상악선/하악선 그리기, 영역(점선)은 움직이지 않음
    final roiBefore = roi;
    await t.tap(find.byTooltip('상악선'));
    await t.pump();
    await t.dragFrom(const Offset(120, 300), const Offset(150, 10));
    await t.pump();
    await t.tap(find.byTooltip('하악선'));
    await t.pump();
    await t.dragFrom(const Offset(120, 380), const Offset(150, -10));
    await t.pump();
    expect(lines, hasLength(2));
    expect(lines[0].upper, isTrue);
    expect(lines[1].upper, isFalse);
    expect(lines[0].pts.length, greaterThan(1));
    expect(roi, roiBefore);
    // 지우개: 상악선 가운데를 세로로 문지르면 그 부분만 지워져 상악선이 두 개로, 하악선은 그대로
    await t.tap(find.byTooltip('지우개'));
    await t.pump();
    await t.dragFrom(const Offset(195, 280), const Offset(0, 40));
    await t.pump();
    expect(lines.where((l) => l.upper), hasLength(2));
    expect(lines.where((l) => !l.upper), hasLength(1));
    // 되돌리기 → 지우기 전으로 (상악선 1개)
    await t.tap(find.byTooltip('되돌리기'));
    await t.pump();
    expect(lines.where((l) => l.upper), hasLength(1));
    // 선 다듬기 → 2줄 그대로, 되돌리기 가능
    await t.tap(find.byTooltip('선 다듬기'));
    await t.pump();
    expect(lines, hasLength(2));
    await t.tap(find.byTooltip('모두 지움'));
    await t.pump();
    expect(lines, isEmpty);
    // 모두 지움도 되돌리기로 복구
    await t.tap(find.byTooltip('되돌리기'));
    await t.pump();
    expect(lines, hasLength(2));
  });
}
