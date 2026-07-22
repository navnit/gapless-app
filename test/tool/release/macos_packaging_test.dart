import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ad hoc signs nested frameworks before the outer macOS app', () async {
    final script = await File('packaging/macos/package_dmg.sh').readAsString();

    final frameworkSigning = script.indexOf(r'find "$app/Contents/Frameworks"');
    final appSigning = script.indexOf(r'codesign --force --sign - "$app"');

    expect(frameworkSigning, greaterThanOrEqualTo(0));
    expect(script, contains("-name '*.framework'"));
    expect(frameworkSigning, lessThan(appSigning));
    expect(script, contains(r'codesign --verify --deep --strict'));
  });

  test('uses the ad hoc identity and no Developer ID / notarization', () async {
    final script = await File('packaging/macos/package_dmg.sh').readAsString();

    expect(script, contains('codesign --force --sign - '));
    for (final forbidden in <String>[
      '--options runtime',
      '--timestamp',
      'GAPLESS_MACOS_SIGN_IDENTITY',
      'GAPLESS_NOTARY_PROFILE',
      'notarytool',
      'stapler',
    ]) {
      expect(script, isNot(contains(forbidden)), reason: forbidden);
    }
  });
}
