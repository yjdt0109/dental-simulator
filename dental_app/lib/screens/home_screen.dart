import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../models/member.dart';
import '../simulator/simulator_screen.dart';
import '../widgets/brand_widgets.dart';
import 'login_screen.dart';

// -----------------------------------------------------------------------------
// 2단계: 홈 허브 (로그인 → 홈 → 서비스 선택)
//   개인회원  : B&A 치과 시뮬레이터(일반) · 주위 치과 추천
//   사업자회원: B&A 치과 시뮬레이터 전문가용 · 주위 기공소 추천
// -----------------------------------------------------------------------------
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.member});
  final MemberProfile member;

  void _openSimulator(BuildContext context, {bool records = false}) {
    Navigator.of(context).push(
      smoothRoute(
        SimulatorHomeScreen(
          profile: member.toClinicProfile(),
          mode: member.simMode,
          openRecords: records,
        ),
      ),
    );
  }

  void _openNearby(BuildContext context) {
    final lab = member.isBusiness;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        icon: Icon(
          lab ? Icons.precision_manufacturing_outlined : Icons.place_outlined,
          color: AppColors.blue,
          size: 36,
        ),
        title: Text(lab ? '주위 기공소 추천' : '주위 치과 추천'),
        content: Text(
          '${member.region.label} 주변의 ${lab ? '치과기공소' : '치과'}를 추천해 드리는 서비스를 준비하고 있습니다.\n\n'
          '제휴 ${lab ? '기공소' : '치과'} 정보가 등록되면 이 지역부터 먼저 보여 드릴게요.',
          style: const TextStyle(height: 1.55),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('확인'),
          ),
        ],
      ),
    );
  }

  void _logout(BuildContext context) {
    Navigator.of(context)
        .pushAndRemoveUntil(smoothRoute(const LoginScreen()), (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    final m = member;
    final w = MediaQuery.sizeOf(context).width;
    final phone = w < 600;
    final cards = <Widget>[
      _ServiceCard(
        primary: true,
        icon: Icons.auto_awesome_rounded,
        badge: m.isBusiness ? 'PRO' : null,
        title: m.isBusiness ? 'B&A 치과 시뮬레이터\n전문가용' : 'B&A 치과 시뮬레이터',
        desc: m.isBusiness
            ? '환자 상담용 Before & After 시뮬레이션 · 자동 QA · 프롬프트 보관함 · 상담실 PC 연결'
            : '내 치아 사진으로 치료 후 모습을 미리 확인해 보세요',
        action: '시작하기',
        onTap: () => _openSimulator(context),
      ),
      // 🗂 예전에 변환한 환자 기록을 시뮬레이터로 (모두 또는 사진 한 장씩)
      _ServiceCard(
        icon: Icons.folder_open_outlined,
        title: '시뮬레이터 불러오기',
        desc: '저장된 환자 기록에서 원본·변환 결과·미소 사진을 한 장씩 불러와 비교·상담해요',
        action: '기록 열기',
        onTap: () => _openSimulator(context, records: true),
      ),
      _ServiceCard(
        icon: m.isBusiness
            ? Icons.precision_manufacturing_outlined
            : Icons.place_outlined,
        title: m.isBusiness ? '주위 기공소 추천' : '주위 치과 추천',
        desc: '${m.region.short} 주변 ${m.isBusiness ? '치과기공소' : '치과'} 찾기',
        action: '보기',
        onTap: () => _openNearby(context),
      ),
      const _ServiceCard(
        icon: Icons.add_rounded,
        title: '추가 서비스 준비 중',
        desc: '새로운 서비스가 곧 추가됩니다',
      ),
    ];
    final cols = w >= 1000
        ? 3
        : w >= 600
        ? 2
        : 1;
    return Scaffold(
      backgroundColor: AppColors.gray50,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        titleSpacing: 16,
        title: const Row(
          children: [
            AppLogo(size: 34),
            SizedBox(width: 10),
            Flexible(
              child: Text(
                'B&A 홈',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: AppColors.blueDeep,
                ),
              ),
            ),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: phone
                ? IconButton(
                    tooltip: '로그아웃',
                    onPressed: () => _logout(context),
                    icon: const Icon(
                      Icons.logout_rounded,
                      color: AppColors.blue,
                    ),
                  )
                : OutlinedButton.icon(
                    onPressed: () => _logout(context),
                    icon: const Icon(Icons.logout_rounded, size: 18),
                    label: const Text('로그아웃'),
                  ),
          ),
        ],
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: AppColors.gray200),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            phone ? 16 : 28,
            phone ? 18 : 28,
            phone ? 16 : 28,
            32,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1100),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 인사
                  Container(
                    padding: EdgeInsets.all(phone ? 20 : 28),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF1A85F0), AppColors.blueDeep],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            m.isBusiness
                                ? '사업자회원 · ${m.orgKind ?? '치과'}${m.demo ? ' · 체험' : ''}'
                                : '개인회원${m.demo ? ' · 체험' : ''}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          m.greeting,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: phone ? 22 : 28,
                            height: 1.3,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            const Icon(
                              Icons.place_outlined,
                              color: Colors.white70,
                              size: 16,
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                m.region.label,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 13.5,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 22),
                  const Text(
                    '서비스',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: AppColors.ink,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _Grid(cols: cols, children: cards),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 같은 줄의 카드 높이를 맞추는 간단한 격자
class _Grid extends StatelessWidget {
  const _Grid({required this.cols, required this.children});
  final int cols;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += cols) {
      if (rows.isNotEmpty) rows.add(const SizedBox(height: 14));
      rows.add(
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var j = 0; j < cols; j++) ...[
                if (j > 0) const SizedBox(width: 14),
                Expanded(
                  child: i + j < children.length
                      ? children[i + j]
                      : const SizedBox(),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return Column(children: rows);
  }
}

class _ServiceCard extends StatelessWidget {
  const _ServiceCard({
    required this.icon,
    required this.title,
    required this.desc,
    this.action,
    this.onTap,
    this.primary = false,
    this.badge,
  });
  final IconData icon;
  final String title, desc;
  final String? action, badge;
  final VoidCallback? onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final soon = onTap == null;
    return Material(
      color: soon ? AppColors.gray50 : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: primary ? AppColors.blue : AppColors.gray200,
          width: primary ? 1.6 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: soon
                          ? AppColors.gray100
                          : primary
                          ? AppColors.blue
                          : AppColors.blueSoft,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(
                      icon,
                      color: soon
                          ? AppColors.gray500
                          : primary
                          ? Colors.white
                          : AppColors.blue,
                    ),
                  ),
                  const Spacer(),
                  if (badge != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.blueDeep,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        badge!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                title,
                style: TextStyle(
                  fontSize: 17,
                  height: 1.3,
                  fontWeight: FontWeight.w800,
                  color: soon ? AppColors.gray500 : AppColors.ink,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                desc,
                style: const TextStyle(
                  fontSize: 13.5,
                  height: 1.45,
                  color: AppColors.gray500,
                ),
              ),
              if (action != null) ...[
                const SizedBox(height: 14),
                const Spacer(),
                Row(
                  children: [
                    Text(
                      action!,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        color: AppColors.blue,
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(
                      Icons.arrow_forward_rounded,
                      size: 18,
                      color: AppColors.blue,
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
