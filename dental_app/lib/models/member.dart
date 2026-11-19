import '../widgets/brand_widgets.dart' show SocialProvider;
import 'clinic_profile.dart';

/// 회원 유형
enum MemberType { personal, business }

/// 시뮬레이터 진입 경로: 개인회원(일반) / 사업자회원(전문가용)
/// 지금은 같은 화면이 열리지만, 전문가용 기능을 따로 고도화할 때 이 값으로 나눕니다.
enum SimMode { general, expert }

/// 시/구/동 단위 정적 주소 (GPS 위치정보를 쓰지 않음 → 위치정보법상 위치정보 수집 아님)
class Region {
  const Region(this.sido, this.sigungu, this.dong);
  final String sido; // 시·도
  final String sigungu; // 시·군·구
  final String dong; // 읍·면·동
  String get label => '$sido $sigungu $dong';
  String get short => '$sigungu $dong';
}

/// 로그인한 회원 정보 (개인/사업자 공통)
class MemberProfile {
  const MemberProfile({
    required this.type,
    required this.name,
    required this.phone,
    required this.region,
    this.bizNo,
    this.role,
    this.orgKind,
    this.addressDetail = '',
    this.provider,
    this.demo = false,
  });

  final MemberType type;

  /// 개인: 회원 이름 / 사업자: 병원명 또는 기공소명
  final String name;
  final String phone;

  /// 개인: 거주 지역 / 사업자: 소재지
  final Region region;

  // ---- 사업자회원만 ----
  final String? bizNo; // 사업자등록번호 (000-00-00000)
  final String? role; // 원장, 실장, 치과위생사, 치과기공사 …
  final String? orgKind; // '치과' 또는 '치과기공소'
  final String addressDetail; // 상세 주소 (선택)

  final SocialProvider? provider;
  final bool demo; // 체험 로그인

  bool get isBusiness => type == MemberType.business;

  /// 홈 화면 인사말
  String get greeting =>
      isBusiness ? '$name (${role ?? '원장'})님, 환영합니다' : '안녕하세요, $name님';

  /// 시뮬레이터 모드 (개인: 일반 / 사업자: 전문가용)
  SimMode get simMode => isBusiness ? SimMode.expert : SimMode.general;
  bool get isLab => orgKind == '치과기공소';

  /// 시뮬레이터 상단에 보이는 정보 (기존 시뮬레이터 화면이 쓰는 형식)
  ClinicProfile toClinicProfile() => ClinicProfile(
    clinicName: isBusiness ? name : '$name 님',
    bizNo: bizNo ?? '-',
    phone: phone,
    zipCode: '-',
    address: [region.label, addressDetail].where((e) => e.isNotEmpty).join(' '),
    role: isBusiness ? (role ?? '원장') : '개인회원',
    provider: provider,
  );

  /// 체험 로그인용
  static const demoPersonal = MemberProfile(
    type: MemberType.personal,
    name: '김민지',
    phone: '010-1234-5678',
    region: Region('서울특별시', '강남구', '역삼동'),
    demo: true,
  );
  static const demoBusiness = MemberProfile(
    type: MemberType.business,
    name: '미소드림치과',
    phone: '02-1234-5678',
    region: Region('서울특별시', '강남구', '역삼동'),
    bizNo: '123-45-67890',
    role: '원장',
    orgKind: '치과',
    demo: true,
  );
}
