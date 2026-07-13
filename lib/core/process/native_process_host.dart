import 'dart:io';

import 'package:gapless/core/process/process_runner.dart';
import 'package:path/path.dart' as p;

final class NativeProcessHost {
  factory NativeProcessHost({
    String? executablePath,
    String? operatingSystem,
    String? resolvedExecutable,
  }) {
    final system = operatingSystem ?? Platform.operatingSystem;
    final path =
        executablePath ??
        resolveBundledExecutable(
          operatingSystem: system,
          resolvedExecutable: resolvedExecutable ?? Platform.resolvedExecutable,
        );
    final context = system == 'windows' ? p.windows : p.posix;
    if (!context.isAbsolute(path)) {
      throw ArgumentError.value(path, 'executablePath', 'Must be absolute');
    }
    return NativeProcessHost._(path);
  }

  const NativeProcessHost._(this.executablePath);

  static const controlCancelMessage = 'GPH1 CANCEL\n';

  final String executablePath;

  static String resolveBundledExecutable({
    required String operatingSystem,
    required String resolvedExecutable,
  }) {
    switch (operatingSystem) {
      case 'macos':
        final macosDirectory = p.posix.dirname(resolvedExecutable);
        return p.posix.join(
          p.posix.dirname(macosDirectory),
          'Resources',
          'gapless_process_host',
        );
      case 'linux':
        return p.posix.join(
          p.posix.dirname(resolvedExecutable),
          'lib',
          'gapless_process_host',
        );
      case 'windows':
        return p.windows.join(
          p.windows.dirname(resolvedExecutable),
          'gapless_process_host.exe',
        );
      default:
        throw UnsupportedError(
          'Gapless has no native process host for $operatingSystem',
        );
    }
  }

  Future<Process> start(
    ProcessRequest request, {
    required Map<String, String> environment,
    required Duration terminationGracePeriod,
    required Duration forceKillTimeout,
  }) async {
    if (!File(executablePath).existsSync()) {
      throw NativeProcessHostStartException(
        executablePath: executablePath,
        reason: 'Bundled native process host is missing',
      );
    }

    try {
      return await Process.start(
        executablePath,
        [
          '--grace-ms',
          '${terminationGracePeriod.inMilliseconds}',
          '--force-ms',
          '${forceKillTimeout.inMilliseconds}',
          '--',
          request.executable,
          ...request.arguments,
        ],
        workingDirectory: request.workingDirectory,
        environment: environment,
        includeParentEnvironment: false,
        runInShell: false,
      );
    } on Object catch (error) {
      throw NativeProcessHostStartException(
        executablePath: executablePath,
        reason: 'Bundled native process host could not be started',
        cause: error,
      );
    }
  }
}

final class NativeProcessHostStartException implements Exception {
  const NativeProcessHostStartException({
    required this.executablePath,
    required this.reason,
    this.cause,
  });

  final String executablePath;
  final String reason;
  final Object? cause;

  @override
  String toString() {
    final causeText = cause == null ? '' : ': $cause';
    return 'NativeProcessHostStartException($executablePath): '
        '$reason$causeText';
  }
}
