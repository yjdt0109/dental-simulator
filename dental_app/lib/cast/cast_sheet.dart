import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../app_theme.dart';
import 'cast_service.dart';

/// 상단 바의 [📺 큰 화면 연결] 버튼
class CastButton extends StatelessWidget {
  const CastButton({super.key, required this.iconOnly});
  final bool iconOnly;

  @override
  Widget build(BuildContext context) {
    final cs = CastService.instance;
    return ListenableBuilder(
      listenable: cs,
      builder: (context, _) {
        final live = cs.connected && cs.monitorOnline;
        final label = live
            ? '${cs.monitorName ?? '큰 화면'} 연결됨'
            : cs.connected
            ? '큰 화면 대기 중'
            : '큰 화면 연결';
        final color = live ? AppColors.mint : AppColors.blue;
        void open() => showCastSheet(context);
        if (iconOnly) {
          return IconButton(
            tooltip: label,
            onPressed: open,
            icon: Icon(Icons.connected_tv_rounded, color: color),
          );
        }
        return Padding(
          padding: const EdgeInsets.only(left: 6),
          child: live
              ? FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.mint,
                    minimumSize: const Size(0, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    textStyle: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  onPressed: open,
                  icon: const Icon(Icons.connected_tv_rounded, size: 18),
                  label: Text(label),
                )
              : OutlinedButton.icon(
                  onPressed: open,
                  icon: const Icon(Icons.connected_tv_rounded, size: 18),
                  label: Text(label),
                ),
        );
      },
    );
  }
}

Future<void> showCastSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: Colors.white,
    constraints: const BoxConstraints(maxWidth: 520),
    builder: (_) => const _CastSheet(),
  );
}

class _CastSheet extends StatefulWidget {
  const _CastSheet();
  @override
  State<_CastSheet> createState() => _CastSheetState();
}

class _CastSheetState extends State<_CastSheet> {
  final _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final room = await Navigator.of(context)
        .push<String>(MaterialPageRoute(builder: (_) => const QrScanPage()));
    if (room == null || !mounted) return;
    final ok = await CastService.instance.connectRoom(room);
    if (ok && mounted) Navigator.pop(context);
  }

  Future<void> _connectCode() async {
    final code = _code.text.trim();
    if (code.length != 4) {
      CastService.instance.error = '숫자 4자리를 입력해 주세요.';
      setState(() {});
      return;
    }
    final ok = await CastService.instance.connectCode(code);
    if (ok && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final cs = CastService.instance;
    return ListenableBuilder(
      listenable: cs,
      builder: (context, _) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            24,
            0,
            24,
            24 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '📺 상담실 큰 화면 연결',
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                  color: AppColors.blueDeep,
                ),
              ),
              const Text(
                '앱 버전 ${CastService.appVersion}',
                style: TextStyle(fontSize: 12, color: AppColors.gray500),
              ),
              const SizedBox(height: 14),
              if (!cs.available)
                _note(
                  cs.error ?? '큰 화면 연결 기능을 준비하는 중입니다. 인터넷 연결을 확인해 주세요.',
                  warn: true,
                )
              else if (cs.connected)
                ..._linked(cs)
              else
                ..._pair(cs),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _linked(CastService cs) => [
    Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: (cs.monitorOnline ? AppColors.mint : AppColors.gray500)
            .withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: (cs.monitorOnline ? AppColors.mint : AppColors.gray200),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.circle,
            size: 12,
            color: cs.monitorOnline ? AppColors.mint : AppColors.gray500,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  cs.monitorName ?? '상담실 모니터',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  cs.monitorOnline ? '연결됨 · [환자 브리핑 모드]를 켜면 큰 화면에 사진이 나옵니다' : 'PC 상담 모니터가 꺼졌습니다. 잠시 후 연결이 해제되니, PC에서 상담 모니터를 다시 열고 QR을 스캔해 주세요.',
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.gray500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
    const SizedBox(height: 16),
    Row(
      children: [
        Expanded(
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
            onPressed: () async {
              await cs.disconnect();
              if (mounted) Navigator.pop(context);
            },
            child: const Text('연결 해제'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: FilledButton(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
            onPressed: () => Navigator.pop(context),
            child: const Text('닫기'),
          ),
        ),
      ],
    ),
  ];

  List<Widget> _pair(CastService cs) => [
    const Text(
      '① 상담실 PC에서 [상담 모니터] 아이콘을 엽니다.\n② PC 화면의 QR 코드를 스캔하면 바로 연결됩니다.\n③ 앱을 껐다 켜거나 PC 화면을 새로 열면 다시 QR로 연결합니다 (자동 연결 안 됨).',
      style: TextStyle(fontSize: 14, height: 1.6),
    ),
    const SizedBox(height: 16),
    FilledButton.icon(
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
      onPressed: cs.busy ? null : _scan,
      icon: const Icon(Icons.qr_code_scanner_rounded),
      label: const Text('QR 코드 스캔하기'),
    ),
    const SizedBox(height: 18),
    const Row(
      children: [
        Expanded(child: Divider(color: AppColors.gray200)),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 10),
          child: Text(
            'QR이 안 되면 숫자 4자리 입력',
            style: TextStyle(fontSize: 12, color: AppColors.gray500),
          ),
        ),
        Expanded(child: Divider(color: AppColors.gray200)),
      ],
    ),
    const SizedBox(height: 12),
    Row(
      children: [
        Expanded(
          child: TextField(
            controller: _code,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            maxLength: 4,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w800,
              letterSpacing: 8,
            ),
            decoration: const InputDecoration(
              counterText: '',
              hintText: '0000',
            ),
            onSubmitted: (_) => _connectCode(),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          height: 54,
          child: FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(88, 54)),
            onPressed: cs.busy ? null : _connectCode,
            child: cs.busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: Colors.white,
                    ),
                  )
                : const Text('연결'),
          ),
        ),
      ],
    ),
    if (cs.error != null) ...[
      const SizedBox(height: 10),
      _note(cs.error!, warn: true),
    ],
  ];

  Widget _note(String text, {bool warn = false}) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: warn ? const Color(0xFFFFF4E5) : AppColors.blueSoft,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 13,
        color: warn ? const Color(0xFF8A5300) : AppColors.blueDeep,
      ),
    ),
  );
}

/// 카메라로 PC 화면의 QR 읽기 → 방 번호 반환
class QrScanPage extends StatefulWidget {
  const QrScanPage({super.key});
  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<QrScanPage> {
  bool _done = false;
  String? _hint;

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final room = CastService.roomFromQr(b.rawValue ?? '');
      if (room != null) {
        _done = true;
        Navigator.pop(context, room);
        return;
      }
    }
    setState(() => _hint = '상담 모니터의 QR이 아닙니다. PC 화면의 QR을 비춰 주세요.');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text(
          'PC 화면의 QR 코드를 비춰 주세요',
          style: TextStyle(fontSize: 16, color: Colors.white),
        ),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            onDetect: _onDetect,
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '카메라를 열 수 없습니다.\n설정에서 이 앱의 카메라 권한을 허용하거나, 숫자 4자리로 연결해 주세요.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    height: 1.6,
                  ),
                ),
              ),
            ),
          ),
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 3),
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          ),
          if (_hint != null)
            Positioned(
              left: 24,
              right: 24,
              bottom: 40,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  _hint!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
