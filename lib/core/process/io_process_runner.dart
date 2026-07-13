import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:gapless/core/process/process_runner.dart';

final class IoProcessRunner implements ProcessRunner {
  IoProcessRunner({
    this.maxDiagnosticLines = 200,
    this.terminationGracePeriod = const Duration(seconds: 2),
    this.forceKillTimeout = const Duration(seconds: 5),
  }) {
    if (maxDiagnosticLines < 0) {
      throw ArgumentError.value(maxDiagnosticLines, 'maxDiagnosticLines');
    }
    if (terminationGracePeriod.isNegative) {
      throw ArgumentError.value(
        terminationGracePeriod,
        'terminationGracePeriod',
      );
    }
    if (forceKillTimeout.isNegative) {
      throw ArgumentError.value(forceKillTimeout, 'forceKillTimeout');
    }
  }

  final int maxDiagnosticLines;
  final Duration terminationGracePeriod;
  final Duration forceKillTimeout;

  @override
  Future<IoRunningProcess> start(ProcessRequest request) async {
    final process = await Process.start(
      request.executable,
      request.arguments,
      workingDirectory: request.workingDirectory,
      environment: request.environment,
      runInShell: false,
    );
    return IoRunningProcess._(
      process,
      maxDiagnosticLines: maxDiagnosticLines,
      terminationGracePeriod: terminationGracePeriod,
      forceKillTimeout: forceKillTimeout,
    );
  }
}

final class IoRunningProcess implements RunningProcess {
  IoRunningProcess._(
    this._process, {
    required this.maxDiagnosticLines,
    required this.terminationGracePeriod,
    required this.forceKillTimeout,
  }) : _stdoutDiagnostics = _BoundedLines(maxDiagnosticLines),
       _stderrDiagnostics = _BoundedLines(maxDiagnosticLines) {
    _stdoutPump = _pump(_process.stdout, _stdoutController, _stdoutDiagnostics);
    _stderrPump = _pump(_process.stderr, _stderrController, _stderrDiagnostics);
    _rawExitCode = _process.exitCode.then((code) {
      _didExit = true;
      return code;
    });
    _publishedExitCode = _publishExitCode();
  }

  final Process _process;
  final int maxDiagnosticLines;
  final Duration terminationGracePeriod;
  final Duration forceKillTimeout;
  final StreamController<String> _stdoutController = StreamController();
  final StreamController<String> _stderrController = StreamController();
  final _BoundedLines _stdoutDiagnostics;
  final _BoundedLines _stderrDiagnostics;
  late final Future<void> _stdoutPump;
  late final Future<void> _stderrPump;
  late final Future<int> _rawExitCode;
  late final Future<int> _publishedExitCode;
  Future<void>? _cancellation;
  var _cancellationRequested = false;
  var _didExit = false;

  @override
  int get pid => _process.pid;

  @override
  Stream<String> get stdoutLines => _stdoutController.stream;

  @override
  Stream<String> get stderrLines => _stderrController.stream;

  List<String> get stdoutDiagnostics => _stdoutDiagnostics.snapshot;

  List<String> get stderrDiagnostics => _stderrDiagnostics.snapshot;

  @override
  Future<int> get exitCode => _publishedExitCode;

  @override
  Future<void> cancel() => _cancellation ??= _cancel();

  Future<int> _publishExitCode() async {
    final code = await _rawExitCode;
    await Future.wait([_stdoutPump, _stderrPump]);
    return _cancellationRequested && code == 0 ? -1 : code;
  }

  Future<void> _cancel() async {
    _cancellationRequested = true;
    if (_didExit) {
      await _publishedExitCode;
      return;
    }
    if (Platform.isWindows) {
      await _cancelWindows();
    } else {
      await _cancelPosix();
    }
    await _publishedExitCode;
  }

  Future<void> _cancelWindows() async {
    final taskkill = await Process.start('taskkill.exe', [
      '/PID',
      '$pid',
      '/T',
      '/F',
    ], runInShell: false);
    await Future.wait([
      taskkill.stdout.drain<void>(),
      taskkill.stderr.drain<void>(),
      taskkill.exitCode,
    ]);
    await _rawExitCode.timeout(forceKillTimeout);
  }

  Future<void> _cancelPosix() async {
    final processTree = await _collectProcessTree(pid);
    _signalAll(processTree.reversed, ProcessSignal.sigterm);

    final terminated = await _waitForTreeExit(
      processTree,
      terminationGracePeriod,
    );
    if (terminated) return;

    _signalAll(processTree.reversed, ProcessSignal.sigkill);
    final killed = await _waitForTreeExit(processTree, forceKillTimeout);
    if (!killed) {
      throw TimeoutException(
        'Process tree rooted at $pid did not terminate',
        forceKillTimeout,
      );
    }
  }

  Future<bool> _waitForTreeExit(List<int> processTree, Duration timeout) async {
    final stopwatch = Stopwatch()..start();
    while (true) {
      if (_didExit && !await _anyPidIsAlive(processTree.skip(1))) {
        return true;
      }
      if (stopwatch.elapsed >= timeout) return false;

      final remaining = timeout - stopwatch.elapsed;
      const pollingInterval = Duration(milliseconds: 20);
      await Future<void>.delayed(
        remaining < pollingInterval ? remaining : pollingInterval,
      );
    }
  }
}

Future<void> _pump(
  Stream<List<int>> bytes,
  StreamController<String> output,
  _BoundedLines diagnostics,
) async {
  try {
    await for (final line
        in bytes
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter())) {
      diagnostics.add(line);
      output.add(line);
    }
  } catch (error, stackTrace) {
    output.addError(error, stackTrace);
  } finally {
    unawaited(output.close());
  }
}

Future<List<int>> _collectProcessTree(int rootPid) async {
  final processTree = <int>[rootPid];
  for (final childPid in await _childPids(rootPid)) {
    processTree.addAll(await _collectProcessTree(childPid));
  }
  return processTree;
}

Future<List<int>> _childPids(int parentPid) async {
  try {
    final result = await Process.run(
      _posixExecutable('/usr/bin/pgrep', 'pgrep'),
      ['-P', '$parentPid'],
      runInShell: false,
    );
    if (result.exitCode != 0) return const [];
    return LineSplitter.split('${result.stdout}')
        .map((line) => int.tryParse(line.trim()))
        .whereType<int>()
        .toList(growable: false);
  } on ProcessException {
    return const [];
  }
}

void _signalAll(Iterable<int> pids, ProcessSignal signal) {
  for (final pid in pids) {
    try {
      Process.killPid(pid, signal);
    } on ProcessException {
      // A process may exit between discovery and signalling.
    }
  }
}

Future<bool> _anyPidIsAlive(Iterable<int> pids) async =>
    (await Future.wait(pids.map(_isPidAlive))).any((isAlive) => isAlive);

Future<bool> _isPidAlive(int pid) async {
  try {
    final result = await Process.run(_posixExecutable('/bin/kill', 'kill'), [
      '-0',
      '$pid',
    ], runInShell: false);
    return result.exitCode == 0;
  } on ProcessException {
    return false;
  }
}

String _posixExecutable(String absolute, String fallback) =>
    File(absolute).existsSync() ? absolute : fallback;

final class _BoundedLines {
  _BoundedLines(this.limit);

  final int limit;
  final Queue<String> _lines = Queue();

  void add(String line) {
    if (limit == 0) return;
    if (_lines.length == limit) _lines.removeFirst();
    _lines.addLast(line);
  }

  List<String> get snapshot => List.unmodifiable(_lines);
}
