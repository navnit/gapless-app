import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/features/update/domain/update_preferences_port.dart';
import 'package:gapless/features/update/data/json_update_preferences.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('update_prefs'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('missing file loads defaults', () async {
    final store = JsonUpdatePreferences(File(p.join(dir.path, 'update.json')));
    final data = await store.load();
    expect(data.autoCheckEnabled, isTrue);
    expect(data.skippedVersion, isNull);
  });

  test('round-trips all fields', () async {
    final file = File(p.join(dir.path, 'update.json'));
    final store = JsonUpdatePreferences(file);
    final when = DateTime.fromMillisecondsSinceEpoch(1700000000000);
    await store.save(UpdatePreferencesData(
      autoCheckEnabled: false,
      skippedVersion: '0.2.0',
      lastCheckedAt: when,
    ));
    final loaded = await store.load();
    expect(loaded.autoCheckEnabled, isFalse);
    expect(loaded.skippedVersion, '0.2.0');
    expect(loaded.lastCheckedAt, when);
  });

  test('rejects wrong schema version as defaults', () async {
    final file = File(p.join(dir.path, 'update.json'));
    await file.writeAsString('{"schemaVersion":99,"autoCheckEnabled":false}');
    final data = await JsonUpdatePreferences(file).load();
    expect(data.autoCheckEnabled, isTrue);
  });
}
