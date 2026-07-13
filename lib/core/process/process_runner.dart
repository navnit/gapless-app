import 'package:collection/collection.dart';
import 'package:path/path.dart' as p;

final class ProcessRequest {
  ProcessRequest({
    required String executable,
    required List<String> arguments,
    String? workingDirectory,
    Map<String, String> environment = const {},
  }) : executable = _validateExecutable(executable),
       arguments = List.unmodifiable(_validateArguments(arguments)),
       workingDirectory = _validateWorkingDirectory(workingDirectory),
       environment = Map.unmodifiable(_validateEnvironment(environment));

  final String executable;
  final List<String> arguments;
  final String? workingDirectory;
  final Map<String, String> environment;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProcessRequest &&
          executable == other.executable &&
          const ListEquality<String>().equals(arguments, other.arguments) &&
          workingDirectory == other.workingDirectory &&
          const MapEquality<String, String>().equals(
            environment,
            other.environment,
          );

  @override
  int get hashCode => Object.hash(
    executable,
    const ListEquality<String>().hash(arguments),
    workingDirectory,
    const MapEquality<String, String>().hash(environment),
  );
}

abstract interface class ProcessRunner {
  Future<RunningProcess> start(ProcessRequest request);
}

abstract interface class RunningProcess {
  int get pid;
  Stream<String> get stdoutLines;
  Stream<String> get stderrLines;
  Future<int> get exitCode;
  Future<void> cancel();
}

String _validateExecutable(String executable) {
  final isAbsolute =
      p.posix.isAbsolute(executable) || p.windows.isAbsolute(executable);
  if (executable.isEmpty || executable.contains('\u0000') || !isAbsolute) {
    throw ArgumentError.value(executable, 'executable');
  }
  return executable;
}

List<String> _validateArguments(List<String> arguments) {
  for (final argument in arguments) {
    if (argument.contains('\u0000')) {
      throw ArgumentError.value(argument, 'arguments');
    }
  }
  return arguments;
}

String? _validateWorkingDirectory(String? workingDirectory) {
  if (workingDirectory != null &&
      (workingDirectory.isEmpty || workingDirectory.contains('\u0000'))) {
    throw ArgumentError.value(workingDirectory, 'workingDirectory');
  }
  return workingDirectory;
}

Map<String, String> _validateEnvironment(Map<String, String> environment) {
  for (final entry in environment.entries) {
    if (entry.key.isEmpty ||
        entry.key.contains('=') ||
        entry.key.contains('\u0000') ||
        entry.value.contains('\u0000')) {
      throw ArgumentError.value(entry, 'environment');
    }
  }
  return environment;
}
