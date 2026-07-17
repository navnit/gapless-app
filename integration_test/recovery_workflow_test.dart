import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _nativeEnabled = bool.fromEnvironment('GAPLESS_NATIVE_E2E');
const _fixtureVideoPath = String.fromEnvironment('GAPLESS_E2E_VIDEO');
const _relocatedVideoPath = String.fromEnvironment(
  'GAPLESS_E2E_RELOCATED_VIDEO',
);
const _projectPath = String.fromEnvironment('GAPLESS_E2E_PROJECT');
const _outputPath = String.fromEnvironment('GAPLESS_E2E_OUTPUT');
const _recoveryOutputPath = String.fromEnvironment(
  'GAPLESS_E2E_RECOVERY_OUTPUT',
);
const _driverAvailable = false;
const _skipReason = 'Task 11B installed-app recovery driver is not composed';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('missing and changed sources require verified relocation '
      '(skipped: $_skipReason)', (_) async {
    final driver = _recoveryDriver();
    final source = Uri.file(_fixtureVideoPath);
    final relocated = Uri.file(_relocatedVideoPath);
    final project = Uri.file(_projectPath);

    await driver.launchInstalledApp();
    await driver.createSavedProject(source: source, project: project);
    await driver.makeSourceMissing();
    expect(
      await driver.restartAndWaitForSourceIssue(project),
      _SourceIssue.missing,
    );
    await driver.relocateSource(relocated);
    expect(await driver.isEditorReady(), isTrue);

    await driver.replaceSourceWithChangedBytes();
    expect(
      await driver.restartAndWaitForSourceIssue(project),
      _SourceIssue.changed,
    );
    await driver.relocateSource(source);
    expect(await driver.isEditorReady(), isTrue);
  }, skip: _mustSkipNativeContract());

  testWidgets(
    'cancelled analysis and export preserve prior timeline and destination '
    '(skipped: $_skipReason)',
    (_) async {
      final driver = _recoveryDriver();
      final source = Uri.file(_fixtureVideoPath);
      final project = Uri.file(_projectPath);
      final destination = Uri.file(_outputPath);

      await driver.launchInstalledApp();
      await driver.createSavedProject(source: source, project: project);
      final timelineBefore = await driver.timelineDigest();
      await driver.startAndCancelAnalysis();
      expect(await driver.timelineDigest(), timelineBefore);

      await driver.seedExistingDestination(destination);
      final destinationBefore = await driver.fileDigest(destination);
      await driver.startAndCancelExport(destination);
      expect(await driver.fileDigest(destination), destinationBefore);
    },
    skip: _mustSkipNativeContract(),
  );

  testWidgets('failed destination offers recovery and exports to a new MP4 '
      '(skipped: $_skipReason)', (_) async {
    final driver = _recoveryDriver();
    final source = Uri.file(_fixtureVideoPath);
    final project = Uri.file(_projectPath);
    final failedDestination = Uri.file(_outputPath);
    final recoveryDestination = Uri.file(_recoveryOutputPath);

    await driver.launchInstalledApp();
    await driver.createSavedProject(source: source, project: project);
    await driver.failNextDestinationWrite(failedDestination);
    await driver.exportMp4(failedDestination);
    expect(
      await driver.visibleRecoveryAction(),
      _RecoveryAction.chooseDestination,
    );

    await driver.exportMp4(recoveryDestination);
    final probe = await driver.probe(recoveryDestination);
    expect(probe.hasVideo, isTrue);
    expect(probe.durationUs, await driver.effectiveDurationUs());
  }, skip: _mustSkipNativeContract());
}

enum _SourceIssue { missing, changed }

enum _RecoveryAction { chooseDestination }

abstract interface class _InstalledRecoveryDriver {
  Future<void> launchInstalledApp();
  Future<void> createSavedProject({required Uri source, required Uri project});
  Future<void> makeSourceMissing();
  Future<void> replaceSourceWithChangedBytes();
  Future<_SourceIssue> restartAndWaitForSourceIssue(Uri project);
  Future<void> relocateSource(Uri source);
  Future<bool> isEditorReady();
  Future<String> timelineDigest();
  Future<void> startAndCancelAnalysis();
  Future<void> seedExistingDestination(Uri destination);
  Future<String> fileDigest(Uri file);
  Future<void> startAndCancelExport(Uri destination);
  Future<void> failNextDestinationWrite(Uri destination);
  Future<void> exportMp4(Uri destination);
  Future<_RecoveryAction> visibleRecoveryAction();
  Future<_MediaProbe> probe(Uri media);
  Future<int> effectiveDurationUs();
}

final class _MediaProbe {
  const _MediaProbe({required this.hasVideo, required this.durationUs});

  final bool hasVideo;
  final int durationUs;
}

_InstalledRecoveryDriver _recoveryDriver() => throw UnsupportedError(
  'Task 11B must compose a public installed-app recovery driver backed by '
  'real filesystem faults, the bundled engine, restart/reopen, and probing.',
);

bool _mustSkipNativeContract() =>
    !_nativeEnabled ||
    _fixtureVideoPath.isEmpty ||
    _relocatedVideoPath.isEmpty ||
    _projectPath.isEmpty ||
    _outputPath.isEmpty ||
    _recoveryOutputPath.isEmpty ||
    !_driverAvailable;
