import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../models/member.dart';
import '../models/regions.dart';
import '../utils/formatters.dart';
import '../widgets/brand_widgets.dart';
import 'home_screen.dart';

// -----------------------------------------------------------------------------
// 회원가입: 개인회원 / 사업자회원(치과·치과기공소) 따로
// -----------------------------------------------------------------------------
const kOrgKinds = ['치과', '치과기공소'];
const kRolesByOrg = {
  '치과': ['원장', '상담실장', '위생사', '직원'],
  '치과기공소': ['소장', '치과기공사', '실장', '직원'],
};

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key, required this.type, this.provider});
  final MemberType type;
  final SocialProvider? provider; // 소셜로 시작했으면 연결된 계정

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _biz = TextEditingController();
  final _phone = TextEditingController();
  final _dong = TextEditingController();
  final _addrDetail = TextEditingController();
  String _orgKind = '치과';
  String? _sido, _sigungu;
  String? _role;
  bool _agree = false;
  bool _agreeError = false;
  bool _submitting = false;

  // 사업자 인증 상태
  bool _bizChecking = false;
  bool _bizVerified = false;
  String? _bizError;

  bool get _biz10 => widget.type == MemberType.business;
  String get _bizDigits => _biz.text.replaceAll(RegExp(r'\D'), '');

  Future<void> _verifyBiz() async {
    if (_bizDigits.length != 10) {
      setState(() => _bizError = '사업자등록번호 10자리를 입력해 주세요.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _bizError = null;
      _bizChecking = true;
    });
    // 가상 검증 (실제 앱: 국세청 사업자등록 상태조회 API 로 교체)
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (!mounted) return;
    setState(() {
      _bizChecking = false;
      _bizVerified = true;
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _biz.dispose();
    _phone.dispose();
    _dong.dispose();
    _addrDetail.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final ok = _formKey.currentState!.validate();
    setState(() => _agreeError = !_agree);
    if (!ok || !_agree) return;

    setState(() => _submitting = true);
    await Future<void>.delayed(const Duration(milliseconds: 800)); // 가상 저장
    if (!mounted) return;
    setState(() => _submitting = false);

    final region = Region(_sido!, _sigungu!, _dong.text.trim());
    final m = _biz10
        ? MemberProfile(
            type: MemberType.business,
            name: _name.text.trim(),
            phone: _phone.text.trim(),
            region: region,
            bizNo: _biz.text.trim(),
            role: _role,
            orgKind: _orgKind,
            addressDetail: _addrDetail.text.trim(),
            provider: widget.provider,
          )
        : MemberProfile(
            type: MemberType.personal,
            name: _name.text.trim(),
            phone: _phone.text.trim(),
            region: region,
            provider: widget.provider,
          );

    final start = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _WelcomeDialog(member: m),
    );
    if (start == true && mounted) {
      Navigator.of(context)
          .pushAndRemoveUntil(smoothRoute(HomeScreen(member: m)), (_) => false);
    }
  }

  // 시·도 / 시·군·구 / 읍·면·동
  Widget _regionFields() {
    final gu = _sido == null ? const <String>[] : kRegions[_sido]!;
    final phone = MediaQuery.sizeOf(context).width < 420;
    final sido = DropdownButtonFormField<String>(
      key: const ValueKey('sido'),
      initialValue: _sido,
      isExpanded: true,
      hint: const Text('시·도'),
      icon: const Icon(Icons.keyboard_arrow_down_rounded),
      borderRadius: BorderRadius.circular(14),
      dropdownColor: Colors.white,
      menuMaxHeight: 420,
      items: [
        for (final s in kRegions.keys)
          DropdownMenuItem(value: s, child: Text(s)),
      ],
      onChanged: (v) => setState(() {
        _sido = v;
        _sigungu = null;
      }),
      validator: (v) => v == null ? '시·도를 선택해 주세요.' : null,
    );
    final sigungu = DropdownButtonFormField<String>(
      key: ValueKey('gu-$_sido'),
      initialValue: _sigungu,
      isExpanded: true,
      hint: const Text('시·군·구'),
      icon: const Icon(Icons.keyboard_arrow_down_rounded),
      borderRadius: BorderRadius.circular(14),
      dropdownColor: Colors.white,
      menuMaxHeight: 420,
      items: [for (final g in gu) DropdownMenuItem(value: g, child: Text(g))],
      onChanged: _sido == null ? null : (v) => setState(() => _sigungu = v),
      validator: (v) => v == null ? '시·군·구를 선택해 주세요.' : null,
    );
    final dong = TextFormField(
      controller: _dong,
      textInputAction: TextInputAction.next,
      decoration: const InputDecoration(hintText: '읍·면·동 (예: 역삼동)'),
      validator: validateDong,
    );
    if (phone) {
      return Column(
        children: [
          sido,
          const SizedBox(height: 10),
          sigungu,
          const SizedBox(height: 10),
          dong,
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: sido),
        const SizedBox(width: 8),
        Expanded(child: sigungu),
        const SizedBox(width: 8),
        Expanded(child: dong),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.provider;
    final biz = _biz10;
    final org = _orgKind;
    final roles = kRolesByOrg[org]!;
    return AuthShell(
      onBack: () => Navigator.of(context).pop(),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _StepIndicator(current: 1, middle: biz ? '사업자 정보' : '회원 정보'),
            const SizedBox(height: 22),
            Text(
              biz ? '사업자회원 가입' : '개인회원 가입',
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: AppColors.ink,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              biz
                  ? '치과·치과기공소 정보를 입력하면 전문가용 시뮬레이터를 바로 쓸 수 있어요.'
                  : '이름·연락처·지역만 입력하면 바로 시작할 수 있어요.',
              style: const TextStyle(color: AppColors.gray500, fontSize: 14),
            ),
            if (p != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: AppColors.blueSoft,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: p.bg,
                        shape: BoxShape.circle,
                        border: p == SocialProvider.google
                            ? Border.all(color: AppColors.gray200)
                            : null,
                      ),
                      alignment: Alignment.center,
                      child: SocialLogo(p, size: 15),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '${p.label} 계정이 연결되었습니다',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.blueDeep,
                        ),
                      ),
                    ),
                    const Icon(
                      Icons.check_circle_rounded,
                      color: AppColors.mint,
                      size: 20,
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 22),

            if (biz) ...[
              const _FieldLabel('기관 구분'),
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: '치과',
                    icon: Icon(Icons.local_hospital_outlined),
                    label: Text('치과(병원)'),
                  ),
                  ButtonSegment(
                    value: '치과기공소',
                    icon: Icon(Icons.precision_manufacturing_outlined),
                    label: Text('치과기공소'),
                  ),
                ],
                selected: {org},
                onSelectionChanged: (v) => setState(() {
                  _orgKind = v.first;
                  if (!kRolesByOrg[_orgKind]!.contains(_role)) _role = null;
                  _bizVerified = false;
                }),
              ),
              const SizedBox(height: 16),
            ],

            _FieldLabel(biz ? (org == '치과' ? '병원명' : '기공소명') : '이름'),
            TextFormField(
              controller: _name,
              textInputAction: TextInputAction.next,
              autofillHints: biz ? null : const [AutofillHints.name],
              decoration: InputDecoration(
                hintText: biz
                    ? (org == '치과' ? '예) 미소드림치과' : '예) 바른치과기공소')
                    : '예) 홍길동',
                prefixIcon: Icon(
                  biz
                      ? Icons.local_hospital_outlined
                      : Icons.person_outline_rounded,
                ),
              ),
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? (biz
                        ? '${org == '치과' ? '병원명' : '기공소명'}을 입력해 주세요.'
                        : '이름을 입력해 주세요.')
                  : null,
            ),
            const SizedBox(height: 16),

            if (biz) ...[
              // 사업자등록번호 + [인증하기]
              _FieldLabel('사업자등록번호', help: '$_orgKind 사업자 여부를 확인합니다'),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _biz,
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.next,
                      inputFormatters: [BizNoFormatter()],
                      forceErrorText: _bizError,
                      onChanged: (_) {
                        // 번호를 고치면 인증을 다시 받아야 함
                        if (_bizVerified || _bizError != null) {
                          setState(() {
                            _bizVerified = false;
                            _bizError = null;
                          });
                        }
                      },
                      onFieldSubmitted: (_) => _verifyBiz(),
                      style: const TextStyle(
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                      decoration: InputDecoration(
                        hintText: '000-00-00000',
                        prefixIcon: const Icon(Icons.business_center_outlined),
                        suffixIcon: _bizVerified
                            ? const Icon(
                                Icons.verified_rounded,
                                color: AppColors.mint,
                              )
                            : null,
                        enabledBorder: _bizVerified
                            ? OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: const BorderSide(
                                  color: AppColors.mint,
                                ),
                              )
                            : null,
                      ),
                      validator: (_) {
                        if (_bizDigits.length != 10) {
                          return '사업자등록번호 10자리를 입력해 주세요.';
                        }
                        if (!_bizVerified) {
                          return '[인증하기]를 눌러 사업자 인증을 완료해 주세요.';
                        }
                        return null;
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 104,
                    height: 54,
                    child: _bizVerified
                        ? OutlinedButton(
                            onPressed: null,
                            style: OutlinedButton.styleFrom(
                              disabledForegroundColor: AppColors.mint,
                              side: const BorderSide(color: AppColors.mint),
                              padding: EdgeInsets.zero,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            child: const Text(
                              '인증 완료',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                          )
                        : FilledButton(
                            onPressed: _bizChecking ? null : _verifyBiz,
                            style: FilledButton.styleFrom(
                              minimumSize: Size.zero,
                              padding: EdgeInsets.zero,
                              textStyle: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                              disabledBackgroundColor: AppColors.blue
                                  .withValues(alpha: 0.6),
                            ),
                            child: _bizChecking
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.4,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Text('인증하기'),
                          ),
                  ),
                ],
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                alignment: Alignment.topLeft,
                child: _bizVerified
                    ? Padding(
                        padding: const EdgeInsets.only(left: 6, top: 8),
                        child: Text(
                          '✓ 정상 운영 중인 $_orgKind 사업자로 확인되었습니다',
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: AppColors.mint,
                          ),
                        ),
                      )
                    : const SizedBox(width: double.infinity),
              ),
              const SizedBox(height: 16),
            ],

            _FieldLabel(
              biz ? '연락처' : '휴대폰 번호',
              help: biz ? '기공소·택배 연락에 사용합니다' : null,
            ),
            TextFormField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.telephoneNumber],
              inputFormatters: [KrPhoneFormatter()],
              decoration: InputDecoration(
                hintText: biz ? '예) 02-1234-5678' : '예) 010-1234-5678',
                prefixIcon: const Icon(Icons.call_outlined),
              ),
              validator: (v) => validateKrPhone(
                v,
                empty: biz ? '연락처를 입력해 주세요.' : '휴대폰 번호를 입력해 주세요.',
              ),
            ),
            const SizedBox(height: 16),

            _FieldLabel(
              biz ? '소재지' : '지역',
              help: biz ? '시·구·동 단위' : '주위 치과 추천에 사용 (시·구·동 단위)',
            ),
            _regionFields(),
            if (biz) ...[
              const SizedBox(height: 10),
              TextFormField(
                controller: _addrDetail,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  hintText: '상세 주소 (선택: 도로명·건물·층)',
                  prefixIcon: Icon(Icons.home_work_outlined),
                ),
              ),
              const SizedBox(height: 16),
              const _FieldLabel('직책'),
              DropdownButtonFormField<String>(
                key: ValueKey('role-$org'),
                initialValue: _role,
                hint: const Text('직책을 선택하세요'),
                icon: const Icon(Icons.keyboard_arrow_down_rounded),
                borderRadius: BorderRadius.circular(14),
                dropdownColor: Colors.white,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.badge_outlined),
                ),
                items: [
                  for (final r in roles)
                    DropdownMenuItem(value: r, child: Text(r)),
                ],
                onChanged: (v) => setState(() => _role = v),
                validator: (v) => v == null ? '직책을 선택해 주세요.' : null,
              ),
            ],
            const SizedBox(height: 18),

            // 약관 동의
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => setState(() {
                _agree = !_agree;
                if (_agree) _agreeError = false;
              }),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 36,
                      height: 36,
                      child: Checkbox(
                        value: _agree,
                        isError: _agreeError,
                        onChanged: (v) => setState(() {
                          _agree = v ?? false;
                          if (_agree) _agreeError = false;
                        }),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(5),
                        ),
                      ),
                    ),
                    const Expanded(
                      child: Text(
                        '[필수] 서비스 이용약관 및 개인정보 처리방침에 동의합니다',
                        style: TextStyle(fontSize: 13, color: AppColors.ink),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_agreeError)
              const Padding(
                padding: EdgeInsets.only(left: 12, top: 2),
                child: Text(
                  '약관에 동의해 주세요.',
                  style: TextStyle(fontSize: 12, color: AppColors.error),
                ),
              ),
            const SizedBox(height: 22),

            FilledButton(
              onPressed: _submitting ? null : _submit,
              style: FilledButton.styleFrom(
                disabledBackgroundColor: AppColors.blue.withValues(alpha: 0.6),
              ),
              child: _submitting
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.6,
                        color: Colors.white,
                      ),
                    )
                  : const Text('가입 완료 및 시작하기'),
            ),
          ],
        ),
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text, {this.help});
  final String text;
  final String? help;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8, left: 2),
    child: Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      children: [
        Text(
          text,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: AppColors.ink,
          ),
        ),
        if (help != null)
          Text(
            help!,
            style: const TextStyle(fontSize: 12, color: AppColors.gray500),
          ),
      ],
    ),
  );
}

class _StepIndicator extends StatelessWidget {
  final int current; // 0: 소셜 인증, 1: 정보 등록, 2: 시작
  const _StepIndicator({required this.current, this.middle = '회원 정보'});
  final String middle;
  List<String> get _labels => ['계정 확인', middle, '시작'];

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < _labels.length; i++) ...[
          if (i > 0)
            Expanded(
              child: Container(
                height: 2,
                margin: const EdgeInsets.only(bottom: 18),
                color: i <= current ? AppColors.blue : AppColors.gray200,
              ),
            ),
          Column(
            children: [
              CircleAvatar(
                radius: 13,
                backgroundColor: i <= current
                    ? AppColors.blue
                    : AppColors.gray100,
                child: i < current
                    ? const Icon(
                        Icons.check_rounded,
                        size: 15,
                        color: Colors.white,
                      )
                    : Text(
                        '${i + 1}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: i <= current
                              ? Colors.white
                              : AppColors.gray500,
                        ),
                      ),
              ),
              const SizedBox(height: 4),
              Text(
                _labels[i],
                style: TextStyle(
                  fontSize: 11,
                  color: i <= current ? AppColors.blue : AppColors.gray500,
                  fontWeight: i == current ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _WelcomeDialog extends StatelessWidget {
  const _WelcomeDialog({required this.member});
  final MemberProfile member;

  @override
  Widget build(BuildContext context) {
    final m = member;
    return Dialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 32, 28, 24),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.4, end: 1),
                  duration: const Duration(milliseconds: 500),
                  curve: Curves.elasticOut,
                  builder: (_, v, child) =>
                      Transform.scale(scale: v, child: child),
                  child: Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: AppColors.mint.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.check_rounded,
                      size: 42,
                      color: AppColors.mint,
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                const Text(
                  '가입이 완료되었습니다',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                Text(
                  m.greeting,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppColors.gray500,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 18),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.gray50,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _kv(
                        '회원 유형',
                        m.isBusiness ? '사업자회원 (${m.orgKind})' : '개인회원',
                      ),
                      _kv(
                        m.isBusiness ? (m.isLab ? '기공소명' : '병원명') : '이름',
                        m.name,
                      ),
                      if (m.isBusiness) _kv('사업자번호', m.bizNo ?? '-'),
                      _kv('연락처', m.phone),
                      _kv(
                        m.isBusiness ? '소재지' : '지역',
                        [
                          m.region.label,
                          m.addressDetail,
                        ].where((e) => e.isNotEmpty).join(' '),
                      ),
                      if (m.isBusiness) _kv('직책', m.role ?? '-'),
                      if (m.provider != null) _kv('연결 계정', m.provider!.label),
                    ],
                  ),
                ),
                const SizedBox(height: 22),
                FilledButton.icon(
                  onPressed: () => Navigator.pop(context, true),
                  icon: const Icon(Icons.arrow_forward_rounded),
                  label: const Text('홈으로 시작하기'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Text(
            k,
            style: const TextStyle(fontSize: 13, color: AppColors.gray500),
          ),
        ),
        Expanded(
          child: Text(
            v,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}
