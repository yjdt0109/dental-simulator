import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;

import 'face_align.dart';

// -----------------------------------------------------------------------------
// 📸 가이드 촬영 화면 (2026.11.27-h)
//   ① 고스트: 먼저 찍은 원본(1 또는 2)을 반투명 사진 / 윤곽선으로 겹쳐 보여 줌
//   ② 가이드선: 수직 정중선 · 눈동자 수평선 · 얼굴 타원 · (원본 1 미소만) 교합평면선
//   ③ 실시간 자동 확인: 얼굴 인식으로 수평·정면·고개·거리·위치를 먼저 찍은 사진과 비교
//   결과: 찍은 사진(JPEG 바이트), 취소하면 null
// -----------------------------------------------------------------------------

enum GhostMode { photo, outline, off }

/// 테스트용: 카메라 대신 보여 줄 화면 (null 이면 진짜 카메라)
Widget? debugCameraPreview;

/// 테스트용: 셔터를 누르면 돌려줄 사진
Uint8List? debugCameraShot;

/// 테스트용: 실시간 판정 결과를 바로 넣기
AlignResult? debugLiveAlign;

Future<Uint8List?> openGuidedCamera(
  BuildContext context, {
  required int slot,
  Uint8List? ghost,
}) => Navigator.of(context).push<Uint8List>(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => GuidedCameraScreen(slot: slot, ghost: ghost),
  ),
);

class GuidedCameraScreen extends StatefulWidget {
  const GuidedCameraScreen({super.key, required this.slot, this.ghost});

  /// 찍을 원본 번호: 1 = 자연스러운 미소, 2 = 개구기
  final int slot;

  /// 먼저 찍은 다른 원본 (겹쳐 볼 사진)
  final Uint8List? ghost;

  @override
  State<GuidedCameraScreen> createState() => _GuidedCameraScreenState();
}

class _GuidedCameraScreenState extends State<GuidedCameraScreen> {
  CameraController? _ctl;
  String? _err;
  GhostMode _mode = GhostMode.photo;
  double _opacity = 0.35;
  bool _guides = true;
  bool _shooting = false;
  Uint8List? _outline; // 윤곽선 PNG
  FacePose? _ref; // 먼저 찍은 사진의 얼굴
  AlignResult? _align;
  FaceDetector? _detector;
  bool _busy = false;
  int _lastRun = 0;
  int _rotation = 90;
  List<CameraDescription> _cams = const [];
  bool _selfie = _lastSelfie; // 앞(셀카) 카메라
  static bool _lastSelfie = false; // 다음에 열 때도 같은 카메라

  /// 화면에 보이는 대로의 기준 얼굴 (셀카면 거울처럼 좌우 뒤집음)
  FacePose? get _refShown => _selfie ? _ref?.mirrored() : _ref;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    final g = widget.ghost;
    if (g == null) _mode = GhostMode.off;
    if (g != null) {
      compute(ghostOutline, g)
          .then((v) {
            if (mounted) setState(() => _outline = v);
          })
          .catchError((Object _) {});
      facePoseOfPhoto(g).then((v) {
        if (mounted) setState(() => _ref = v);
      });
    }
    if (debugCameraPreview == null) _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cams = _cams.isEmpty ? await availableCameras() : _cams;
      if (cams.isEmpty) throw StateError('카메라를 찾지 못했습니다');
      _cams = cams;
      final want = _selfie
          ? CameraLensDirection.front
          : CameraLensDirection.back;
      final cam = cams.firstWhere(
        (c) => c.lensDirection == want,
        orElse: () => cams.first,
      );
      _selfie = cam.lensDirection == CameraLensDirection.front;
      _rotation = cam.sensorOrientation;
      final ctl = CameraController(
        cam,
        ResolutionPreset.max,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.nv21,
      );
      await ctl.initialize();
      try {
        await ctl.lockCaptureOrientation(DeviceOrientation.portraitUp);
      } catch (_) {}
      if (!mounted) {
        await ctl.dispose();
        return;
      }
      setState(() => _ctl = ctl);
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        _detector = FaceDetector(
          options: FaceDetectorOptions(
            enableLandmarks: true,
            enableClassification: false,
            performanceMode: FaceDetectorMode.fast,
            minFaceSize: 0.15,
          ),
        );
        try {
          await ctl.startImageStream(_onFrame);
        } catch (e) {
          debugPrint('image stream: $e');
        }
      }
    } catch (e) {
      if (mounted) setState(() => _err = '카메라를 열지 못했습니다 ($e)');
    }
  }

  Future<void> _onFrame(CameraImage f) async {
    final det = _detector;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (det == null || _busy || now - _lastRun < 300) return;
    _busy = true;
    _lastRun = now;
    try {
      final bytes = nv21Of(f);
      final rot = switch (_rotation) {
        90 => InputImageRotation.rotation90deg,
        180 => InputImageRotation.rotation180deg,
        270 => InputImageRotation.rotation270deg,
        _ => InputImageRotation.rotation0deg,
      };
      final faces = await det.processImage(
        InputImage.fromBytes(
          bytes: bytes,
          metadata: InputImageMetadata(
            size: ui.Size(f.width.toDouble(), f.height.toDouble()),
            rotation: rot,
            format: InputImageFormat.nv21,
            bytesPerRow: f.width,
          ),
        ),
      );
      final side = _rotation == 90 || _rotation == 270;
      final w = (side ? f.height : f.width).toDouble();
      final h = (side ? f.width : f.height).toDouble();
      final raw = poseOfFaces(faces, w, h);
      final pose = _selfie ? raw?.mirrored() : raw; // 거울 화면 기준
      if (mounted) {
        setState(() => _align = checkAlign(pose, _refShown, selfie: _selfie));
      }
    } catch (e) {
      debugPrint('face check: $e');
    } finally {
      _busy = false;
    }
  }

  /// 앞(셀카) ↔ 뒤 카메라 바꾸기
  Future<void> _flip() async {
    if (_shooting) return;
    final old = _ctl;
    setState(() {
      _selfie = !_selfie;
      _lastSelfie = _selfie;
      _ctl = null;
      _align = null;
    });
    if (old != null) {
      try {
        if (old.value.isStreamingImages) await old.stopImageStream();
      } catch (_) {}
      await old.dispose();
    }
    await _detector?.close();
    _detector = null;
    if (debugCameraPreview == null) await _initCamera();
  }

  Future<void> _shoot() async {
    if (_shooting) return;
    setState(() => _shooting = true);
    try {
      if (debugCameraPreview != null) {
        if (mounted) Navigator.pop(context, debugCameraShot);
        return;
      }
      final ctl = _ctl;
      if (ctl == null) return;
      try {
        if (ctl.value.isStreamingImages) await ctl.stopImageStream();
      } catch (_) {}
      final x = await ctl.takePicture();
      final b = await x.readAsBytes();
      if (mounted) Navigator.pop(context, b);
    } catch (e) {
      if (mounted) {
        setState(() => _shooting = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('촬영하지 못했습니다 ($e)')));
      }
    }
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    final ctl = _ctl;
    if (ctl != null) {
      () async {
        try {
          if (ctl.value.isStreamingImages) await ctl.stopImageStream();
        } catch (_) {}
        await ctl.dispose();
      }();
    }
    _detector?.close();
    super.dispose();
  }

  String get _title =>
      widget.slot == 1 ? '원본 1 촬영 · 자연스러운 미소' : '원본 2 촬영 · 개구기';

  @override
  Widget build(BuildContext context) {
    final align = debugLiveAlign ?? _align;
    final ctl = _ctl;
    final ratio = debugCameraPreview != null
        ? 3 / 4
        : (ctl != null && ctl.value.isInitialized
              ? 1 / ctl.value.aspectRatio
              : 3 / 4);
    final preview =
        debugCameraPreview ??
        (ctl != null && ctl.value.isInitialized
            ? CameraPreview(ctl)
            : Center(
                child: _err != null
                    ? Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          _err!,
                          style: const TextStyle(color: Colors.white),
                          textAlign: TextAlign.center,
                        ),
                      )
                    : const CircularProgressIndicator(color: Colors.white),
              ));
    final ghost = widget.ghost;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(_title, style: const TextStyle(fontSize: 17)),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: ratio,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ClipRect(child: preview),
                      if (ghost != null && _mode == GhostMode.photo)
                        IgnorePointer(
                          child: Transform.flip(
                            flipX: _selfie, // 셀카 화면은 거울처럼 보이므로 겹칠 사진도
                            child: Opacity(
                              opacity: _opacity,
                              child: Image.memory(
                                ghost,
                                fit: BoxFit.cover,
                                gaplessPlayback: true,
                              ),
                            ),
                          ),
                        ),
                      if (_outline != null && _mode == GhostMode.outline)
                        IgnorePointer(
                          child: Transform.flip(
                            flipX: _selfie,
                            child: Opacity(
                              opacity: math.min(1, _opacity * 2.2),
                              child: Image.memory(
                                _outline!,
                                fit: BoxFit.cover,
                                gaplessPlayback: true,
                              ),
                            ),
                          ),
                        ),
                      if (_guides)
                        IgnorePointer(
                          child: CustomPaint(
                            painter: GuidePainter(
                              occlusal: widget.slot == 1,
                              oval: ghost == null,
                              ok: align?.allOk ?? false,
                            ),
                          ),
                        ),
                      Positioned(
                        left: 8,
                        right: 8,
                        top: 8,
                        child: _statusBar(align),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            _controls(ghost != null),
          ],
        ),
      ),
    );
  }

  Widget _statusBar(AlignResult? a) {
    final hasDetector =
        debugLiveAlign != null ||
        _detector != null ||
        debugCameraPreview != null;
    final msg = !hasDetector
        ? (widget.ghost != null
              ? '눈·코·이마를 겹쳐 맞추세요 (개구기를 끼면 입 주변은 달라도 정상)'
              : '얼굴을 타원·눈동자선·중앙선에 맞추세요')
        : a == null
        ? '얼굴을 찾는 중…'
        : a.message;
    final ok = a?.allOk ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (a != null && a.face)
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final i in a.items)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: i.ok
                        ? const Color(0xE600A88F)
                        : const Color(0xE6D9363E),
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Text(
                    '${i.label} ${i.ok ? '✓' : '✕'}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
            ],
          ),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: ok ? const Color(0xE600A88F) : const Color(0xB3000000),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            msg,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }

  Widget _controls(bool hasGhost) {
    const white = TextStyle(color: Colors.white, fontSize: 13);
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasGhost)
            Row(
              children: [
                const Text('겹쳐 보기', style: white),
                const SizedBox(width: 8),
                Expanded(
                  child: SegmentedButton<GhostMode>(
                    style: SegmentedButton.styleFrom(
                      foregroundColor: Colors.white,
                      selectedForegroundColor: Colors.black,
                      selectedBackgroundColor: Colors.white,
                      visualDensity: VisualDensity.compact,
                    ),
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                        value: GhostMode.photo,
                        label: Text('반투명 사진'),
                      ),
                      ButtonSegment(
                        value: GhostMode.outline,
                        label: Text('윤곽선'),
                      ),
                      ButtonSegment(value: GhostMode.off, label: Text('끄기')),
                    ],
                    selected: {_mode},
                    onSelectionChanged: (s) => setState(() => _mode = s.first),
                  ),
                ),
              ],
            ),
          if (hasGhost && _mode != GhostMode.off)
            Row(
              children: [
                Text('투명도 ${(_opacity * 100).round()}%', style: white),
                Expanded(
                  child: Slider(
                    value: _opacity,
                    min: 0.15,
                    max: 0.7,
                    divisions: 11,
                    onChanged: (v) => setState(() => _opacity = v),
                  ),
                ),
              ],
            ),
          Row(
            children: [
              TextButton.icon(
                onPressed: () => setState(() => _guides = !_guides),
                icon: Icon(
                  _guides ? Icons.grid_on_rounded : Icons.grid_off_rounded,
                  color: Colors.white,
                ),
                label: Text(_guides ? '가이드선 끄기' : '가이드선 켜기', style: white),
              ),
              const Spacer(),
              SizedBox(
                width: 76,
                height: 76,
                child: Semantics(
                  button: true,
                  label: '촬영',
                  child: Material(
                    color: Colors.white,
                    shape: const CircleBorder(
                      side: BorderSide(color: Color(0xFF00A88F), width: 4),
                    ),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: _shooting ? null : _shoot,
                      child: Center(
                        child: _shooting
                            ? const CircularProgressIndicator()
                            : const Icon(
                                Icons.camera_alt_rounded,
                                size: 34,
                                color: Colors.black87,
                              ),
                      ),
                    ),
                  ),
                ),
              ),
              const Spacer(),
              SizedBox(
                width: 110,
                child: TextButton.icon(
                  onPressed: _shooting ? null : _flip,
                  icon: const Icon(
                    Icons.cameraswitch_rounded,
                    color: Colors.white,
                  ),
                  label: Text(_selfie ? '뒤 카메라' : '셀카', style: white),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// ② 가이드선: 수직 정중선(점선) · 눈동자 수평선 · 얼굴 타원 · 교합평면선(원본 1)
class GuidePainter extends CustomPainter {
  const GuidePainter({
    this.occlusal = false,
    this.oval = true,
    this.ok = false,
  });
  final bool occlusal, oval, ok;

  @override
  void paint(Canvas c, Size s) {
    final col = ok ? const Color(0xFF3DDC97) : const Color(0xFFFFE14D);
    final p = Paint()
      ..color = col.withValues(alpha: 0.9)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    void dashed(Offset a, Offset b) {
      final len = (b - a).distance;
      const dash = 10.0, gap = 7.0;
      final dir = (b - a) / len;
      for (var t = 0.0; t < len; t += dash + gap) {
        c.drawLine(a + dir * t, a + dir * math.min(len, t + dash), p);
      }
    }

    final x = s.width * GuideGeom.midX;
    dashed(Offset(x, 0), Offset(x, s.height));
    final ey = s.height * GuideGeom.eyeY;
    c.drawLine(Offset(s.width * 0.12, ey), Offset(s.width * 0.88, ey), p);
    // 눈금 (가로 길이 재기): 가운데부터 양쪽으로 2.5% 마다 작은 눈금, 10% 마다 큰 눈금 + 숫자
    final tick = Paint()
      ..color = col.withValues(alpha: 0.9)
      ..strokeWidth = 1.5;
    for (var i = -15; i <= 15; i++) {
      final tx = x + s.width * 0.025 * i;
      final big = i % 4 == 0;
      final len = big ? 12.0 : 6.0;
      c.drawLine(Offset(tx, ey - len), Offset(tx, ey + len), tick);
      if (big && i != 0) {
        final tp = TextPainter(
          text: TextSpan(
            text: '${i.abs() ~/ 4}',
            style: TextStyle(
              color: col,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              shadows: const [Shadow(blurRadius: 2)],
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(c, Offset(tx - tp.width / 2, ey + len + 1));
      }
    }
    if (occlusal) {
      final oy = s.height * GuideGeom.occY;
      dashed(Offset(s.width * 0.25, oy), Offset(s.width * 0.75, oy));
    }
    if (oval) {
      c.drawOval(
        Rect.fromCenter(
          center: Offset(
            s.width * GuideGeom.ovalCx,
            s.height * GuideGeom.ovalCy,
          ),
          width: s.width * GuideGeom.ovalRx * 2,
          height: s.height * GuideGeom.ovalRy * 2,
        ),
        p,
      );
    }
  }

  @override
  bool shouldRepaint(GuidePainter o) =>
      o.occlusal != occlusal || o.oval != oval || o.ok != ok;
}

/// ML Kit 얼굴들 → 가장 큰 얼굴의 위치·각도 (0~1, 바로 선 화면 기준)
FacePose? poseOfFaces(List<Face> faces, double w, double h) {
  if (faces.isEmpty) return null;
  final f = faces.reduce(
    (a, b) =>
        a.boundingBox.width * a.boundingBox.height >=
            b.boundingBox.width * b.boundingBox.height
        ? a
        : b,
  );
  final l = f.landmarks[FaceLandmarkType.leftEye]?.position;
  final r = f.landmarks[FaceLandmarkType.rightEye]?.position;
  if (l == null || r == null) return null;
  final n = f.landmarks[FaceLandmarkType.noseBase]?.position;
  return FacePose.fromEyes(
    ui.Offset(l.x / w, l.y / h),
    ui.Offset(r.x / w, r.y / h),
    nose: n == null ? null : ui.Offset(n.x / w, n.y / h),
    yaw: f.headEulerAngleY,
    pitch: f.headEulerAngleX,
  );
}

/// 찍어 둔 사진의 얼굴 위치·각도 (기준). 못 찾으면 null
Future<FacePose?> facePoseOfPhoto(Uint8List bytes) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
  File? tmp;
  final det = FaceDetector(
    options: FaceDetectorOptions(
      enableLandmarks: true,
      performanceMode: FaceDetectorMode.accurate,
      minFaceSize: 0.1,
    ),
  );
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    final fr = await codec.getNextFrame();
    final w = fr.image.width.toDouble(), h = fr.image.height.toDouble();
    final raw = await fr.image.toByteData(format: ui.ImageByteFormat.rawRgba);
    fr.image.dispose();
    final up = await compute(
      (a) => img.encodeJpg(
        img.Image.fromBytes(
          width: a.$1,
          height: a.$2,
          bytes: a.$3.buffer,
          numChannels: 4,
        ),
        quality: 90,
      ),
      (w.toInt(), h.toInt(), raw!),
    );
    tmp = File(
      '${Directory.systemTemp.path}/ghost_${DateTime.now().microsecondsSinceEpoch}.jpg',
    );
    await tmp.writeAsBytes(up, flush: true);
    final faces = await det.processImage(InputImage.fromFilePath(tmp.path));
    return poseOfFaces(faces, w, h);
  } catch (e) {
    debugPrint('ghost face: $e');
    return null;
  } finally {
    try {
      await det.close();
    } catch (_) {}
    try {
      await tmp?.delete();
    } catch (_) {}
  }
}

/// 카메라 프레임 → NV21 바이트 (ML Kit 안드로이드 입력)
Uint8List nv21Of(CameraImage f) {
  if (f.planes.length == 1) return f.planes.first.bytes;
  final w = f.width, h = f.height;
  final out = Uint8List(w * h + 2 * ((w + 1) ~/ 2) * ((h + 1) ~/ 2));
  final y = f.planes[0];
  var o = 0;
  for (var r = 0; r < h; r++) {
    final s = r * y.bytesPerRow;
    out.setRange(o, o + w, y.bytes, s);
    o += w;
  }
  final u = f.planes[1], v = f.planes[2];
  final ups = u.bytesPerPixel ?? 1, vps = v.bytesPerPixel ?? 1;
  for (var r = 0; r < h ~/ 2; r++) {
    for (var c = 0; c < w ~/ 2; c++) {
      final vi = r * v.bytesPerRow + c * vps;
      final ui0 = r * u.bytesPerRow + c * ups;
      out[o++] = vi < v.bytes.length ? v.bytes[vi] : 128;
      out[o++] = ui0 < u.bytes.length ? u.bytes[ui0] : 128;
    }
  }
  return out;
}

/// ① 윤곽선 고스트: 사진의 경계선만 하늘색 선으로 (배경 투명 PNG)
Uint8List ghostOutline(Uint8List bytes) {
  var im = img.decodeImage(bytes);
  if (im == null) throw StateError('사진을 읽지 못했습니다');
  im = img.bakeOrientation(im);
  final k = 720 / math.max(im.width, im.height);
  if (k < 1) {
    im = img.copyResize(
      im,
      width: (im.width * k).round(),
      height: (im.height * k).round(),
    );
  }
  final g = img.gaussianBlur(img.grayscale(im), radius: 2);
  final e = img.sobel(g);
  final out = img.Image(width: e.width, height: e.height, numChannels: 4);
  for (final px in e) {
    final m = px.r.toInt();
    final a = ((m - 45) * 5).clamp(0, 255);
    if (a > 0) out.setPixelRgba(px.x, px.y, 0, 229, 255, a);
  }
  return img.encodePng(out);
}
