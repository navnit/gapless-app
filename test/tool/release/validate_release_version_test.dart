import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../../tool/release/validate_release_version.dart';

void main() {
  test('committed pubspec declares Gapless 0.1.2 build 1', () async {
    final version = ReleaseVersion.parsePubspec(
      await File('pubspec.yaml').readAsString(),
    );

    expect(version.name, '0.1.2');
    expect(version.buildNumber, 1);
  });

  test('parses the committed Flutter release version', () {
    final version = ReleaseVersion.parsePubspec('version: 0.1.0+1\n');

    expect(version.name, '0.1.0');
    expect(version.buildNumber, 1);
  });

  test('requires exact candidate or tag equality', () {
    final version = ReleaseVersion.parsePubspec('version: 0.1.0+1\n');

    expect(() => version.requireReleaseName('0.1.0'), returnsNormally);
    expect(
      () => version.requireReleaseName('1.0.0'),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'Release version 1.0.0 does not match pubspec version 0.1.0.',
        ),
      ),
    );
  });

  test('rejects malformed and ambiguous versions', () {
    for (final source in <String>[
      'name: gapless\n',
      'version: 0.1.0\n',
      'version: 01.0.0+1\n',
      'version: 0.1.0+0\n',
      'version: 0.1.0+1\nversion: 0.1.1+2\n',
    ]) {
      expect(
        () => ReleaseVersion.parsePubspec(source),
        throwsA(isA<FormatException>()),
        reason: source,
      );
    }
  });
}
