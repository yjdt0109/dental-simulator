import 'dart:typed_data';

/// 🖼 자동 QA·보관함의 결과를 시뮬레이터 메인 화면(원본 · After)으로 가져오기
///   시뮬레이터가 열려 있을 때 [handler] 를 등록해 둠. 결과 문구를 돌려줌.
typedef SimImportFn = Future<String> Function({
  required Uint8List original,
  required Uint8List result,
  required String tag,
  String name,
  List<String> treatments,
});

class SimImport {
  static SimImportFn? handler;

  static Future<String> run({
    required Uint8List original,
    required Uint8List result,
    required String tag,
    String name = '',
    List<String> treatments = const [],
  }) async {
    final h = handler;
    if (h == null) return '시뮬레이터 화면이 열려 있지 않아 가져올 수 없습니다.';
    return h(
      original: original,
      result: result,
      tag: tag,
      name: name,
      treatments: treatments,
    );
  }
}

/// 🗂 환자 기록 → 시뮬레이터로 다시 불러오기 (원본 · 결과들 · 상담 내용 · 미소 사진)
class LoadedCase {
  const LoadedCase({
    required this.before,
    required this.results,
    this.name = '',
    this.treatments = const [],
    this.teeth = const [],
    this.shade,
    this.memo = '',
    this.photoType = '',
    this.smile,
    this.smileAfter,
    this.smileFrom = '',
    this.recordId,
  });
  final String? recordId; // 불러온 기록 (미소 사진을 그 폴더에 저장)
  final Uint8List before;
  final List<({Uint8List bytes, String engine, String check})> results;
  final String name;
  final List<String> treatments;
  final List<int> teeth;
  final String? shade;
  final String memo;
  final String photoType;
  final Uint8List? smile, smileAfter;
  final String smileFrom;
}

typedef CaseLoadFn = Future<String> Function(LoadedCase c, {bool openSmile});

class CaseLoader {
  static CaseLoadFn? handler;

  static Future<String> run(LoadedCase c, {bool openSmile = false}) async {
    final h = handler;
    if (h == null) return '시뮬레이터 화면이 열려 있지 않아 불러올 수 없습니다.';
    return h(c, openSmile: openSmile);
  }
}

/// 🗂 환자 기록의 사진을 한 장씩 시뮬레이터로 (원본 · N번 결과 · 미소 사진 · 미소 미리보기)
///   [file]: 기록 폴더 안 파일 이름 (before.jpg, after_1.jpg, smile_before.jpg, smile_after.jpg)
typedef RecordPhotoFn = Future<String> Function(String recordId, String file);

class RecordPhotoLoader {
  static RecordPhotoFn? handler;

  static Future<String> run(String recordId, String file) async {
    final h = handler;
    if (h == null) return '시뮬레이터 화면이 열려 있지 않아 불러올 수 없습니다.';
    return h(recordId, file);
  }
}
