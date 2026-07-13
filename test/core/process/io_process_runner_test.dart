import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/core/process/io_process_runner.dart';
import 'package:gapless/core/process/native_process_host.dart';
import 'package:gapless/core/process/process_runner.dart';
import 'package:path/path.dart' as p;

import '../../helpers/native_process_host_test_support.dart';

void main() {
  late Directory temp;
  late Directory suiteTemp;
  late NativeProcessHost nativeProcessHost;
  late IoProcessRunner runner;

  setUpAll(() async {
    if (!supportsNativeHostTests) return;
    suiteTemp = Directory.systemTemp.createTempSync('gapless-runner-host-');
    nativeProcessHost = NativeProcessHost(
      executablePath: await compileNativeProcessHost(suiteTemp),
    );
  });

  tearDownAll(() {
    if (supportsNativeHostTests && suiteTemp.existsSync()) {
      suiteTemp.deleteSync(recursive: true);
    }
  });

  setUp(() {
    temp = Directory.systemTemp.createTempSync('gapless-process-test-');
    if (supportsNativeHostTests) {
      runner = IoProcessRunner(nativeProcessHost: nativeProcessHost);
    }
  });

  test(
    'requires the bundled host and never falls back to the target',
    () async {
      if (!supportsNativeHostTests) return;
      final markerPath = p.join(temp.path, 'target-started.json');
      final missingHost = NativeProcessHost(
        executablePath: p.join(temp.path, 'missing-process-host'),
      );
      final missingHostRunner = IoProcessRunner(nativeProcessHost: missingHost);

      await expectLater(
        missingHostRunner.start(
          ProcessRequest(
            executable: _dartExecutable,
            arguments: [_fixturePath('capture_args.dart'), markerPath],
          ),
        ),
        throwsA(isA<NativeProcessHostStartException>()),
      );
      expect(File(markerPath).existsSync(), isFalse);
    },
  );

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  _nativeHostTest(
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

  _nativeHostTest(
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

  _nativeHostTest(
    'honors the requested environment and working directory',
    () async {
      final contextPath = p.join(temp.path, 'context.json');
      final isolatedRunner = IoProcessRunner(
        nativeProcessHost: nativeProcessHost,
        parentEnvironment: const {
          'PATH': '/deliberate/path',
          'GAPLESS_PARENT_SECRET': 'must-not-leak',
        },
      );
      final request = ProcessRequest(
        executable: _dartExecutable,
        arguments: [
          _fixturePath('process_fixture.dart'),
          'context',
          contextPath,
        ],
        workingDirectory: temp.path,
        environment: const {'GAPLESS_TEST_VALUE': 'explicit-value'},
      );

      final running = await isolatedRunner.start(request);

      expect(await running.exitCode, 0);
      final context = jsonDecode(await File(contextPath).readAsString());
      expect(
        await Directory(
          context['workingDirectory'] as String,
        ).resolveSymbolicLinks(),
        await temp.resolveSymbolicLinks(),
      );
      expect(context['environment'], 'explicit-value');
      expect(context['parentSecret'], isNull);
    },
  );

  _windowsHostTest('does not leak an unrelated inheritable handle', () async {
    final resultPath = p.join(temp.path, 'handle-privacy.txt');
    final running = await runner.start(
      ProcessRequest(
        executable: _dartExecutable,
        arguments: [
          _fixturePath('process_fixture.dart'),
          'check-unrelated-handle',
          resultPath,
        ],
        environment: const {'GPH_TEST_CREATE_UNRELATED_HANDLE': '1'},
      ),
    );

    expect(await running.exitCode, 0);
    expect(await File(resultPath).readAsString(), 'invalid');
  });

  _nativeHostTest(
    'exposes a nonzero exit code without losing output',
    () async {
      final running = await runner.start(_fixtureRequest(['fail', '17']));
      final stdout = running.stdoutLines.toList();
      final stderr = running.stderrLines.toList();

      expect(await running.exitCode, 17);
      expect(await stdout, ['before failure']);
      expect(await stderr, ['structured diagnostic']);
    },
  );

  _nativeHostTest(
    'bounds diagnostics without truncating live streams',
    () async {
      final boundedRunner = IoProcessRunner(
        nativeProcessHost: nativeProcessHost,
        maxDiagnosticLines: 2,
        maxDiagnosticBytes: 64,
      );
      final running = await boundedRunner.start(
        _fixtureRequest(['lines', '5']),
      );
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
    },
  );

  _nativeHostTest(
    'bounds newline output before a listener without blocking exit',
    () async {
      final boundedRunner = IoProcessRunner(
        nativeProcessHost: nativeProcessHost,
        maxPendingOutputLines: 3,
        maxPendingOutputBytes: 64,
        maxDiagnosticLines: 3,
        maxDiagnosticBytes: 64,
      );
      final running = await boundedRunner.start(
        _fixtureRequest(['lines', '20000']),
      );

      expect(await running.exitCode.timeout(const Duration(seconds: 10)), 0);
      final replay = await running.stdoutLines.toList();
      expect(replay.first, IoRunningProcess.outputTruncatedMarker);
      expect(replay.length, lessThanOrEqualTo(4));
      expect(replay.last, 'stdout-19999');
      expect(_utf8Length(running.stdoutDiagnostics), lessThanOrEqualTo(64));
      expect(_utf8Length(running.stderrDiagnostics), lessThanOrEqualTo(64));
    },
  );

  _nativeHostTest(
    'caps a single enormous unterminated line and diagnostic bytes',
    () async {
      final boundedRunner = IoProcessRunner(
        nativeProcessHost: nativeProcessHost,
        maxLineBytes: 64,
        maxLineCharacters: 64,
        maxPendingOutputBytes: 80,
        maxDiagnosticBytes: 64,
      );
      final running = await boundedRunner.start(
        _fixtureRequest(['long-line', '${2 * 1024 * 1024}']),
      );

      expect(await running.exitCode.timeout(const Duration(seconds: 10)), 0);
      final replay = await running.stdoutLines.toList();
      expect(replay, hasLength(1));
      expect(replay.single, endsWith(IoRunningProcess.lineTruncatedMarker));
      expect(utf8.encode(replay.single), hasLength(lessThanOrEqualTo(64)));
      expect(_utf8Length(running.stdoutDiagnostics), lessThanOrEqualTo(64));
    },
  );

  _nativeHostTest(
    'replays a bounded tail then preserves ordered live lines',
    () async {
      final releasePath = p.join(temp.path, 'release');
      final readyPath = p.join(temp.path, 'ready');
      final boundedRunner = IoProcessRunner(
        nativeProcessHost: nativeProcessHost,
        maxPendingOutputLines: 2,
        maxPendingOutputBytes: 64,
      );
      final running = await boundedRunner.start(
        _fixtureRequest(['replay-then-live', '5', releasePath, readyPath]),
      );
      await waitUntil(
        () => File(readyPath).exists(),
        timeout: const Duration(seconds: 5),
      );

      final linesFuture = running.stdoutLines.toList();
      File(releasePath).writeAsStringSync('release', flush: true);

      expect(await running.exitCode, 0);
      expect(await linesFuture, [
        IoRunningProcess.outputTruncatedMarker,
        'pre-3',
        'pre-4',
        'live-0',
        'live-1',
      ]);
    },
  );

  _nativeHostTest(
    'handles split multibyte UTF-8, CRLF, and a final partial line',
    () async {
      final running = await runner.start(_fixtureRequest(['split-bytes']));
      final lines = running.stdoutLines.toList();

      expect(await running.exitCode, 0);
      expect(await lines, ['A€', 'B', 'C']);
    },
  );

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
      () => ProcessRequest(executable: 'tools/engine', arguments: const []),
      throwsArgumentError,
    );
    expect(
      () =>
          ProcessRequest(executable: r'tools\engine.exe', arguments: const []),
      throwsArgumentError,
    );
    expect(
      () => ProcessRequest(
        executable: r'C:tools\engine.exe',
        arguments: const [],
      ),
      throwsArgumentError,
    );
    expect(
      () => ProcessRequest(
        executable: _dartExecutable,
        arguments: const ['bad\u0000arg'],
      ),
      throwsArgumentError,
    );
    expect(
      () => ProcessRequest(
        executable: _dartExecutable,
        arguments: const [],
        environment: const {'BAD=KEY': 'value'},
      ),
      throwsArgumentError,
    );
  });

  test('Dart cancellation watchdog exceeds the full native cleanup budget', () {
    expect(
      () => IoProcessRunner(
        nativeProcessHost: nativeProcessHost,
        forceKillTimeout: Duration.zero,
      ),
      throwsArgumentError,
    );
    expect(
      () => IoProcessRunner(
        nativeProcessHost: nativeProcessHost,
        terminationGracePeriod: const Duration(milliseconds: 300),
        forceKillTimeout: const Duration(milliseconds: 300),
        cancellationTimeout: const Duration(milliseconds: 600),
      ),
      throwsArgumentError,
    );

    final guarded = IoProcessRunner(
      nativeProcessHost: nativeProcessHost,
      terminationGracePeriod: const Duration(milliseconds: 300),
      forceKillTimeout: const Duration(milliseconds: 300),
      cancellationTimeout: const Duration(milliseconds: 1600),
    );
    expect(
      guarded.cancellationTimeout,
      greaterThan(guarded.terminationGracePeriod + guarded.forceKillTimeout),
    );
  });

  _nativeHostTest(
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
      await waitUntil(
        () async => !await isProcessAlive(childPid),
        timeout: const Duration(seconds: 5),
      );
      expect(await isProcessAlive(childPid), isFalse);
    },
  );

  _nativeHostTest(
    'cancels an orphaned descendant after its direct parent exits',
    () async {
      if (!supportsNativeHostTests) return;
      final childPidPath = p.join(temp.path, 'orphan-grandchild.pid');
      final running = await runner.start(
        _fixtureRequest(['orphan-grandchild', childPidPath]),
      );
      expect(await running.stdoutLines.first, 'READY');
      final childPid = int.parse(await File(childPidPath).readAsString());

      await running.cancel().timeout(const Duration(seconds: 10));

      expect(await isProcessAlive(childPid), isFalse);
      expect(await running.exitCode, isNot(0));
    },
  );

  _posixHostTest(
    'terminates a descendant spawned during cancellation',
    () async {
      if (!supportsPosixNativeHostTests) return;
      final childPidPath = p.join(temp.path, 'late-child.pid');
      final running = await runner.start(
        _fixtureRequest(['spawn-child-on-term', childPidPath]),
      );
      expect(
        await running.stdoutLines.first.timeout(const Duration(seconds: 5)),
        'READY',
      );

      final cancellation = running.cancel();
      await waitUntil(
        () => File(childPidPath).exists(),
        timeout: const Duration(seconds: 5),
      );
      final childPid = int.parse(await File(childPidPath).readAsString());
      await cancellation.timeout(const Duration(seconds: 6));

      expect(await isProcessAlive(childPid), isFalse);
      expect(await running.exitCode, isNot(0));
    },
  );

  _posixHostTest(
    'force-kills a full group that ignores SIGTERM within the deadline',
    () async {
      if (!supportsPosixNativeHostTests) return;
      final childPidPath = p.join(temp.path, 'ignore-term-child.pid');
      final forceRunner = IoProcessRunner(
        nativeProcessHost: nativeProcessHost,
        terminationGracePeriod: const Duration(milliseconds: 150),
        forceKillTimeout: const Duration(seconds: 2),
        cancellationTimeout: const Duration(seconds: 4),
      );
      final running = await forceRunner.start(
        _fixtureRequest(['ignore-term-tree', childPidPath]),
      );
      expect(await running.stdoutLines.first, 'READY');
      final childPid = int.parse(await File(childPidPath).readAsString());
      final stopwatch = Stopwatch()..start();

      await running.cancel();

      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 4)));
      expect(await isProcessAlive(childPid), isFalse);
      expect(await running.exitCode, isNot(0));
    },
  );

  _nativeHostTest(
    'cleans lingering descendants before a normal host exit',
    () async {
      if (!supportsNativeHostTests) return;
      final childPidPath = p.join(temp.path, 'lingering-child.pid');
      final cleanupRunner = IoProcessRunner(
        nativeProcessHost: nativeProcessHost,
        terminationGracePeriod: const Duration(milliseconds: 100),
      );
      final running = await cleanupRunner.start(
        _fixtureRequest(['exit-with-child', childPidPath]),
      );
      expect(await running.stdoutLines.first, 'READY');
      final childPid = int.parse(await File(childPidPath).readAsString());

      expect(await running.exitCode.timeout(const Duration(seconds: 5)), 0);
      expect(await isProcessAlive(childPid), isFalse);
    },
  );

  _nativeHostTest(
    'control-channel EOF cancels the owned process group',
    () async {
      if (!supportsNativeHostTests) return;
      final childPidPath = p.join(temp.path, 'eof-child.pid');
      final host = await Process.start(nativeProcessHost.executablePath, [
        '--grace-ms',
        '100',
        '--force-ms',
        '2000',
        '--',
        _dartExecutable,
        _fixturePath('process_fixture.dart'),
        'tree',
        childPidPath,
      ], runInShell: false);
      final ready = host.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      expect(await ready.first, 'READY');
      final childPid = int.parse(await File(childPidPath).readAsString());

      await host.stdin.close();

      expect(await host.exitCode.timeout(const Duration(seconds: 5)), isNot(0));
      expect(await isProcessAlive(childPid), isFalse);
    },
  );

  _nativeHostTest('target exec failure is bounded and nonzero', () async {
    if (!supportsNativeHostTests) return;
    final failureRunner = IoProcessRunner(
      nativeProcessHost: nativeProcessHost,
      maxDiagnosticLines: 2,
      maxDiagnosticBytes: 160,
    );
    final running = await failureRunner.start(
      ProcessRequest(
        executable: p.join(temp.path, 'missing-target'),
        arguments: const ['hostile; argument', 'quoted "argument"'],
      ),
    );

    expect(
      await running.exitCode.timeout(const Duration(seconds: 5)),
      isNot(0),
    );
    expect(
      running.stderrDiagnostics.join('\n'),
      contains('target exec failed'),
    );
    expect(_utf8Length(running.stderrDiagnostics), lessThanOrEqualTo(160));
  });
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

int _utf8Length(List<String> lines) =>
    lines.fold(0, (length, line) => length + utf8.encode(line).length);

void _posixHostTest(String description, FutureOr<void> Function() body) {
  test(
    description,
    body,
    skip: supportsPosixNativeHostTests
        ? false
        : 'Native runtime proof is deferred to POSIX hosts',
  );
}

void _nativeHostTest(String description, FutureOr<void> Function() body) {
  test(
    description,
    body,
    skip: supportsNativeHostTests
        ? false
        : 'Native runtime proof requires a desktop host',
  );
}

void _windowsHostTest(String description, FutureOr<void> Function() body) {
  test(
    description,
    body,
    skip: Platform.isWindows ? false : 'Windows runtime proof runs in CI',
  );
}
