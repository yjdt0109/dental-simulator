import '../widgets/brand_widgets.dart';

/// 가입 시 등록한 치과 정보
class ClinicProfile {
  const ClinicProfile({
    required this.clinicName,
    required this.bizNo,
    required this.phone,
    required this.zipCode,
    required this.address,
    required this.role,
    required this.provider,
  });
  final String clinicName;
  final String bizNo; // 사업자등록번호 (인증 완료된 값)
  final String phone; // 치과 연락처 (택배·기공소 연락용)
  final String zipCode; // 우편번호 5자리 (택배 발송용)
  final String address;
  final String role;
  final SocialProvider? provider;
}
