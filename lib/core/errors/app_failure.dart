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
