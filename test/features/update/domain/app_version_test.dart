import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/features/update/domain/app_version.dart';

void main() {
  test('parses plain and v-prefixed versions', () {
    expect(AppVersion.tryParse('0.1.1'), AppVersion.tryParse('v0.1.1'));
    expect(AppVersion.tryParse('0.1.1').toString(), '0.1.1');
  });

  test('compares numerically, not lexically', () {
    expect(
      AppVersion.tryParse('0.10.0')!.isNewerThan(AppVersion.tryParse('0.9.0')!),
      isTrue,
    );
    expect(
      AppVersion.tryParse(
        '1.0.0',
      )!.isNewerThan(AppVersion.tryParse('0.99.99')!),
      isTrue,
    );
    expect(
      AppVersion.tryParse('0.1.1')!.isNewerThan(AppVersion.tryParse('0.1.1')!),
      isFalse,
    );
  });

  test('rejects suffixes, build metadata, and malformed input as null', () {
    for (final raw in ['0.2.0-rc1', '0.1.1+1', '1.2', '1.2.3.4', 'abc', '']) {
      expect(AppVersion.tryParse(raw), isNull, reason: raw);
    }
  });
}
