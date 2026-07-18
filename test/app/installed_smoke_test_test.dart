import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/app/installed_smoke_test.dart';

void main() {
  test('resolves relative smoke-test arguments to absolute file URIs', () {
    const argument = 'build/smoke/source.avi';

    final uri = absoluteSmokeTestFileUri(argument);

    expect(uri, File(argument).absolute.uri);
    expect(uri.isAbsolute, isTrue);
  });
}
