import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/features/update/domain/update_preferences_port.dart';

void main() {
  test('defaults to auto-check on with no skip or timestamp', () {
    const data = UpdatePreferencesData();
    expect(data.autoCheckEnabled, isTrue);
    expect(data.skippedVersion, isNull);
    expect(data.lastCheckedAt, isNull);
  });

  test('copyWith replaces only named fields', () {
    final base = const UpdatePreferencesData();
    final updated = base.copyWith(skippedVersion: '0.2.0', autoCheckEnabled: false);
    expect(updated.skippedVersion, '0.2.0');
    expect(updated.autoCheckEnabled, isFalse);
    expect(updated.lastCheckedAt, isNull);
  });
}
