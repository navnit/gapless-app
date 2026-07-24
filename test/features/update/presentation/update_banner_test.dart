import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/features/update/domain/app_version.dart';
import 'package:gapless/features/update/domain/install_channel.dart';
import 'package:gapless/features/update/domain/release_info.dart';
import 'package:gapless/features/update/domain/update_status.dart';
import 'package:gapless/features/update/presentation/update_banner.dart';

void main() {
  testWidgets('shows the new version and fires View', (tester) async {
    var viewed = false;
    final status = UpdateAvailable(
      release: ReleaseInfo(
        version: AppVersion.tryParse('0.2.0')!,
        notes: '',
        htmlUrl: 'https://github.com/x',
      ),
      channel: InstallChannel.homebrew,
      current: AppVersion.tryParse('0.1.1')!,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UpdateBanner(
            status: status,
            onView: () => viewed = true,
            onSkip: () {},
            onDismiss: () {},
          ),
        ),
      ),
    );
    expect(find.textContaining('0.2.0'), findsOneWidget);
    await tester.tap(find.text('View'));
    expect(viewed, isTrue);
  });
}
