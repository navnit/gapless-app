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
    final isolatedRunner = IoProcessRunner(
      parentEnvironment: const {
        'PATH': '/deliberate/path',
        'GAPLESS_PARENT_SECRET': 'must-not-leak',
      },
    );
    final request = ProcessRequest(
      executable: _dartExecutable,
      arguments: [_fixturePath('process_fixture.dart'), 'context', contextPath],
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
    final boundedRunner = IoProcessRunner(
      maxDiagnosticLines: 2,
      maxDiagnosticBytes: 64,
    );
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

  test(
    'bounds newline output before a listener without blocking exit',
    () async {
      final boundedRunner = IoProcessRunner(
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

  test(
    'caps a single enormous unterminated line and diagnostic bytes',
    () async {
      final boundedRunner = IoProcessRunner(
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

  test('replays a bounded tail then preserves ordered live lines', () async {
    final releasePath = p.join(temp.path, 'release');
    final readyPath = p.join(temp.path, 'ready');
    final boundedRunner = IoProcessRunner(
      maxPendingOutputLines: 2,
      maxPendingOutputBytes: 64,
    );
    final running = await boundedRunner.start(
      _fixtureRequest(['replay-then-live', '5', releasePath, readyPath]),
    );
    await _waitUntil(
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
  });

  test(
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

  test('cleans an owned child after its direct parent exits', () async {
    if (Platform.isWindows) return;
    final childPidPath = p.join(temp.path, 'orphan-child.pid');
    final releasePath = p.join(temp.path, 'release-parent');
    final control = _RecordingProcessControl(
      IoProcessControl(parentEnvironment: Platform.environment),
    );
    final ownershipRunner = IoProcessRunner(
      processControl: control,
      ownershipPollInterval: const Duration(milliseconds: 10),
      cancellationTimeout: const Duration(seconds: 5),
    );
    final running = await ownershipRunner.start(
      _fixtureRequest(['orphan-child', childPidPath, releasePath]),
    );
    expect(
      await running.stdoutLines.first.timeout(const Duration(seconds: 5)),
      'READY',
    );
    final childPid = int.parse(await File(childPidPath).readAsString());
    await _waitUntil(
      () async => control.seenPids.contains(childPid),
      timeout: const Duration(seconds: 5),
    );
    File(releasePath).writeAsStringSync('release', flush: true);
    expect(await running.exitCode, 0);

    await running.cancel().timeout(const Duration(seconds: 6));

    await _waitUntil(
      () async => !await _isProcessAlive(childPid),
      timeout: const Duration(seconds: 5),
    );
  });

  test('discovers and terminates a descendant spawned during cancel', () async {
    if (Platform.isWindows) return;
    final childPidPath = p.join(temp.path, 'late-child.pid');
    final control = _RecordingProcessControl(
      IoProcessControl(parentEnvironment: Platform.environment),
    );
    final ownershipRunner = IoProcessRunner(
      processControl: control,
      ownershipPollInterval: const Duration(milliseconds: 10),
      cancellationTimeout: const Duration(seconds: 5),
    );
    final running = await ownershipRunner.start(
      _fixtureRequest(['spawn-child-on-term', childPidPath]),
    );
    expect(
      await running.stdoutLines.first.timeout(const Duration(seconds: 5)),
      'READY',
    );

    final cancellation = running.cancel();
    await _waitUntil(
      () => File(childPidPath).exists(),
      timeout: const Duration(seconds: 5),
    );
    final childPid = int.parse(await File(childPidPath).readAsString());
    await cancellation.timeout(const Duration(seconds: 6));

    expect(await _isProcessAlive(childPid), isFalse);
    expect(await running.exitCode, isNot(0));
  });

  test('never signals a recycled PID with a mismatched identity', () async {
    final control = _FakeProcessControl();
    control.identityFor = (pid, timeout) async =>
        ProcessIdentity(pid: pid, startIdentity: 'original');
    control.snapshot = (timeout) async => [
      ProcessRecord(
        identity: ProcessIdentity(
          pid: control.rootPid!,
          startIdentity: 'recycled',
        ),
        parentPid: 1,
      ),
    ];
    final safeRunner = IoProcessRunner(
      processControl: control,
      cancellationTimeout: const Duration(milliseconds: 150),
      ownershipPollInterval: const Duration(milliseconds: 10),
    );
    final running = await safeRunner.start(_fixtureRequest(['wait']));
    control.rootPid = running.pid;
    expect(
      await running.stdoutLines.first.timeout(const Duration(seconds: 5)),
      'READY',
    );
    expect(await _isProcessAlive(running.pid), isTrue);

    await expectLater(running.cancel(), throwsA(isA<TimeoutException>()));
    expect(control.signals, isEmpty);
    await _forceCleanup(running);
  });

  test('applies one hard deadline when process discovery hangs', () async {
    final control = _FakeProcessControl();
    control.identityFor = (pid, timeout) async =>
        ProcessIdentity(pid: pid, startIdentity: 'root');
    control.snapshot = (_) => Completer<List<ProcessRecord>>().future;
    final deadlineRunner = IoProcessRunner(
      processControl: control,
      cancellationTimeout: const Duration(milliseconds: 150),
    );
    final running = await deadlineRunner.start(_fixtureRequest(['wait']));
    control.rootPid = running.pid;
    expect(await running.stdoutLines.first, 'READY');
    final stopwatch = Stopwatch()..start();

    await expectLater(running.cancel(), throwsA(isA<TimeoutException>()));

    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
    await _forceCleanup(running);
  });

  test('applies the hard deadline to a hung Windows taskkill', () async {
    final control = _FakeProcessControl(isWindows: true);
    control.identityFor = (pid, timeout) async =>
        ProcessIdentity(pid: pid, startIdentity: 'root');
    control.taskkill = (_, _) => Completer<ProcessCommandResult>().future;
    final deadlineRunner = IoProcessRunner(
      processControl: control,
      cancellationTimeout: const Duration(milliseconds: 150),
    );
    final running = await deadlineRunner.start(_fixtureRequest(['wait']));
    control.rootPid = running.pid;
    expect(await running.stdoutLines.first, 'READY');

    await expectLater(running.cancel(), throwsA(isA<TimeoutException>()));

    await _forceCleanup(running);
  });

  test(
    'rejects nonzero taskkill while the original process is alive',
    () async {
      final control = _FakeProcessControl(isWindows: true);
      control.identityFor = (pid, timeout) async =>
          ProcessIdentity(pid: pid, startIdentity: 'root');
      control.taskkill = (_, _) async =>
          const ProcessCommandResult(exitCode: 5);
      final windowsRunner = IoProcessRunner(
        processControl: control,
        cancellationTimeout: const Duration(seconds: 1),
      );
      final running = await windowsRunner.start(_fixtureRequest(['wait']));
      control.rootPid = running.pid;
      expect(await running.stdoutLines.first, 'READY');

      await expectLater(running.cancel(), throwsA(isA<ProcessException>()));

      await _forceCleanup(running);
    },
  );

  test('accepts nonzero taskkill only after verified target exit', () async {
    final control = _FakeProcessControl(isWindows: true);
    var originalAlive = true;
    control.identityFor = (pid, timeout) async => ProcessIdentity(
      pid: pid,
      startIdentity: originalAlive ? 'root' : 'replacement',
    );
    control.taskkill = (pid, _) async {
      originalAlive = false;
      Process.killPid(pid, ProcessSignal.sigkill);
      return const ProcessCommandResult(exitCode: 128);
    };
    final windowsRunner = IoProcessRunner(
      processControl: control,
      cancellationTimeout: const Duration(seconds: 2),
    );
    final running = await windowsRunner.start(_fixtureRequest(['wait']));
    control.rootPid = running.pid;
    expect(await running.stdoutLines.first, 'READY');

    await running.cancel();

    expect(await running.exitCode, isNot(0));
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

int _utf8Length(List<String> lines) =>
    lines.fold(0, (length, line) => length + utf8.encode(line).length);

Future<void> _forceCleanup(IoRunningProcess running) async {
  Process.killPid(running.pid, ProcessSignal.sigkill);
  await running.exitCode.timeout(const Duration(seconds: 5));
}

typedef _IdentityFor =
    Future<ProcessIdentity?> Function(int pid, Duration timeout);
typedef _Snapshot = Future<List<ProcessRecord>> Function(Duration timeout);
typedef _Taskkill =
    Future<ProcessCommandResult> Function(int pid, Duration timeout);

final class _FakeProcessControl implements ProcessControl {
  _FakeProcessControl({this.isWindows = false});

  @override
  final bool isWindows;
  int? rootPid;
  final List<(ProcessIdentity, ProcessSignal)> signals = [];
  late _IdentityFor identityFor;
  _Snapshot snapshot = (_) async => const [];
  _Taskkill taskkill = (_, _) async => const ProcessCommandResult(exitCode: 0);

  @override
  Future<ProcessIdentity?> inspectIdentity(
    int pid, {
    required Duration timeout,
  }) {
    rootPid ??= pid;
    return identityFor(pid, timeout);
  }

  @override
  Future<List<ProcessRecord>> inspectAll({required Duration timeout}) =>
      snapshot(timeout);

  @override
  Future<bool> signal(
    ProcessIdentity identity,
    ProcessSignal signal, {
    required Duration timeout,
  }) async {
    signals.add((identity, signal));
    return true;
  }

  @override
  Future<ProcessCommandResult> terminateWindowsTree(
    int pid, {
    required Duration timeout,
  }) => taskkill(pid, timeout);
}

final class _RecordingProcessControl implements ProcessControl {
  _RecordingProcessControl(this.delegate);

  final ProcessControl delegate;
  final Set<int> seenPids = {};
  final List<(ProcessIdentity, ProcessSignal, bool)> signals = [];

  @override
  bool get isWindows => delegate.isWindows;

  @override
  Future<ProcessIdentity?> inspectIdentity(
    int pid, {
    required Duration timeout,
  }) => delegate.inspectIdentity(pid, timeout: timeout);

  @override
  Future<List<ProcessRecord>> inspectAll({required Duration timeout}) async {
    final records = await delegate.inspectAll(timeout: timeout);
    seenPids.addAll(records.map((record) => record.identity.pid));
    return records;
  }

  @override
  Future<bool> signal(
    ProcessIdentity identity,
    ProcessSignal signal, {
    required Duration timeout,
  }) async {
    final result = await delegate.signal(identity, signal, timeout: timeout);
    signals.add((identity, signal, result));
    return result;
  }

  @override
  Future<ProcessCommandResult> terminateWindowsTree(
    int pid, {
    required Duration timeout,
  }) => delegate.terminateWindowsTree(pid, timeout: timeout);
}
