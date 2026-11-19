import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_theme.dart';
import 'ai_service.dart';
import 'pipeline.dart';

/// AI 연결 설정 · API 키
///  ① Fal.ai API 키 (1단계 FLUX.1 Fill) — 맨 위
///  ② Google Vertex AI (옵션 C): API 키 + 프로젝트 ID (고급: 서비스 계정 JSON)
///  ③ 이 태블릿의 App Check 인증 토큰 (나노바나나)
/// 키는 이 태블릿 안에만 저장되고, PC 상담 모니터로는 보내지 않습니다.
Future<void> showAiSettingsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true, // 화면 거의 전체 높이까지
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: Colors.white,
    constraints: const BoxConstraints(maxWidth: 680),
    builder: (ctx) =>
        const FractionallySizedBox(heightFactor: 0.94, child: _AiSettings()),
  );
}

class _AiSettings extends StatefulWidget {
  const _AiSettings();
  @override
  State<_AiSettings> createState() => _AiSettingsState();
}

class _AiSettingsState extends State<_AiSettings> {
  final st = PipelineSettings.instance;
  final _fal = TextEditingController();
  final _json = TextEditingController();
  final _vkey = TextEditingController();
  late final _project = TextEditingController(text: st.vertexProject);
  late final _location = TextEditingController(text: st.vertexLocation);
  late final _imagen = TextEditingController(text: st.imagenModel);
  late final _nano = TextEditingController(text: st.nanoModel);
  late final _nanoPro = TextEditingController(text: st.nanoProModel);
  bool _showFal = false, _showVkey = false, _busy = false;

  // 각 칸 아래에 바로 보이는 결과 (스낵바는 시트 뒤에 가려져서 안 씀)
  String? _falMsg, _vertexMsg, _modelMsg;
  bool _falErr = false, _vertexErr = false;

  @override
  void dispose() {
    for (final c in [
      _fal,
      _json,
      _vkey,
      _project,
      _location,
      _imagen,
      _nano,
      _nanoPro,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _paste(TextEditingController c) async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    final t = d?.text?.trim() ?? '';
    setState(() {
      if (t.isNotEmpty) c.text = t;
    });
  }

  String _where() =>
      st.savedInFallback ? ' (이 기기의 보안 저장소를 쓸 수 없어 앱 저장소에 저장)' : ' (보안 저장소)';

  Future<void> _saveFal() async {
    if (_fal.text.trim().isEmpty) {
      setState(() {
        _falErr = true;
        _falMsg = '키를 붙여넣은 뒤 [저장]을 눌러 주세요.';
      });
      return;
    }
    setState(() => _busy = true);
    try {
      await st.saveFalKey(_fal.text);
      _fal.clear();
      _falErr = false;
      _falMsg = '✓ 저장했습니다: ${PipelineSettings.masked(st.falKey)}${_where()}';
    } catch (e) {
      _falErr = true;
      _falMsg = '저장하지 못했습니다: ${e is PipelineError ? e.message : e}';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _saveVertex() async {
    setState(() => _busy = true);
    try {
      if (_project.text.trim().isEmpty) {
        throw const PipelineError(
          '프로젝트 ID를 입력해 주세요. (Google Cloud 콘솔 맨 위 프로젝트 선택 창에 보이는 ID)',
        );
      }
      await st.saveProject(
        _project.text,
        _location.text,
        _imagen.text,
        _nano.text,
        _nanoPro.text,
      );
      final saved = <String>[];
      if (_vkey.text.trim().isNotEmpty) {
        await st.saveVertexApiKey(_vkey.text);
        _vkey.clear();
        saved.add(
          'API 키 ${PipelineSettings.masked(st.vertexApiKey).replaceFirst('저장됨 ', '')}',
        );
      }
      if (_json.text.trim().isNotEmpty) {
        await st.saveVertexJson(_json.text);
        _json.clear();
        _project.text = st.vertexProject;
        saved.add('서비스 계정 JSON');
      }
      saved.add('프로젝트 ID ${st.vertexProject}');
      _vertexErr = !st.hasVertex;
      _vertexMsg = st.hasVertex
          ? '✓ 저장했습니다: ${saved.join(' · ')}${saved.length > 1 ? _where() : ''}'
          : '프로젝트 ID만 저장했습니다. Vertex AI API 키(AIzaSy…)도 붙여넣어 주세요.';
    } catch (e) {
      _vertexErr = true;
      _vertexMsg = e is PipelineError ? e.message : '저장하지 못했습니다: $e';
    }
    if (mounted) setState(() => _busy = false);
  }

  Widget _title(String t, {String? sub}) => Padding(
    padding: const EdgeInsets.only(top: 18, bottom: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
            color: AppColors.blueDeep,
          ),
        ),
        if (sub != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              sub,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.gray500,
                height: 1.45,
              ),
            ),
          ),
      ],
    ),
  );

  Widget _status(bool ok, String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(
      color: ok ? AppColors.mint.withValues(alpha: 0.1) : AppColors.gray100,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      children: [
        Icon(
          ok ? Icons.check_circle_rounded : Icons.error_outline_rounded,
          size: 18,
          color: ok ? AppColors.mint : AppColors.gray500,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: ok ? AppColors.mint : AppColors.gray500,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _msg(String? m, bool err) => m == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            m,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: err ? AppColors.error : AppColors.mint,
              height: 1.4,
            ),
          ),
        );

  Widget _small(TextEditingController c, String label) => TextField(
    controller: c,
    autocorrect: false,
    enableSuggestions: false,
    style: const TextStyle(fontSize: 13),
    decoration: InputDecoration(isDense: true, labelText: label),
  );

  @override
  Widget build(BuildContext context) {
    final ai = AiService.instance;
    final token = ai.debugToken;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '🔑 API 키 설정',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          const Text(
            '키는 이 태블릿 안에만 저장되고, PC 상담 모니터·다른 기기로는 보내지 않습니다.',
            style: TextStyle(
              fontSize: 12.5,
              color: AppColors.gray500,
              height: 1.45,
            ),
          ),

          // ① Fal.ai --------------------------------------------------------------
          _title(
            '① Fal.ai API Key  (옵션 A·B·C 1단계 FLUX용)',
            sub: 'fal.ai 로그인 → Dashboard → [Keys] → 키 복사 → 아래 [붙여넣기] → [Fal.ai 키 저장]',
          ),
          _status(st.hasFal, 'Fal.ai 키: ${PipelineSettings.masked(st.falKey)}'),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('falField'),
            controller: _fal,
            obscureText: !_showFal,
            autocorrect: false,
            enableSuggestions: false,
            onChanged: (_) => setState(() => _falMsg = null),
            decoration: InputDecoration(
              labelText: st.hasFal ? '새 키로 바꾸려면 여기에 붙여넣기' : 'Fal.ai API 키 붙여넣기',
              prefixIcon: const Icon(Icons.key_rounded),
              suffixIcon: IconButton(
                tooltip: _showFal ? '숨기기' : '보기',
                onPressed: () => setState(() => _showFal = !_showFal),
                icon: Icon(
                  _showFal
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _paste(_fal),
                icon: const Icon(Icons.content_paste_rounded, size: 18),
                label: const Text('붙여넣기'),
              ),
              FilledButton.icon(
                onPressed: _busy ? null : _saveFal,
                icon: const Icon(Icons.save_rounded, size: 18),
                label: const Text('Fal.ai 키 저장'),
              ),
              if (st.hasFal)
                TextButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          await st.saveFalKey(null);
                          setState(() {
                            _falErr = false;
                            _falMsg = 'Fal.ai 키를 지웠습니다.';
                          });
                        },
                  child: const Text('키 삭제'),
                ),
            ],
          ),
          _msg(_falMsg, _falErr),

          // ② Vertex AI -------------------------------------------------------------
          _title(
            '② Google Vertex AI  (옵션 C 2단계 · 무료 크레딧)',
            sub:
                'Google Cloud 콘솔에서 만든 API 키(AIzaSy…)와 그 키가 속한 프로젝트 ID를 넣으세요. '
                '이 프로젝트에 연결된 결제 계정의 크레딧으로 청구됩니다.',
          ),
          _status(
            st.hasVertex,
            st.hasVertexKey
                ? 'Vertex AI API 키: ${PipelineSettings.masked(st.vertexApiKey)} · 프로젝트 ${st.vertexProject}'
                : st.hasVertexJson
                ? '서비스 계정 JSON으로 연결됨 · 프로젝트 ${st.vertexProject}'
                : 'Vertex AI: 저장 안 됨',
          ),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('vertexKeyField'),
            controller: _vkey,
            obscureText: !_showVkey,
            autocorrect: false,
            enableSuggestions: false,
            onChanged: (_) => setState(() => _vertexMsg = null),
            decoration: InputDecoration(
              labelText: st.hasVertexKey
                  ? '새 API 키로 바꾸려면 붙여넣기'
                  : 'Vertex AI API 키 (AIzaSy…) 붙여넣기',
              prefixIcon: const Icon(Icons.vpn_key_outlined),
              suffixIcon: IconButton(
                tooltip: _showVkey ? '숨기기' : '보기',
                onPressed: () => setState(() => _showVkey = !_showVkey),
                icon: Icon(
                  _showVkey
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('projectField'),
            controller: _project,
            autocorrect: false,
            enableSuggestions: false,
            onChanged: (_) => setState(() => _vertexMsg = null),
            decoration: const InputDecoration(
              labelText: '프로젝트 ID',
              hintText: '예) project-4bd0de84-…',
              prefixIcon: Icon(Icons.folder_outlined),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _small(_location, '지역 (location)')),
              const SizedBox(width: 8),
              Expanded(child: _small(_imagen, 'Imagen 편집 모델')),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _paste(_vkey),
                icon: const Icon(Icons.content_paste_rounded, size: 18),
                label: const Text('API 키 붙여넣기'),
              ),
              FilledButton.icon(
                onPressed: _busy ? null : _saveVertex,
                icon: const Icon(Icons.save_rounded, size: 18),
                label: const Text('Vertex AI 저장'),
              ),
              if (st.hasVertex)
                TextButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          await st.saveVertexApiKey(null);
                          await st.saveVertexJson(null);
                          setState(() {
                            _vertexErr = false;
                            _vertexMsg = 'Vertex AI 키를 지웠습니다.';
                          });
                        },
                  child: const Text('키 삭제'),
                ),
            ],
          ),
          _msg(_vertexMsg, _vertexErr),
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text(
                '고급: 서비스 계정 JSON으로 연결',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
              subtitle: const Text(
                'API 키를 쓰면 필요 없어요 (API 키가 있으면 API 키를 먼저 씀)',
                style: TextStyle(fontSize: 11.5),
              ),
              children: [
                TextField(
                  key: const ValueKey('vertexField'),
                  controller: _json,
                  minLines: 3,
                  maxLines: 6,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  decoration: const InputDecoration(
                    labelText: '서비스 계정 JSON 붙여넣기',
                    hintText: '{ "type": "service_account", … }',
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : () => _paste(_json),
                    icon: const Icon(Icons.content_paste_rounded, size: 18),
                    label: const Text('JSON 붙여넣기'),
                  ),
                ),
                const SizedBox(height: 4),
              ],
            ),
          ),

          // ③ App Check ---------------------------------------------------------------
          _title(
            '③ 나노바나나 (2.1 / Pro) — 이 태블릿 인증 토큰',
            sub: 'Firebase 콘솔 [App Check] → 디버그 토큰 관리에 한 번 등록 (이미 하셨으면 그대로)',
          ),
          _status(
            ai.ready,
            ai.ready ? '나노바나나 연결 준비됨' : '준비 안 됨 (인터넷 연결 후 앱을 다시 실행)',
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.gray100,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: SelectableText(
                    token ?? '(없음)',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12.5,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: token == null
                    ? null
                    : () => Clipboard.setData(ClipboardData(text: token)),
                child: const Text('복사'),
              ),
            ],
          ),

          // 고급: 모델 이름 -------------------------------------------------------------
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text(
                '고급: 나노바나나 모델 이름',
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
              ),
              subtitle: const Text(
                'Google 이 모델 이름을 바꾸면 여기서 고칠 수 있어요',
                style: TextStyle(fontSize: 11.5),
              ),
              children: [
                _small(_nano, '옵션 A · 나노바나나 2.1'),
                const SizedBox(height: 8),
                _small(_nanoPro, '옵션 B · 나노바나나 Pro'),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton(
                    onPressed: () async {
                      await st.saveProject(
                        _project.text,
                        _location.text,
                        _imagen.text,
                        _nano.text,
                        _nanoPro.text,
                      );
                      setState(() {
                        _nano.text = st.nanoModel;
                        _nanoPro.text = st.nanoProModel;
                        _modelMsg = '✓ 모델 이름을 저장했습니다';
                      });
                    },
                    child: const Text('모델 이름 저장'),
                  ),
                ),
                _msg(_modelMsg, false),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '※ 키는 비밀번호처럼 다뤄 주세요. 채팅·메신저로 보내거나 사진으로 찍지 마세요.\n'
            '※ API 키는 Google Cloud [API 및 서비스] → [사용자 인증 정보]에서 "Vertex AI API"만 쓰도록 제한하고, [결제] → [예산 및 알림]을 걸어 두세요.\n'
            '※ AI 변환 시 환자 사진(눈 가림)이 Fal.ai·Google 서버로 전송됩니다. 환자 동의를 받아 주세요.',
            style: TextStyle(
              fontSize: 12,
              color: AppColors.gray500,
              height: 1.55,
            ),
          ),
        ],
      ),
    );
  }
}
