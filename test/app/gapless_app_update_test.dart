import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/app/app_dependencies.dart';
import 'package:gapless/app/gapless_app.dart';
import 'package:gapless/features/update/application/app_update_services.dart';
import 'package:gapless/features/update/application/update_coordinator.dart';
import 'package:gapless/features/update/domain/app_version.dart';
import 'package:gapless/features/update/domain/install_channel.dart';
import 'package:gapless/features/update/domain/release_info.dart';
import 'package:gapless/features/update/domain/update_preferences_port.dart';
import '../features/update/support/fakes.dart' as fakes;

void main() {
  testWidgets('shows the update banner after a launch check', (tester) async {
    // debugDefaultTargetPlatformOverride must be set and reset within this
    // same test body: Flutter's TestWidgetsFlutterBinding runs its
    // debugAssertAllFoundationVarsUnset invariant check immediately after the
    // test body completes but before package:test's tearDown() callbacks
    // run, so resetting via a separate tearDown() is too late and trips
    // "The value of a foundation debug variable was changed by the test."
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final coordinator = UpdateCoordinator(
        checker: fakes.FakeChecker(ReleaseInfo(
          version: AppVersion.tryParse('0.2.0')!,
          notes: '',
          htmlUrl: 'https://github.com/navnit/gapless-app/releases/tag/v0.2.0',
        )),
        detector: fakes.FakeDetector(InstallChannel.homebrew),
        preferences: fakes.MemoryPrefs(const UpdatePreferencesData()),
        currentVersion: AppVersion.tryParse('0.1.1')!,
        now: () => DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
      final deps = AppDependencies(
        editorViewModelFactory: null, // required param; null → EditorViewModel.empty()
        update: AppUpdateServices(coordinator: coordinator),
      );
      await tester.pumpWidget(GaplessApp(dependencies: deps));
      await tester.pumpAndSettle();
      expect(find.textContaining('0.2.0 is available'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
