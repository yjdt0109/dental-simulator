import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../models/member.dart';
import '../widgets/brand_widgets.dart';
import 'home_screen.dart';
import 'signup_screen.dart';

// -----------------------------------------------------------------------------
// 1단계: 로그인 (개인회원 / 사업자회원 탭 분리)
// -----------------------------------------------------------------------------
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _id = TextEditingController();
  final _pw = TextEditingController();
  bool _obscure = true;
  bool _keep = true;
  bool _loading = false;
  MemberType _type = MemberType.personal;
  bool get _biz => _type == MemberType.business;

  @override
  void dispose() {
    _id.dispose();
    _pw.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    await Future<void>.delayed(const Duration(milliseconds: 900)); // 가상 서버 응답
    if (!mounted) return;
    setState(() => _loading = false);
    // 프로토타입: 서버가 없으므로 체험 회원 정보에 입력한 아이디를 이름으로 사용
    final id = _id.text.trim();
    final d = _biz ? MemberProfile.demoBusiness : MemberProfile.demoPersonal;
    _goHome(
      MemberProfile(
        type: d.type,
        name: id,
        phone: d.phone,
        region: d.region,
        bizNo: d.bizNo,
        role: d.role,
        orgKind: d.orgKind,
      ),
    );
  }

  void _goHome(MemberProfile m) {
    Navigator.of(context)
        .pushAndRemoveUntil(smoothRoute(HomeScreen(member: m)), (_) => false);
  }

  void _signup([SocialProvider? p]) {
    Navigator.of(context)
        .push(smoothRoute(SignupScreen(type: _type, provider: p)));
  }

  Future<void> _social(SocialProvider p) async {
    // 가상 소셜 인증: 잠깐 인증 중 창을 보여준 뒤 추가 정보 등록 화면으로 이동
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _SocialAuthDialog(provider: p),
    );
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    if (!mounted) return;
    Navigator.of(context).pop();
    _signup(p);
  }

  void _notReady(String what) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('$what 기능은 서버 연동 후 사용할 수 있습니다.'),
          width: MediaQuery.sizeOf(context).width > 600 ? 400 : null,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 960;
    return AuthShell(
      child: Form(
        key: _formKey,
        child: AutofillGroup(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 상단: 로고 + 타이틀
              Center(child: AppLogo(size: wide ? 56 : 64)),
              const SizedBox(height: 18),
              const Text(
                'Before & After\n치과 시뮬레이터',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 24,
                  height: 1.3,
                  fontWeight: FontWeight.w800,
                  color: AppColors.ink,
                ),
              ),
              const SizedBox(height: 22),
              // 개인 / 사업자 탭
              _TypeTabs(
                value: _type,
                onChanged: (t) => setState(() {
                  _type = t;
                  _formKey.currentState?.reset();
                }),
              ),
              const SizedBox(height: 10),
              Text(
                _biz ? '치과·치과기공소 사업자 계정으로 로그인하세요' : '개인 계정으로 로그인하세요',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.gray500, fontSize: 14),
              ),
              const SizedBox(height: 20),

              // 중앙: 아이디 / 비밀번호
              TextFormField(
                controller: _id,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.username],
                decoration: const InputDecoration(
                  hintText: '아이디',
                  prefixIcon: Icon(Icons.person_outline_rounded),
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? '아이디를 입력해 주세요.' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _pw,
                obscureText: _obscure,
                textInputAction: TextInputAction.done,
                autofillHints: const [AutofillHints.password],
                onFieldSubmitted: (_) => _login(),
                decoration: InputDecoration(
                  hintText: '비밀번호',
                  prefixIcon: const Icon(Icons.lock_outline_rounded),
                  suffixIcon: IconButton(
                    tooltip: _obscure ? '비밀번호 보기' : '비밀번호 숨기기',
                    onPressed: () => setState(() => _obscure = !_obscure),
                    icon: Icon(
                      _obscure
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                    ),
                  ),
                ),
                validator: (v) =>
                    (v == null || v.isEmpty) ? '비밀번호를 입력해 주세요.' : null,
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  SizedBox(
                    width: 36,
                    height: 36,
                    child: Checkbox(
                      value: _keep,
                      onChanged: (v) => setState(() => _keep = v ?? false),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(5),
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => setState(() => _keep = !_keep),
                    child: const Text(
                      '로그인 상태 유지',
                      style: TextStyle(fontSize: 13, color: AppColors.ink),
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => _notReady('비밀번호 찾기'),
                    child: const Text(
                      '비밀번호 찾기',
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // 로그인 버튼
              FilledButton(
                onPressed: _loading ? null : _login,
                style: FilledButton.styleFrom(
                  disabledBackgroundColor: AppColors.blue.withValues(
                    alpha: 0.6,
                  ),
                ),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: _loading
                      ? const SizedBox(
                          key: ValueKey('l'),
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.6,
                            color: Colors.white,
                          ),
                        )
                      : Row(
                          key: ValueKey('t$_type'),
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.login_rounded, size: 20),
                            const SizedBox(width: 8),
                            Text(_biz ? '사업자회원 로그인' : '개인회원 로그인'),
                          ],
                        ),
                ),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () => _goHome(
                  _biz
                      ? MemberProfile.demoBusiness
                      : MemberProfile.demoPersonal,
                ),
                icon: const Icon(Icons.play_circle_outline_rounded, size: 20),
                label: Text(_biz ? '사업자회원 체험 로그인' : '개인회원 체험 로그인'),
              ),
              const SizedBox(height: 24),

              // 하단: 간편 로그인 / 회원가입
              const Row(
                children: [
                  Expanded(child: Divider(color: AppColors.gray200)),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      '간편 로그인 / 회원가입',
                      style: TextStyle(fontSize: 13, color: AppColors.gray500),
                    ),
                  ),
                  Expanded(child: Divider(color: AppColors.gray200)),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  for (final p in SocialProvider.values) ...[
                    if (p != SocialProvider.google) const SizedBox(width: 10),
                    Expanded(
                      child: SocialButton(provider: p, onTap: () => _social(p)),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 20),
              Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text(
                    '처음이신가요?',
                    style: TextStyle(fontSize: 13, color: AppColors.gray500),
                  ),
                  TextButton(
                    onPressed: _signup,
                    child: Text(
                      _biz ? '사업자회원 가입' : '개인회원 가입',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SocialAuthDialog extends StatelessWidget {
  const _SocialAuthDialog({required this.provider});
  final SocialProvider provider;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: provider.bg,
                  shape: BoxShape.circle,
                  border: provider == SocialProvider.google
                      ? Border.all(color: AppColors.gray200)
                      : null,
                ),
                alignment: Alignment.center,
                child: SocialLogo(provider, size: 26),
              ),
              const SizedBox(height: 18),
              Text(
                '${provider.label} 계정 확인 중',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                '(프로토타입: 가상 인증)',
                style: TextStyle(fontSize: 12, color: AppColors.gray500),
              ),
              const SizedBox(height: 20),
              const SizedBox(
                width: 160,
                child: LinearProgressIndicator(
                  minHeight: 4,
                  borderRadius: BorderRadius.all(Radius.circular(4)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TypeTabs extends StatelessWidget {
  const _TypeTabs({required this.value, required this.onChanged});
  final MemberType value;
  final ValueChanged<MemberType> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget tab(MemberType t, IconData icon, String label) {
      final on = value == t;
      return Expanded(
        child: Semantics(
          selected: on,
          button: true,
          child: Material(
            color: on ? Colors.white : Colors.transparent,
            elevation: on ? 1 : 0,
            borderRadius: BorderRadius.circular(11),
            child: InkWell(
              borderRadius: BorderRadius.circular(11),
              onTap: () => onChanged(t),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      icon,
                      size: 19,
                      color: on ? AppColors.blue : AppColors.gray500,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: on ? FontWeight.w800 : FontWeight.w600,
                        color: on ? AppColors.blueDeep : AppColors.gray500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.gray100,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          tab(MemberType.personal, Icons.person_outline_rounded, '개인회원'),
          const SizedBox(width: 4),
          tab(MemberType.business, Icons.business_outlined, '사업자회원'),
        ],
      ),
    );
  }
}
