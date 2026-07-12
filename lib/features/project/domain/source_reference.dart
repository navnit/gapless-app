final class SourceFingerprint {
  const SourceFingerprint({
    required this.size,
    required this.modifiedAtUtc,
    required this.sampledSha256,
  });

  final int size;
  final DateTime modifiedAtUtc;
  final String sampledSha256;

  bool matches(SourceFingerprint other) =>
      size == other.size && sampledSha256 == other.sampledSha256;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SourceFingerprint &&
          size == other.size &&
          modifiedAtUtc == other.modifiedAtUtc &&
          sampledSha256 == other.sampledSha256;

  @override
  int get hashCode => Object.hash(size, modifiedAtUtc, sampledSha256);
}

final class SourceReference {
  const SourceReference({
    required this.relativePath,
    required this.absolutePath,
    required this.fingerprint,
  });

  final String relativePath;
  final String absolutePath;
  final SourceFingerprint fingerprint;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SourceReference &&
          relativePath == other.relativePath &&
          absolutePath == other.absolutePath &&
          fingerprint == other.fingerprint;

  @override
  int get hashCode => Object.hash(relativePath, absolutePath, fingerprint);
}
