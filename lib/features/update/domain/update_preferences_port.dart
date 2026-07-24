final class UpdatePreferencesData {
  const UpdatePreferencesData({
    this.autoCheckEnabled = true,
    this.skippedVersion,
    this.lastCheckedAt,
  });

  final bool autoCheckEnabled;
  final String? skippedVersion;
  final DateTime? lastCheckedAt;

  UpdatePreferencesData copyWith({
    bool? autoCheckEnabled,
    String? skippedVersion,
    DateTime? lastCheckedAt,
  }) => UpdatePreferencesData(
    autoCheckEnabled: autoCheckEnabled ?? this.autoCheckEnabled,
    skippedVersion: skippedVersion ?? this.skippedVersion,
    lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
  );
}

abstract interface class UpdatePreferencesPort {
  Future<UpdatePreferencesData> load();
  Future<void> save(UpdatePreferencesData data);
}
