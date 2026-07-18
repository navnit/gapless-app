import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/installed_editor_driver.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'import analyze override save reopen and export',
    (tester) async {
      final app = InstalledEditorDriver(tester);
      addTearDown(app.dispose);

      await app.launch();
      await app.openVideo();
      await app.waitForAnalysisReady();
      final expectedDurationUs = await app.toggleFirstCut();
      await app.waitForAutosave();
      await app.saveAs();
      await app.restartAndReopen();
      await app.exportMp4();
      final probe = await app.probeOutput();

      expect(probe.hasVideo, isTrue);
      expect(probe.hasAudio, isTrue);
      expect(
        probe.durationUs,
        closeTo(expectedDurationUs, probe.frameDurationUs),
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
