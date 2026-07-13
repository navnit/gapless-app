import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/core/process/io_process_runner.dart';
import 'package:gapless/core/process/process_runner.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  late IoProcessRunner runner;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('gapless-process-test-');
    runner = IoProcessRunner();
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  test(
    'passes hostile-looking paths as one argument without a shell',
    () async {
      final capturePath = p.join(temp.path, 'arguments.json');
      final markerPath = p.join(temp.path, 'side-effect.txt');
      final hostilePath = Platform.isWindows
          ? '${p.join(temp.path, 'input video.mp4')} & echo pwned>"$markerPath"'
          : '${p.join(temp.path, 'input video.mp4')}; touch "$markerPath"';
      final request = ProcessRequest(
        executable: _dartExecutable,
        arguments: [
          _fixturePath('capture_args.dart'),
          capturePath,
          '--',
          hostilePath,
        ],
      );

      final running = await runner.start(request);

      expect(await running.exitCode, 0);
      expect(
        jsonDecode(await File(capturePath).readAsString()),
        request.arguments.skip(2).toList(),
      );
      expect(await File(markerPath).exists(), isFalse);
    },
  );

  test(
    'decodes Unicode and replaces malformed UTF-8 on both streams',
    () async {
      final running = await runner.start(_fixtureRequest(['bytes']));
      final stdout = running.stdoutLines.toList();
      final stderr = running.stderrLines.toList();

      expect(await running.exitCode, 0);
      expect(await stdout, ['café', 'bad\u{FFFD}byte']);
      expect(await stderr, ['σφάλμα', 'err\u{FFFD}or']);
    },
  );

  test('honors the requested environment and working directory', () async {
    final contextPath = p.join(temp.path, 'context.json');
    final request = ProcessRequest(
      executable: _dartExecutable,
      arguments: [_fixturePath('process_fixture.dart'), 'context', contextPath],
      workingDirectory: temp.path,
      environment: const {'GAPLESS_TEST_VALUE': 'snowman-☃'},
    );

    final running = await runner.start(request);

    expect(await running.exitCode, 0);
    final context = jsonDecode(await File(contextPath).readAsString());
    expect(
      await Directory(
        context['workingDirectory'] as String,
      ).resolveSymbolicLinks(),
      await temp.resolveSymbolicLinks(),
    );
    expect(context['environment'], 'snowman-☃');
  });

  test('exposes a nonzero exit code without losing output', () async {
    final running = await runner.start(_fixtureRequest(['fail', '17']));
    final stdout = running.stdoutLines.toList();
    final stderr = running.stderrLines.toList();

    expect(await running.exitCode, 17);
    expect(await stdout, ['before failure']);
    expect(await stderr, ['structured diagnostic']);
  });

  test('bounds diagnostics without truncating live streams', () async {
    final boundedRunner = IoProcessRunner(maxDiagnosticLines: 2);
    final running = await boundedRunner.start(_fixtureRequest(['lines', '5']));
    final stdout = running.stdoutLines.toList();
    final stderr = running.stderrLines.toList();

    expect(await running.exitCode, 0);
    expect(await stdout, [
      'stdout-0',
      'stdout-1',
      'stdout-2',
      'stdout-3',
      'stdout-4',
    ]);
    expect(await stderr, [
      'stderr-0',
      'stderr-1',
      'stderr-2',
      'stderr-3',
      'stderr-4',
    ]);
    expect(running.stdoutDiagnostics, ['stdout-3', 'stdout-4']);
    expect(running.stderrDiagnostics, ['stderr-3', 'stderr-4']);
    expect(
      () => running.stdoutDiagnostics.add('mutate'),
      throwsUnsupportedError,
    );
  });

  test('defensively copies request arguments and environment', () {
    final arguments = <String>['first'];
    final environment = <String, String>{'KEY': 'value'};

    final request = ProcessRequest(
      executable: _dartExecutable,
      arguments: arguments,
      environment: environment,
    );
    arguments.add('second');
    environment['KEY'] = 'changed';

    expect(request.arguments, ['first']);
    expect(request.environment, {'KEY': 'value'});
    expect(() => request.arguments.add('third'), throwsUnsupportedError);
    expect(
      () => request.environment['OTHER'] = 'value',
      throwsUnsupportedError,
    );
  });

  test('rejects invalid process request values', () {
    expect(
      () => ProcessRequest(executable: '', arguments: const []),
      throwsArgumentError,
    );
    expect(
      () => ProcessRequest(executable: 'dart\u0000bad', arguments: const []),
      throwsArgumentError,
    );
    expect(
      () =>
          ProcessRequest(executable: 'dart', arguments: const ['bad\u0000arg']),
      throwsArgumentError,
    );
    expect(
      () => ProcessRequest(
        executable: 'dart',
        arguments: const [],
        environment: const {'BAD=KEY': 'value'},
      ),
      throwsArgumentError,
    );
  });

  test(
    'cancel is idempotent, waits for the process tree, and is not success',
    () async {
      final childPidPath = p.join(temp.path, 'child.pid');
      final running = await runner.start(
        _fixtureRequest(['tree', childPidPath]),
      );
      expect(
        await running.stdoutLines.first.timeout(const Duration(seconds: 10)),
        'READY',
      );
      final childPid = int.parse(await File(childPidPath).readAsString());

      await Future.wait([
        running.cancel(),
        running.cancel(),
        running.cancel(),
      ]).timeout(const Duration(seconds: 10));

      expect(await running.exitCode, isNot(0));
      await _waitUntil(
        () async => !await _isProcessAlive(childPid),
        timeout: const Duration(seconds: 5),
      );
      expect(await _isProcessAlive(childPid), isFalse);
    },
  );
}

ProcessRequest _fixtureRequest(List<String> arguments) => ProcessRequest(
  executable: _dartExecutable,
  arguments: [_fixturePath('process_fixture.dart'), ...arguments],
);

String _fixturePath(String name) =>
    p.join(Directory.current.path, 'test', 'fixtures', 'process', name);

String get _dartExecutable {
  final resolved = Platform.resolvedExecutable;
  if (p.basenameWithoutExtension(resolved) == 'dart') return resolved;

  final executableName = Platform.isWindows ? 'dart.exe' : 'dart';
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    final fromEnvironment = p.join(
      flutterRoot,
      'bin',
      'cache',
      'dart-sdk',
      'bin',
      executableName,
    );
    if (File(fromEnvironment).existsSync()) return fromEnvironment;
  }

  var directory = File(resolved).parent;
  while (directory.parent.path != directory.path) {
    if (p.basename(directory.path) == 'cache') {
      final besideFlutterEngine = p.join(
        directory.path,
        'dart-sdk',
        'bin',
        executableName,
      );
      if (File(besideFlutterEngine).existsSync()) return besideFlutterEngine;
    }
    directory = directory.parent;
  }
  throw StateError('Could not locate the Dart executable from $resolved');
}

Future<bool> _isProcessAlive(int pid) async {
  if (Platform.isWindows) {
    final result = await Process.run('tasklist.exe', [
      '/FI',
      'PID eq $pid',
      '/FO',
      'CSV',
      '/NH',
    ], runInShell: false);
    return result.exitCode == 0 && '${result.stdout}'.contains('"$pid"');
  }
  final result = await Process.run('kill', ['-0', '$pid'], runInShell: false);
  return result.exitCode == 0;
}

Future<void> _waitUntil(
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
