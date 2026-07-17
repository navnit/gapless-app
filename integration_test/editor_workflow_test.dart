import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _nativeEnabled = bool.fromEnvironment('GAPLESS_NATIVE_E2E');
const _fixtureVideoPath = String.fromEnvironment('GAPLESS_E2E_VIDEO');
const _projectPath = String.fromEnvironment('GAPLESS_E2E_PROJECT');
const _outputPath = String.fromEnvironment('GAPLESS_E2E_OUTPUT');
const _driverAvailable = false;
const _skipReason = 'Task 11B installed-app driver is not composed';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'installed import analyze override autosave reopen and MP4 export '
    '(skipped: $_skipReason)',
    (_) async {
      final driver = _installedDriver();
      final fixture = Uri.file(_fixtureVideoPath);
      final project = Uri.file(_projectPath);
      final output = Uri.file(_outputPath);

      await driver.launchInstalledApp();
      await driver.importVideo(fixture);
      await driver.waitForPinnedEngineAnalysis();
      final expectedDurationUs = await driver.toggleFirstDetectedCut();
      await driver.waitForAutosave();
      await driver.saveAs(project);
      await driver.restartAndReopen(project);
      await driver.exportMp4(output);
      final probe = await driver.probe(output);

      expect(probe.hasVideo, isTrue);
      expect(probe.hasAudio, isTrue);
      expect(probe.durationUs, expectedDurationUs);
    },
    skip: _mustSkipNativeContract(),
  );
}

abstract interface class _InstalledEditorDriver {
  Future<void> launchInstalledApp();
  Future<void> importVideo(Uri fixture);
  Future<void> waitForPinnedEngineAnalysis();
  Future<int> toggleFirstDetectedCut();
  Future<void> waitForAutosave();
  Future<void> saveAs(Uri project);
  Future<void> restartAndReopen(Uri project);
  Future<void> exportMp4(Uri destination);
  Future<_MediaProbe> probe(Uri media);
}

final class _MediaProbe {
  const _MediaProbe({
    required this.hasVideo,
    required this.hasAudio,
    required this.durationUs,
  });

  final bool hasVideo;
  final bool hasAudio;
  final int durationUs;
}

_InstalledEditorDriver _installedDriver() => throw UnsupportedError(
  'Task 11B must compose a public installed-app driver backed by the real '
  'bundled engine, native file selection, restart/reopen, and media probing.',
);

bool _mustSkipNativeContract() =>
    !_nativeEnabled ||
    _fixtureVideoPath.isEmpty ||
    _projectPath.isEmpty ||
    _outputPath.isEmpty ||
    !_driverAvailable;
