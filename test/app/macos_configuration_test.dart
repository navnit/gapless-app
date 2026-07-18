import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('debug app can read and write files selected by the user', () {
    final entitlements = File(
      'macos/Runner/DebugProfile.entitlements',
    ).readAsStringSync();

    expect(
      entitlements,
      contains('com.apple.security.files.user-selected.read-write'),
    );
  });
}
