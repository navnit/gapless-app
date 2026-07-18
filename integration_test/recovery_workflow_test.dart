import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/core/errors/app_failure.dart';
import 'package:integration_test/integration_test.dart';

import 'support/installed_editor_driver.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('missing and changed sources recover without discarding edits', (
    tester,
  ) async {
    final driver = InstalledEditorDriver(tester);
    addTearDown(driver.dispose);
    await driver.launch();
    final editedDuration = await driver.createSavedProject();

    await driver.makeSourceMissing();
    expect(await driver.restartForSourceIssue(), InstalledSourceIssue.missing);
    await driver.relocateSource(driver.relocatedSource);
    expect(driver.effectiveDurationUs, editedDuration);

    await driver.changeRelocatedSourceAndRestoreOriginal();
    expect(await driver.restartForSourceIssue(), InstalledSourceIssue.changed);
    await driver.relocateSource(driver.source);
    expect(driver.effectiveDurationUs, editedDuration);
  });

  testWidgets('failed destination preserves project and exports after retry', (
    tester,
  ) async {
    final driver = InstalledEditorDriver(tester);
    addTearDown(driver.dispose);
    await driver.launch();
    final editedDuration = await driver.createSavedProject();

    await driver.cancelAnalysisPreservingTimeline();
    expect(driver.effectiveDurationUs, editedDuration);
    await driver.cancelExportPreservingDestination();
    expect(driver.effectiveDurationUs, editedDuration);

    final failure = await driver.failExportToUnavailableDestination();
    expect(failure, isA<EngineContractFailure>());
    expect(driver.effectiveDurationUs, editedDuration);

    driver.restoreExportDestination();
    await driver.exportMp4();
    final probe = await driver.probeOutput();
    expect(probe.hasVideo, isTrue);
    expect(probe.hasAudio, isTrue);
    expect(
      (probe.durationUs - editedDuration).abs(),
      lessThanOrEqualTo(probe.frameDurationUs),
    );
  });
}
