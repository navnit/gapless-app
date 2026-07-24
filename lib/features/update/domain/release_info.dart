import 'package:gapless/features/update/domain/app_version.dart';

final class ReleaseInfo {
  const ReleaseInfo({
    required this.version,
    required this.notes,
    required this.htmlUrl,
    this.dmgAssetUrl,
  });

  final AppVersion version;
  final String notes;
  final String htmlUrl;
  final String? dmgAssetUrl;
}
