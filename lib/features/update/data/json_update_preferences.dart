import 'dart:convert';
import 'dart:io';

import 'package:gapless/features/update/domain/update_preferences_port.dart';

final class JsonUpdatePreferences implements UpdatePreferencesPort {
  const JsonUpdatePreferences(this.file);

  static const schemaVersion = 1;
  final File file;

  @override
  Future<UpdatePreferencesData> load() async {
    try {
      if (!await file.exists()) return const UpdatePreferencesData();
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic> ||
          decoded['schemaVersion'] != schemaVersion) {
        return const UpdatePreferencesData();
      }
      final millis = decoded['lastCheckedAt'];
      return UpdatePreferencesData(
        autoCheckEnabled: decoded['autoCheckEnabled'] as bool? ?? true,
        skippedVersion: decoded['skippedVersion'] as String?,
        lastCheckedAt: millis is int
            ? DateTime.fromMillisecondsSinceEpoch(millis)
            : null,
      );
    } on Object {
      return const UpdatePreferencesData();
    }
  }

  @override
  Future<void> save(UpdatePreferencesData data) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      '${jsonEncode(<String, Object?>{'schemaVersion': schemaVersion, 'autoCheckEnabled': data.autoCheckEnabled, 'skippedVersion': data.skippedVersion, 'lastCheckedAt': data.lastCheckedAt?.millisecondsSinceEpoch})}\n',
      flush: true,
    );
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }
}
