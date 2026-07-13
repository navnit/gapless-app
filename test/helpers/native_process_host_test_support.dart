import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

bool get supportsPosixNativeHostTests => Platform.isMacOS || Platform.isLinux;

Future<String> compilePosixProcessHost(Directory outputDirectory) async {
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

Future<bool> isProcessAlive(int pid) async {
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
