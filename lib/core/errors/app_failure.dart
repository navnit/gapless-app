sealed class AppFailure implements Exception {
  const AppFailure();
}

final class ProjectFormatFailure extends AppFailure {
  const ProjectFormatFailure(this.reason);

  final String reason;

  @override
  String toString() => 'ProjectFormatFailure: $reason';
}

final class ProjectSaveFailure extends AppFailure {
  const ProjectSaveFailure(this.path, this.cause);

  final Uri path;
  final Object cause;

  @override
  String toString() => 'ProjectSaveFailure($path): $cause';
}

final class SourceMissingFailure extends AppFailure {
  const SourceMissingFailure({this.source});

  final Uri? source;
}

final class SourceChangedFailure extends AppFailure {
  const SourceChangedFailure({
    this.source,
    this.expectedFingerprint,
    this.actualFingerprint,
  });

  final Uri? source;
  final String? expectedFingerprint;
  final String? actualFingerprint;
}

final class EngineMissingFailure extends AppFailure {
  const EngineMissingFailure({this.expectedLocation});

  final Uri? expectedLocation;
}

final class EngineChecksumFailure extends AppFailure {
  const EngineChecksumFailure({
    required this.expectedSha256,
    required this.actualSha256,
  });

  final String expectedSha256;
  final String actualSha256;
}

enum EngineContractReason {
  invalidOutput,
  unsupportedVersion,
  unsupportedSources,
  invalidTimeline,
  unexpectedExit,
}

final class EngineContractFailure extends AppFailure {
  EngineContractFailure({
    required this.operation,
    required this.reason,
    this.exitCode,
    List<String> diagnostics = const [],
  }) : diagnostics = List.unmodifiable(diagnostics);

  final String operation;
  final EngineContractReason reason;
  final int? exitCode;
  final List<String> diagnostics;
}

enum MediaReadReason { unreadable, corrupt, unsupported, noAudio }

final class MediaReadFailure extends AppFailure {
  MediaReadFailure({
    required this.source,
    required this.reason,
    List<String> diagnostics = const [],
  }) : diagnostics = List.unmodifiable(diagnostics);

  final Uri source;
  final MediaReadReason reason;
  final List<String> diagnostics;
}

final class DiskFullFailure extends AppFailure {
  const DiskFullFailure({
    this.destination,
    this.requiredBytes,
    this.availableBytes,
  }) : assert(requiredBytes == null || requiredBytes >= 0),
       assert(availableBytes == null || availableBytes >= 0);

  final Uri? destination;
  final int? requiredBytes;
  final int? availableBytes;
}

final class OperationCancelled extends AppFailure {
  const OperationCancelled({this.operation});

  final String? operation;
}
