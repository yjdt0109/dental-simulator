import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import 'tooth_library.dart';

// -----------------------------------------------------------------------------
// 📁 내 라이브러리 (실제 치아 사진 / STL 정면 렌더링 PNG)
//   태블릿 안 [앱 문서]/tooth_library/<이름>/<치아번호>.png 로 저장.
//   PNG 는 배경이 투명해야 함 (치아 모양 그대로 오려 낸 것). 파일 이름에 치아 번호(11·12·13·21·22·23)를 넣으면
//   그 번호로, 없으면 고른 차례대로 13 12 11 21 22 23 (3장이면 11 12 13 → 반대쪽은 뒤집어 씀).
// -----------------------------------------------------------------------------

const kLibOrder6 = [13, 12, 11, 21, 22, 23];
const kLibOrder3 = [11, 12, 13];

/// 파일 이름에서 치아 번호 찾기 (예: '11.png', 'UR1_11.png', 'tooth-23.png')
int? fdiFromName(String name) {
  final m = RegExp(r'(?<!\d)(1[123]|2[123])(?!\d)').firstMatch(name);
  return m == null ? null : int.parse(m.group(1)!);
}

/// 받은 파일들 → 치아 번호별 PNG (투명 배경을 치아에 딱 맞게 자름). 투명 배경이 없으면 오류
Map<int, Uint8List> prepareLibraryPngs(List<(String, Uint8List)> files) {
  final named = <int, Uint8List>{};
  final rest = <Uint8List>[];
  for (final (name, bytes) in files) {
    final f = fdiFromName(name);
    if (f != null && !named.containsKey(f)) {
      named[f] = bytes;
    } else {
      rest.add(bytes);
    }
  }
  if (named.isEmpty) {
    final order = rest.length <= 3 ? kLibOrder3 : kLibOrder6;
    for (var i = 0; i < rest.length && i < order.length; i++) {
      named[order[i]] = rest[i];
    }
  }
  final out = <int, Uint8List>{};
  for (final e in named.entries) {
    final im = img.decodeImage(e.value);
    if (im == null) throw StateError('${e.key}번 사진을 읽지 못했습니다');
    if (!im.hasAlpha) {
      throw StateError('${e.key}번 사진에 투명 배경이 없어요 (배경을 지운 PNG 가 필요해요)');
    }
    // 투명하지 않은 곳만 남기기
    var x0 = im.width, y0 = im.height, x1 = -1, y1 = -1;
    for (final p in im) {
      if (p.a > 20) {
        if (p.x < x0) x0 = p.x;
        if (p.y < y0) y0 = p.y;
        if (p.x > x1) x1 = p.x;
        if (p.y > y1) y1 = p.y;
      }
    }
    if (x1 < x0) throw StateError('${e.key}번 사진이 모두 투명해요');
    var c = img.copyCrop(
      im,
      x: x0,
      y: y0,
      width: x1 - x0 + 1,
      height: y1 - y0 + 1,
    );
    if (c.width > 900) {
      c = img.copyResize(c, width: 900, interpolation: img.Interpolation.cubic);
    }
    out[e.key] = img.encodePng(c);
  }
  return out;
}

class CustomLibraryStore {
  /// 테스트용 저장 폴더 (null 이면 앱 문서 폴더)
  static Directory? debugDir;

  static Future<Directory> _root() async {
    final base = debugDir ?? await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/tooth_library');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  static Future<List<String>> names() async {
    try {
      final r = await _root();
      return [
        for (final d in r.listSync().whereType<Directory>())
          d.uri.pathSegments.where((s) => s.isNotEmpty).last,
      ]..sort();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> save(String name, Map<int, Uint8List> pngs) async {
    final r = await _root();
    final d = Directory('${r.path}/$name');
    if (d.existsSync()) d.deleteSync(recursive: true);
    d.createSync(recursive: true);
    for (final e in pngs.entries) {
      await File('${d.path}/${e.key}.png').writeAsBytes(e.value, flush: true);
    }
  }

  static Future<void> delete(String name) async {
    final r = await _root();
    final d = Directory('${r.path}/$name');
    if (d.existsSync()) d.deleteSync(recursive: true);
  }

  static Future<CustomLibrary?> load(String name) async {
    final r = await _root();
    final d = Directory('${r.path}/$name');
    if (!d.existsSync()) return null;
    final images = <int, ui.Image>{};
    for (final f in d.listSync().whereType<File>()) {
      final fdi = fdiFromName(f.uri.pathSegments.last);
      if (fdi == null) continue;
      final codec = await ui.instantiateImageCodec(await f.readAsBytes());
      images[fdi] = (await codec.getNextFrame()).image;
    }
    return images.isEmpty ? null : CustomLibrary(name, images);
  }

  /// 파일들 → 정리해서 저장. 저장된 치아 번호들을 돌려줌
  static Future<List<int>> import(
    String name,
    List<(String, Uint8List)> files,
  ) async {
    final pngs = await compute(prepareLibraryPngs, files);
    await save(name, pngs);
    return pngs.keys.toList()..sort();
  }
}
