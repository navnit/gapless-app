import 'package:gapless/features/update/domain/app_version.dart';
import 'package:gapless/features/update/domain/channel_detector_port.dart';
import 'package:gapless/features/update/domain/update_checker_port.dart';
import 'package:gapless/features/update/domain/update_preferences_port.dart';
import 'package:gapless/features/update/domain/update_status.dart';

final class UpdateCoordinator {
  UpdateCoordinator({
    required this.checker,
    required this.detector,
    required this.preferences,
    required this.currentVersion,
    required this.now,
    this.throttle = const Duration(hours: 24),
  });

  final UpdateCheckerPort checker;
  final ChannelDetectorPort detector;
  final UpdatePreferencesPort preferences;
  final AppVersion currentVersion;
  final DateTime Function() now;
  final Duration throttle;

  Future<UpdateAvailable?> checkOnLaunch() async {
    final prefs = await preferences.load();
    if (!prefs.autoCheckEnabled) return null;
    final last = prefs.lastCheckedAt;
    if (last != null && now().difference(last) < throttle) return null;
    try {
      final status = await _check();
      await preferences.save(prefs.copyWith(lastCheckedAt: now()));
      if (status is UpdateAvailable &&
          status.release.version.toString() != prefs.skippedVersion) {
        return status;
      }
      return null;
    } on Object {
      return null;
    }
  }

  Future<UpdateStatus> checkManually() async {
    final prefs = await preferences.load();
    try {
      final status = await _check();
      await preferences.save(prefs.copyWith(lastCheckedAt: now()));
      return status;
    } on UpdateCheckException catch (error) {
      return CheckFailed(error.reason);
    } on Object {
      // A non-check failure (e.g. preferences.save) must not throw out of the
      // manual path into the UI handler; treat as a network-class failure.
      return const CheckFailed(CheckFailureReason.network);
    }
  }

  Future<void> skipVersion(String version) async {
    final prefs = await preferences.load();
    await preferences.save(prefs.copyWith(skippedVersion: version));
  }

  Future<void> setAutoCheckEnabled(bool enabled) async {
    final prefs = await preferences.load();
    await preferences.save(prefs.copyWith(autoCheckEnabled: enabled));
  }

  Future<bool> autoCheckEnabled() async =>
      (await preferences.load()).autoCheckEnabled;

  Future<UpdateStatus> _check() async {
    final release = await checker.fetchLatest();
    if (!release.version.isNewerThan(currentVersion)) return const UpToDate();
    final channel = await detector.detect();
    return UpdateAvailable(
      release: release,
      channel: channel,
      current: currentVersion,
    );
  }
}
