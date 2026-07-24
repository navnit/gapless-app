import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/features/update/domain/app_version.dart';
import 'package:gapless/features/update/domain/install_channel.dart';
import 'package:gapless/features/update/domain/release_info.dart';
import 'package:gapless/features/update/domain/update_status.dart';

void main() {
  test('UpdateAvailable carries release, channel, and current version', () {
    final release = ReleaseInfo(
      version: AppVersion.tryParse('0.2.0')!,
      notes: 'notes',
      htmlUrl: 'https://github.com/navnit/gapless-app/releases/tag/v0.2.0',
    );
    final UpdateStatus status = UpdateAvailable(
      release: release,
      channel: InstallChannel.homebrew,
      current: AppVersion.tryParse('0.1.1')!,
    );
    expect(status, isA<UpdateAvailable>());
    expect((status as UpdateAvailable).channel, InstallChannel.homebrew);
    expect(status.release.dmgAssetUrl, isNull);
  });

  test('failure reasons are distinct', () {
    expect(
      const CheckFailed(CheckFailureReason.rateLimited).reason,
      isNot(const CheckFailed(CheckFailureReason.network).reason),
    );
  });
}
