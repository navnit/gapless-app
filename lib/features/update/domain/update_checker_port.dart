import 'package:gapless/features/update/domain/release_info.dart';
import 'package:gapless/features/update/domain/update_status.dart';

abstract interface class UpdateCheckerPort {
  Future<ReleaseInfo> fetchLatest();
}

final class UpdateCheckException implements Exception {
  const UpdateCheckException(this.reason);

  final CheckFailureReason reason;
}
