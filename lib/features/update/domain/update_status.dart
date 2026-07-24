import 'package:gapless/features/update/domain/app_version.dart';
import 'package:gapless/features/update/domain/install_channel.dart';
import 'package:gapless/features/update/domain/release_info.dart';

enum CheckFailureReason { rateLimited, network }

sealed class UpdateStatus {
  const UpdateStatus();
}

final class UpToDate extends UpdateStatus {
  const UpToDate();
}

final class UpdateAvailable extends UpdateStatus {
  const UpdateAvailable({
    required this.release,
    required this.channel,
    required this.current,
  });

  final ReleaseInfo release;
  final InstallChannel channel;
  final AppVersion current;
}

final class CheckFailed extends UpdateStatus {
  const CheckFailed(this.reason);

  final CheckFailureReason reason;
}
