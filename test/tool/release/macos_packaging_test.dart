import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('signs nested frameworks before the outer macOS app', () async {
    final script = await File('packaging/macos/package_dmg.sh').readAsString();

    final frameworkSigning = script.indexOf(r'find "$app/Contents/Frameworks"');
    final appSigning = script.indexOf(
      r'codesign --force --options runtime --timestamp --sign "$identity" '
      r'"$app"',
    );

    expect(frameworkSigning, greaterThanOrEqualTo(0));
    expect(script, contains("-name '*.framework'"));
    expect(frameworkSigning, lessThan(appSigning));
    expect(script, isNot(contains('codesign --deep')));
  });
}
