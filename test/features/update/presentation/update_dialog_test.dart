import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/features/update/domain/app_version.dart';
import 'package:gapless/features/update/domain/install_channel.dart';
import 'package:gapless/features/update/domain/release_info.dart';
import 'package:gapless/features/update/domain/update_status.dart';
import 'package:gapless/features/update/presentation/update_dialog.dart';

UpdateAvailable _status(InstallChannel channel) => UpdateAvailable(
  release: ReleaseInfo(
    version: AppVersion.tryParse('0.2.0')!,
    notes: 'What is new',
    htmlUrl: 'https://github.com/navnit/gapless-app/releases/tag/v0.2.0',
    dmgAssetUrl:
        'https://github.com/navnit/gapless-app/releases/download/v0.2.0/Gapless-0.2.0-macos-arm64-UNNOTARIZED.dmg',
  ),
  channel: channel,
  current: AppVersion.tryParse('0.1.1')!,
);

Future<void> _pump(WidgetTester tester, InstallChannel channel) =>
    tester.pumpWidget(
      MaterialApp(
        home: UpdateDialog(
          status: _status(channel),
          onSkip: () {},
          onClose: () {},
          openUrl: (_) async {},
          copyText: (_) async {},
        ),
      ),
    );

void main() {
  testWidgets('homebrew shows the brew command', (tester) async {
    await _pump(tester, InstallChannel.homebrew);
    expect(find.text('brew upgrade --cask gapless'), findsOneWidget);
    expect(find.text('Download'), findsNothing);
  });

  testWidgets('directDmg shows a Download action', (tester) async {
    await _pump(tester, InstallChannel.directDmg);
    expect(find.text('Download'), findsOneWidget);
    expect(find.textContaining('Replace'), findsOneWidget);
  });

  testWidgets('unknown channel is treated like directDmg', (tester) async {
    await _pump(tester, InstallChannel.unknown);
    expect(find.text('Download'), findsOneWidget);
  });
}
