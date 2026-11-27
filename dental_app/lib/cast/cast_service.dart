import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_config.dart';

/// 상담실 큰 화면(PC 모니터) 연결.
///
/// 데이터 구조 (Realtime Database)
///   codes/{4자리}          : { room, uid, exp }   ← PC가 띄우는 숫자 코드 → 방 번호 (10분 유효)
///   rooms/{방 번호}/monitor : { name, online }     ← PC 상태 ("상담실 1")
///   rooms/{방 번호}/tablet  : { online }           ← 태블릿 상태
///   rooms/{방 번호}/state   : 화면 상태(브리핑 여부, 손잡이 위치, 이름·셰이드 등)
///   rooms/{방 번호}/images  : 지금 보고 있는 Before 사진(+ 만들었으면 After). 압축 JPEG.
///                             연결이 끊기면 자동 삭제.
///   rooms/{방 번호}/cmds    : PC → 태블릿 조작 명령 (치아 선택, 셰이드, 변환하기 등). 처리하면 삭제.
/// 방 번호는 PC가 만든 추측 불가능한 20자 이상 무작위 문자열(QR에 들어 있음).
class CastService extends ChangeNotifier {
  CastService._();
  static final CastService instance = CastService._();

  /// 앱 버전 (PC 상담 모니터에 표시 → 태블릿이 최신 앱인지 확인용)
  static const appVersion = '2026.11.27-e';

  /// PC 에서 받은 명령 수 (PC 가 '태블릿이 받았는지' 확인하는 데 씀)
  int cmdCount = 0;

  static const _prefRoom = 'cast.room';
  static const _prefName = 'cast.name';

  bool available = false; // Firebase 사용 가능 여부
  bool busy = false;
  String? error;
  String? roomId;
  String? monitorName;
  bool monitorOnline = false;

  FirebaseDatabase? _db;
  StreamSubscription<DatabaseEvent>? _monitorSub;
  StreamSubscription<DatabaseEvent>? _controlSub;
  StreamSubscription<DatabaseEvent>? _cmdSub;
  StreamSubscription<DatabaseEvent>? _netSub;
  bool _everOnline = false;
  final Set<String> _doneCmds = {}; // 처리한 PC 명령 (같은 명령을 두 번 처리하지 않게)
  (String, Uint8List, Uint8List?, List<Uint8List>)? _lastImages;
  Timer? _monitorGone;

  /// PC 에서 마우스로 조작한 명령 ({t: 종류, ...})
  void Function(Map<String, Object?> cmd)? onRemoteCmd;

  /// PC 에서 마우스·키보드로 손잡이를 움직였을 때 (0~1)
  void Function(double pos)? onRemotePos;

  /// PC 의 상담 메모 칸에 입력했을 때
  void Function(String memo)? onRemoteMemo;

  /// PC 에서 [환자 브리핑 모드]를 켜고 끌 때
  void Function(bool on)? onRemoteBriefing;
  num _lastPosAt = 0, _lastMemoAt = 0, _lastBriefingAt = 0;
  bool _controlPrimed = false;
  bool _initStarted = false;

  bool get connected => roomId != null;

  /// QR 내용(…#pair-방번호)에서 방 번호만 꺼냄
  static String? roomFromQr(String raw) =>
      RegExp(r'pair-([A-Za-z0-9_-]{20,64})').firstMatch(raw)?.group(1);

  /// 앱 시작 후 한 번: 익명 로그인만. 자동 연결은 하지 않음 (QR·숫자로 연결할 때만 연결)
  Future<void> init() async {
    if (_initStarted) return;
    _initStarted = true;
    try {
      if (Firebase.apps.isEmpty) return;
      _db = FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL: kDatabaseUrl,
      );
      if (FirebaseAuth.instance.currentUser == null) {
        await FirebaseAuth.instance.signInAnonymously();
      }
      available = true;
      // 예전 버전이 저장해 둔 자동 연결 정보는 지움
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefRoom);
      await prefs.remove(_prefName);
      notifyListeners();
    } catch (e) {
      available = false;
      error = '큰 화면 서버에 연결하지 못했습니다. 인터넷 연결을 확인해 주세요.';
      debugPrint('CastService.init: $e');
      notifyListeners();
    }
  }

  /// PC 화면의 숫자 4자리로 연결
  Future<bool> connectCode(String code) async {
    final db = _db;
    if (db == null) return false;
    _setBusy(true);
    try {
      final snap = await db.ref('codes/$code').get();
      final v = snap.value;
      if (v is! Map || v['room'] is! String) {
        error = '코드 $code 를 찾을 수 없습니다. PC 화면의 숫자를 다시 확인해 주세요.';
        return false;
      }
      final exp = v['exp'];
      if (exp is num && exp < DateTime.now().millisecondsSinceEpoch) {
        error = '코드가 만료되었습니다. PC 화면에 새로 나온 숫자를 입력해 주세요.';
        return false;
      }
      return await connectRoom(v['room'] as String);
    } catch (e) {
      error = '연결하지 못했습니다. 인터넷 연결을 확인해 주세요.';
      return false;
    } finally {
      _setBusy(false);
    }
  }

  /// 방 번호로 연결 (QR 스캔 또는 숫자 입력)
  Future<bool> connectRoom(String room) async {
    final db = _db;
    if (db == null || room.length < 20) return false;
    if (roomId == room) return true;
    await disconnect();
    try {
      final r = db.ref('rooms/$room');
      await r.child('tablet').update({
        'online': true,
        'at': ServerValue.timestamp,
      });
      await r.child('tablet').onDisconnect().update({'online': false});
      await r.child('images').onDisconnect().remove(); // 끊기면 사진 자동 삭제
      roomId = room;
      error = null;
      // 인터넷이 잠깐 끊겼다 돌아오면 같은 연결을 다시 '온라인'으로 (앱을 껐다 켜면 연결 안 함)
      _netSub = db.ref('.info/connected').onValue.listen((e) {
        if (e.snapshot.value == true && roomId == room) {
          r
              .child('tablet')
              .update({'online': true, 'at': ServerValue.timestamp})
              .catchError((_) {});
          r
              .child('tablet')
              .onDisconnect()
              .update({'online': false})
              .catchError((_) {});
          // 끊긴 사이 서버가 사진을 지웠으므로 다시 보냄 (와이파이가 잠깐 끊겼다 돌아온 경우)
          r.child('images').onDisconnect().remove().catchError((_) {});
          final last = _lastImages;
          if (_everOnline && last != null) {
            _imgKey = null;
            sendImages(last.$1, last.$2, last.$3, thumbs: last.$4);
            _flush(force: true);
          }
          _everOnline = true;
        }
      });
      _monitorSub = r.child('monitor').onValue.listen((e) {
        final v = e.snapshot.value;
        final wasOnline = monitorOnline;
        if (v is Map) {
          monitorName = (v['name'] ?? '상담실 모니터').toString();
          monitorOnline = v['online'] == true;
        } else {
          monitorOnline = false;
        }
        if (monitorOnline) {
          _monitorGone?.cancel();
          _monitorGone = null;
        } else if (wasOnline || _monitorGone == null) {
          // PC 상담 모니터를 닫거나 새로고침하면(새 QR) 60초 뒤 연결 해제 (와이파이가 잠깐 끊긴 건 그대로 유지) → 다시 QR 로 연결
          _monitorGone?.cancel();
          _monitorGone = Timer(const Duration(seconds: 60), () {
            if (roomId == room && !monitorOnline) disconnect();
          });
        }
        if (monitorOnline && !wasOnline) {
          _flush(force: true); // PC가 다시 켜지면 현재 화면 다시 보냄 (사진은 서버에 남아 있음)
        }
        notifyListeners();
      });
      // PC → 태블릿: 손잡이 위치, 상담 메모 (연결 전부터 있던 값은 무시)
      _controlPrimed = false;
      _controlSub = r.child('control').onValue.listen((e) {
        final v = e.snapshot.value;
        if (v is! Map) {
          _controlPrimed = true;
          return;
        }
        final posAt = v['posAt'] is num ? v['posAt'] as num : 0;
        final memoAt = v['memoAt'] is num ? v['memoAt'] as num : 0;
        final briefingAt = v['briefingAt'] is num ? v['briefingAt'] as num : 0;
        if (!_controlPrimed) {
          _controlPrimed = true;
          _lastPosAt = posAt;
          _lastMemoAt = memoAt;
          _lastBriefingAt = briefingAt;
          return;
        }
        if (briefingAt > _lastBriefingAt && v['briefing'] is bool) {
          _lastBriefingAt = briefingAt;
          onRemoteBriefing?.call(v['briefing'] as bool);
        }
        if (posAt > _lastPosAt && v['pos'] is num) {
          _lastPosAt = posAt;
          onRemotePos?.call((v['pos'] as num).toDouble().clamp(0.0, 1.0));
        }
        if (memoAt > _lastMemoAt && v['memo'] is String) {
          _lastMemoAt = memoAt;
          onRemoteMemo?.call(v['memo'] as String);
        }
      });
      // PC → 태블릿 조작 명령: 연결 전에 쌓인 것은 버리고, 새로 온 것만 처리 후 삭제
      await r.child('cmds').remove();
      // 명령 목록 전체를 받아 아직 처리 안 한 것을 순서대로 모두 처리
      // (PC 에서 빠르게 여러 번 눌러 거의 동시에 온 명령도 빠짐없이)
      _doneCmds.clear();
      _cmdSub = r.child('cmds').onValue.listen((e) {
        final all = e.snapshot.value;
        if (all is! Map) return;
        final keys = [for (final k in all.keys) k.toString()]..sort();
        for (final k in keys) {
          if (!_doneCmds.add(k)) continue; // 이미 처리함
          r.child('cmds/$k').remove().catchError((_) {});
          final v = all[k];
          if (v is! Map) continue;
          cmdCount++;
          try {
            onRemoteCmd?.call(v.map((k, x) => MapEntry(k.toString(), x)));
          } catch (err) {
            debugPrint('remote cmd: $err');
          }
        }
        if (_doneCmds.length > 400) {
          final keep = _doneCmds.toList()..sort();
          _doneCmds
            ..clear()
            ..addAll(keep.sublist(keep.length - 200));
        }
      });
      notifyListeners();
      _flush(force: true);
      return true;
    } catch (e) {
      roomId = null;
      error = '연결하지 못했습니다. 잠시 후 다시 시도해 주세요.';
      notifyListeners();
      return false;
    }
  }

  /// 연결 해제.
  Future<void> disconnect() async {
    await _monitorSub?.cancel();
    _monitorSub = null;
    await _controlSub?.cancel();
    _controlSub = null;
    await _cmdSub?.cancel();
    _cmdSub = null;
    await _netSub?.cancel();
    _netSub = null;
    _monitorGone?.cancel();
    _monitorGone = null;
    _everOnline = false;
    _lastImages = null;
    final room = roomId, db = _db;
    roomId = null;
    monitorOnline = false;
    _imgKey = null;
    if (room != null && db != null) {
      final r = db.ref('rooms/$room');
      try {
        await r.child('images').remove();
        for (final k in sharedPaths) {
          await r.child(k).remove();
        }
        await r.child('state').remove();
        await r.child('tablet').update({'online': false});
        await r.child('tablet').onDisconnect().cancel();
        await r.child('images').onDisconnect().cancel();
      } catch (_) {}
    }
    monitorName = null;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 화면 상태 보내기 (손잡이 위치 등은 자주 바뀌므로 0.12초마다 묶어서 보냄)
  // ---------------------------------------------------------------------------
  Map<String, Object?>? _pending;
  String? _lastSent;
  Timer? _timer;

  void sendState(Map<String, Object?> state) {
    if (!connected) return;
    _pending = state;
    _timer ??= Timer(const Duration(milliseconds: 120), () {
      _timer = null;
      _flush();
    });
  }

  void _flush({bool force = false}) {
    final room = roomId, db = _db, s = _pending;
    if (room == null || db == null || s == null) return;
    final key = jsonEncode(s);
    if (!force && key == _lastSent) return;
    _lastSent = key;
    db
        .ref('rooms/$room/state')
        .set({...s, 'at': ServerValue.timestamp})
        .catchError((_) {});
  }

  // ---------------------------------------------------------------------------
  // 지금 보고 있는 사진 보내기 (압축 JPEG, 긴 변 1280px)
  // ---------------------------------------------------------------------------
  String? _imgKey;
  int imgVer = 0;

  /// [before]·[after]: 화면에 보일 두 장 (비교 목록에서 고른 것). [thumbs]: 원본 + 변환 결과 작은 사진
  Future<void> sendImages(
    String key,
    Uint8List before,
    Uint8List? after, {
    List<Uint8List> thumbs = const [],
  }) async {
    final room = roomId, db = _db;
    if (room == null || db == null || key == _imgKey) return;
    _imgKey = key;
    _lastImages = (key, before, after, thumbs);
    final ver = ++imgVer;
    try {
      final b = await jpegBase64(before);
      final a = after == null ? null : await jpegBase64(after);
      final th = [
        for (final t in thumbs) await jpegBase64(t, maxSide: 220, quality: 70),
      ];
      if (_imgKey != key || roomId != room) return; // 그 사이 바뀜
      await db.ref('rooms/$room/images').set({
        'ver': ver,
        'before': b,
        'after': ?a,
        if (th.isNotEmpty) 'thumbs': th,
      });
    } catch (e) {
      debugPrint('sendImages: $e');
      if (_imgKey == key) _imgKey = null; // 다음 화면 갱신 때 다시 시도
    }
  }

  static const sharedPaths = [
    'qa',
    'qaImg',
    'archive',
    'archiveFull',
    'archiveMsg',
    'records',
    'recordFull',
    'samOv',
    'rzImg',
    'smileImg',
    'recSync',
    'slotImg',
  ];

  /// rooms/{방}/[path] 에 값 쓰기 (자동 QA·보관함을 PC 에 보여 줄 때). null 이면 지움.
  Future<void> put(String path, Object? value) async {
    final room = roomId, db = _db;
    if (room == null || db == null) return;
    try {
      final r = db.ref('rooms/$room/$path');
      await r.set(value);
      // 사진이 들어 있으므로 태블릿 연결이 끊기면 자동 삭제
      if (value != null) {
        await r.onDisconnect().remove();
      }
    } catch (e) {
      debugPrint('put $path: $e');
    }
  }

  Future<void> clearImages() async {
    if (_imgKey == null) return;
    _imgKey = null;
    final room = roomId, db = _db;
    if (room == null || db == null) return;
    try {
      await db.ref('rooms/$room/images').remove();
    } catch (_) {}
  }

  void _setBusy(bool v) {
    busy = v;
    notifyListeners();
  }
}

/// 사진을 긴 변 [maxSide] 이하 JPEG 로 줄여 base64 문자열로 (전송량 절약)
/// 같은 사진을 여러 번 압축하지 않도록 (체크 목록을 바꿀 때마다 다시 압축하면 느려짐)
final _jpegCache = Expando<Map<int, String>>();

/// 기본: 긴 변 2048 · 품질 88 (PC 에서 크게 확대해도 덜 흐리게, 2026.11.27-c. 예전 1280 · 80)
Future<String> jpegBase64(
  Uint8List src, {
  int maxSide = 2048,
  int quality = 88,
}) async {
  final cache = _jpegCache[src] ??= {};
  final ck = maxSide * 1000 + quality;
  final hit = cache[ck];
  if (hit != null) return hit;
  final out = await _jpegBase64(src, maxSide: maxSide, quality: quality);
  cache[ck] = out;
  return out;
}

Future<String> _jpegBase64(
  Uint8List src, {
  required int maxSide,
  required int quality,
}) async {
  // 긴 변 maxSide 이하로 줄여서 풀기 (안드로이드·PC·웹 모두 지원하는 방식)
  final buffer = await ui.ImmutableBuffer.fromUint8List(src);
  final codec = await ui.instantiateImageCodecWithSize(
    buffer,
    getTargetSize: (iw, ih) {
      final scale = math.min(1.0, maxSide / math.max(iw, ih));
      return ui.TargetImageSize(
        width: (iw * scale).round(),
        height: (ih * scale).round(),
      );
    },
  );
  final frame = await codec.getNextFrame();
  final w = frame.image.width, h = frame.image.height;
  final raw = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
  frame.image.dispose();
  final rgba = raw!.buffer.asUint8List();
  return compute(_encodeJpeg, (rgba, w, h, quality));
}

String _encodeJpeg((Uint8List, int, int, int) a) {
  final image = img.Image.fromBytes(
    width: a.$2,
    height: a.$3,
    bytes: a.$1.buffer,
    numChannels: 4,
  );
  return base64Encode(img.encodeJpg(image, quality: a.$4));
}
