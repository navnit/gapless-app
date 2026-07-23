import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/features/update/application/update_coordinator.dart';
import 'package:gapless/features/update/domain/app_version.dart';
import 'package:gapless/features/update/domain/install_channel.dart';
import 'package:gapless/features/update/domain/release_info.dart';
import 'package:gapless/features/update/domain/update_checker_port.dart';
import 'package:gapless/features/update/domain/update_preferences_port.dart';
import 'package:gapless/features/update/domain/update_status.dart';

import '../support/fakes.dart';

ReleaseInfo _release(String v) => ReleaseInfo(
      version: AppVersion.tryParse(v)!,
      notes: '',
      htmlUrl: 'https://github.com/navnit/gapless-app/releases/tag/v$v',
    );

UpdateCoordinator _coordinator({
  required UpdateCheckerPort checker,
  UpdatePreferencesPort? prefs,
  DateTime? now,
}) =>
    UpdateCoordinator(
      checker: checker,
      detector: FakeDetector(InstallChannel.homebrew),
      preferences: prefs ?? MemoryPrefs(),
      currentVersion: AppVersion.tryParse('0.1.1')!,
      now: () => now ?? DateTime.fromMillisecondsSinceEpoch(1700000000000),
    );

void main() {
  test('launch check returns UpdateAvailable and records timestamp', () async {
    final prefs = MemoryPrefs();
    final result = await _coordinator(checker: FakeChecker(_release('0.2.0')), prefs: prefs).checkOnLaunch();
    expect(result, isA<UpdateAvailable>());
    expect(prefs.data.lastCheckedAt, isNotNull);
  });

  test('launch check is skipped within the throttle window', () async {
    final now = DateTime.fromMillisecondsSinceEpoch(1700000000000);
    final prefs = MemoryPrefs(UpdatePreferencesData(lastCheckedAt: now.subtract(const Duration(hours: 1))));
    final checker = FakeChecker(_release('0.2.0'));
    final result = await _coordinator(checker: checker, prefs: prefs, now: now).checkOnLaunch();
    expect(result, isNull);
    expect(checker.calls, 0);
  });

  test('launch check short-circuits when auto-check disabled', () async {
    final prefs = MemoryPrefs(const UpdatePreferencesData(autoCheckEnabled: false));
    final checker = FakeChecker(_release('0.2.0'));
    expect(await _coordinator(checker: checker, prefs: prefs).checkOnLaunch(), isNull);
    expect(checker.calls, 0);
  });

  test('launch check suppresses a skipped version but manual still reports it', () async {
    final prefs = MemoryPrefs(const UpdatePreferencesData(skippedVersion: '0.2.0'));
    expect(await _coordinator(checker: FakeChecker(_release('0.2.0')), prefs: prefs).checkOnLaunch(), isNull);
    final manual = await _coordinator(checker: FakeChecker(_release('0.2.0')), prefs: prefs).checkManually();
    expect(manual, isA<UpdateAvailable>());
  });

  test('up-to-date when latest is not newer', () async {
    expect(await _coordinator(checker: FakeChecker(_release('0.1.1'))).checkManually(), isA<UpToDate>());
  });

  test('launch failure is swallowed, manual failure surfaces reason', () async {
    final launch = await _coordinator(
      checker: FakeChecker(const UpdateCheckException(CheckFailureReason.rateLimited)),
    ).checkOnLaunch();
    expect(launch, isNull);
    final manual = await _coordinator(
      checker: FakeChecker(const UpdateCheckException(CheckFailureReason.rateLimited)),
    ).checkManually();
    expect(manual, isA<CheckFailed>());
    expect((manual as CheckFailed).reason, CheckFailureReason.rateLimited);
  });
}
