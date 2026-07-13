import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

bool get supportsPosixNativeHostTests => Platform.isMacOS || Platform.isLinux;

bool get supportsNativeHostTests =>
    supportsPosixNativeHostTests || Platform.isWindows;

Future<String> compileNativeProcessHost(Directory outputDirectory) {
  if (supportsPosixNativeHostTests) {
    return compilePosixProcessHost(outputDirectory, enableTestHooks: true);
  }
  if (Platform.isWindows) {
    return compileWindowsProcessHost(outputDirectory);
  }
  throw UnsupportedError(
    'Native process host tests do not support ${Platform.operatingSystem}',
  );
}

Future<String> compilePosixProcessHost(
  Directory outputDirectory, {
  bool enableTestHooks = false,
}) async {
  final source = File(
    p.join(
      Directory.current.path,
      'native',
      'process_host',
      'posix',
      'process_host.c',
    ),
  );
  final output = p.join(outputDirectory.path, 'gapless_process_host');
  final compiler = Platform.isMacOS ? '/usr/bin/clang' : '/usr/bin/cc';
  final result = await Process.run(compiler, [
    '-std=c11',
    '-Wall',
    '-Wextra',
    '-Werror',
    '-O2',
    if (enableTestHooks) '-DGAPLESS_PROCESS_HOST_TESTING=1',
    source.path,
    '-o',
    output,
  ], runInShell: false);
  if (result.exitCode != 0) {
    throw StateError(
      'Native process host compilation failed (${result.exitCode}):\n'
      '${result.stdout}\n${result.stderr}',
    );
  }
  return output;
}

Future<String> compileWindowsProcessHost(Directory outputDirectory) async {
  final sourceDirectory = p.join(
    Directory.current.path,
    'native',
    'process_host',
    'windows',
  );
  final buildDirectory = p.join(outputDirectory.path, 'windows-build');
  final configure = await Process.run('cmake.exe', [
    '-S',
    sourceDirectory,
    '-B',
    buildDirectory,
    '-A',
    'x64',
  ], runInShell: false);
  if (configure.exitCode != 0) {
    throw StateError(
      'Windows host configuration failed (${configure.exitCode}):\n'
      '${configure.stdout}\n${configure.stderr}',
    );
  }
  final build = await Process.run('cmake.exe', [
    '--build',
    buildDirectory,
    '--config',
    'Release',
  ], runInShell: false);
  if (build.exitCode != 0) {
    throw StateError(
      'Windows host compilation failed (${build.exitCode}):\n'
      '${build.stdout}\n${build.stderr}',
    );
  }
  return p.join(buildDirectory, 'Release', 'gapless_process_host.exe');
}

Future<bool> isProcessAlive(int pid) async {
  if (Platform.isWindows) {
    final result = await Process.run('tasklist.exe', [
      '/FI',
      'PID eq $pid',
      '/FO',
      'CSV',
      '/NH',
    ], runInShell: false);
    return result.exitCode == 0 &&
        result.stdout.toString().contains('","$pid","');
  }
  final result = await Process.run('/bin/kill', [
    '-0',
    '$pid',
  ], runInShell: false);
  return result.exitCode == 0;
}

Future<void> waitUntil(
  Future<bool> Function() condition, {
  required Duration timeout,
}) async {
  final stopwatch = Stopwatch()..start();
  while (!await condition()) {
    if (stopwatch.elapsed >= timeout) {
      throw TimeoutException('Condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
