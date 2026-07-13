import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:gapless/core/process/bounded_utf8_line_decoder.dart';
import 'package:gapless/core/process/process_runner.dart';

final class ProcessIdentity {
  const ProcessIdentity({required this.pid, required this.startIdentity});

  final int pid;
  final String startIdentity;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProcessIdentity &&
          pid == other.pid &&
          startIdentity == other.startIdentity;

  @override
  int get hashCode => Object.hash(pid, startIdentity);
}

final class ProcessRecord {
  const ProcessRecord({required this.identity, required this.parentPid});

  final ProcessIdentity identity;
  final int parentPid;
}

final class ProcessCommandResult {
  const ProcessCommandResult({
    required this.exitCode,
    this.stdoutDiagnostics = '',
    this.stderrDiagnostics = '',
  });

  final int exitCode;
  final String stdoutDiagnostics;
  final String stderrDiagnostics;
}

abstract interface class ProcessControl {
  bool get isWindows;

  Future<ProcessIdentity?> inspectIdentity(
    int pid, {
    required Duration timeout,
  });

  Future<List<ProcessRecord>> inspectAll({required Duration timeout});

  Future<bool> signal(
    ProcessIdentity identity,
    ProcessSignal signal, {
    required Duration timeout,
  });

  Future<ProcessCommandResult> terminateWindowsTree(
    int pid, {
    required Duration timeout,
  });
}

final class IoProcessControl implements ProcessControl {
  IoProcessControl({
    Map<String, String>? parentEnvironment,
    this.maxHelperDiagnosticBytes = 8 * 1024,
    this.maxSnapshotBytes = 4 * 1024 * 1024,
  }) : parentEnvironment = Map.unmodifiable(
         parentEnvironment ?? Platform.environment,
       ) {
    if (maxHelperDiagnosticBytes < 0) {
      throw ArgumentError.value(
        maxHelperDiagnosticBytes,
        'maxHelperDiagnosticBytes',
      );
    }
    if (maxSnapshotBytes <= 0) {
      throw ArgumentError.value(maxSnapshotBytes, 'maxSnapshotBytes');
    }
  }

  final Map<String, String> parentEnvironment;
  final int maxHelperDiagnosticBytes;
  final int maxSnapshotBytes;

  @override
  bool get isWindows => Platform.isWindows;

  @override
  Future<ProcessIdentity?> inspectIdentity(
    int pid, {
    required Duration timeout,
  }) async {
    if (isWindows) {
      final result = await _runHelper(_tasklistExecutable(parentEnvironment), [
        '/FI',
        'PID eq $pid',
        '/FO',
        'CSV',
        '/NH',
      ], timeout: timeout);
      if (result.exitCode != 0 ||
          !result.stdoutDiagnostics.contains('"$pid"')) {
        return null;
      }
      return ProcessIdentity(pid: pid, startIdentity: 'windows-pid-$pid');
    }
    final result = await _runHelper(
      _posixExecutable('/bin/ps', 'ps'),
      ['-p', '$pid', '-o', 'pid=,ppid=,lstart='],
      timeout: timeout,
      outputByteLimit: maxSnapshotBytes,
    );
    if (result.exitCode != 0) return null;
    final records = _parsePosixProcessRecords(result.stdoutDiagnostics);
    return records
        .where((record) => record.identity.pid == pid)
        .firstOrNull
        ?.identity;
  }

  @override
  Future<List<ProcessRecord>> inspectAll({required Duration timeout}) async {
    if (isWindows) return const [];
    final result = await _runHelper(
      _posixExecutable('/bin/ps', 'ps'),
      ['-axo', 'pid=,ppid=,lstart='],
      timeout: timeout,
      outputByteLimit: maxSnapshotBytes,
    );
    if (result.exitCode != 0) {
      throw ProcessException(
        'ps',
        const ['-axo', 'pid=,ppid=,lstart='],
        result.stderrDiagnostics,
        result.exitCode,
      );
    }
    return _parsePosixProcessRecords(result.stdoutDiagnostics);
  }

  @override
  Future<bool> signal(
    ProcessIdentity identity,
    ProcessSignal signal, {
    required Duration timeout,
  }) async {
    final current = await inspectIdentity(identity.pid, timeout: timeout);
    if (current != identity) return false;
    return Process.killPid(identity.pid, signal);
  }

  @override
  Future<ProcessCommandResult> terminateWindowsTree(
    int pid, {
    required Duration timeout,
  }) => _runHelper(_taskkillExecutable(parentEnvironment), [
    '/PID',
    '$pid',
    '/T',
    '/F',
  ], timeout: timeout);

  Future<ProcessCommandResult> _runHelper(
    String executable,
    List<String> arguments, {
    required Duration timeout,
    int? outputByteLimit,
  }) async {
    final deadline = _Deadline(timeout);
    Process? helper;
    try {
      helper = await Process.start(
        executable,
        arguments,
        environment: _safeEnvironment(parentEnvironment, const {}),
        includeParentEnvironment: false,
        runInShell: false,
      ).timeout(deadline.remaining);
      final stdoutTail = _BoundedByteTail(
        outputByteLimit ?? maxHelperDiagnosticBytes,
      );
      final stderrTail = _BoundedByteTail(maxHelperDiagnosticBytes);
      final stdoutPump = helper.stdout.forEach(stdoutTail.add);
      final stderrPump = helper.stderr.forEach(stderrTail.add);
      final exitCode = await helper.exitCode.timeout(deadline.remaining);
      await Future.wait([stdoutPump, stderrPump]).timeout(deadline.remaining);
      return ProcessCommandResult(
        exitCode: exitCode,
        stdoutDiagnostics: stdoutTail.text,
        stderrDiagnostics: stderrTail.text,
      );
    } on TimeoutException {
      helper?.kill(ProcessSignal.sigkill);
      rethrow;
    }
  }
}

final class IoProcessRunner implements ProcessRunner {
  IoProcessRunner({
    this.maxDiagnosticLines = 200,
    this.maxDiagnosticBytes = 64 * 1024,
    this.maxPendingOutputLines = 256,
    this.maxPendingOutputBytes = 64 * 1024,
    this.maxLineBytes = 16 * 1024,
    this.maxLineCharacters = 16 * 1024,
    this.terminationGracePeriod = const Duration(seconds: 2),
    this.forceKillTimeout = const Duration(seconds: 5),
    this.cancellationTimeout = const Duration(seconds: 7),
    this.ownershipPollInterval = const Duration(milliseconds: 25),
    this.helperTimeout = const Duration(seconds: 1),
    Map<String, String>? parentEnvironment,
    ProcessControl? processControl,
  }) : parentEnvironment = Map.unmodifiable(
         parentEnvironment ?? Platform.environment,
       ),
       processControl =
           processControl ??
           IoProcessControl(
             parentEnvironment: parentEnvironment ?? Platform.environment,
           ) {
    if (maxDiagnosticLines < 0) {
      throw ArgumentError.value(maxDiagnosticLines, 'maxDiagnosticLines');
    }
    if (maxDiagnosticBytes < 0) {
      throw ArgumentError.value(maxDiagnosticBytes, 'maxDiagnosticBytes');
    }
    if (maxPendingOutputLines < 0) {
      throw ArgumentError.value(maxPendingOutputLines, 'maxPendingOutputLines');
    }
    if (maxPendingOutputBytes < 0) {
      throw ArgumentError.value(maxPendingOutputBytes, 'maxPendingOutputBytes');
    }
    if (maxLineBytes <
        utf8.encode(BoundedUtf8LineDecoder.lineTruncatedMarker).length) {
      throw ArgumentError.value(maxLineBytes, 'maxLineBytes');
    }
    if (maxLineCharacters <
        BoundedUtf8LineDecoder.lineTruncatedMarker.runes.length) {
      throw ArgumentError.value(maxLineCharacters, 'maxLineCharacters');
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
    if (cancellationTimeout <= Duration.zero) {
      throw ArgumentError.value(cancellationTimeout, 'cancellationTimeout');
    }
    if (ownershipPollInterval <= Duration.zero) {
      throw ArgumentError.value(ownershipPollInterval, 'ownershipPollInterval');
    }
    if (helperTimeout <= Duration.zero) {
      throw ArgumentError.value(helperTimeout, 'helperTimeout');
    }
  }

  final int maxDiagnosticLines;
  final int maxDiagnosticBytes;
  final int maxPendingOutputLines;
  final int maxPendingOutputBytes;
  final int maxLineBytes;
  final int maxLineCharacters;
  final Duration terminationGracePeriod;
  final Duration forceKillTimeout;
  final Duration cancellationTimeout;
  final Duration ownershipPollInterval;
  final Duration helperTimeout;
  final Map<String, String> parentEnvironment;
  final ProcessControl processControl;

  @override
  Future<IoRunningProcess> start(ProcessRequest request) async {
    final process = await Process.start(
      request.executable,
      request.arguments,
      workingDirectory: request.workingDirectory,
      environment: _safeEnvironment(parentEnvironment, request.environment),
      includeParentEnvironment: false,
      runInShell: false,
    );
    ProcessIdentity? rootIdentity;
    try {
      rootIdentity = await processControl
          .inspectIdentity(process.pid, timeout: helperTimeout)
          .timeout(helperTimeout);
    } on Object {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode.timeout(helperTimeout);
      rethrow;
    }
    return IoRunningProcess._(
      process,
      processControl: processControl,
      rootIdentity: rootIdentity,
      maxDiagnosticLines: maxDiagnosticLines,
      maxDiagnosticBytes: maxDiagnosticBytes,
      maxPendingOutputLines: maxPendingOutputLines,
      maxPendingOutputBytes: maxPendingOutputBytes,
      maxLineBytes: maxLineBytes,
      maxLineCharacters: maxLineCharacters,
      terminationGracePeriod: terminationGracePeriod,
      forceKillTimeout: forceKillTimeout,
      cancellationTimeout: cancellationTimeout,
      ownershipPollInterval: ownershipPollInterval,
      helperTimeout: helperTimeout,
    );
  }
}

final class IoRunningProcess implements RunningProcess {
  IoRunningProcess._(
    this._process, {
    required this.processControl,
    required ProcessIdentity? rootIdentity,
    required this.maxDiagnosticLines,
    required this.maxDiagnosticBytes,
    required this.maxPendingOutputLines,
    required this.maxPendingOutputBytes,
    required this.maxLineBytes,
    required this.maxLineCharacters,
    required this.terminationGracePeriod,
    required this.forceKillTimeout,
    required this.cancellationTimeout,
    required this.ownershipPollInterval,
    required this.helperTimeout,
  }) : _stdoutOutput = _BoundedLineOutput(
         maxPendingLines: maxPendingOutputLines,
         maxPendingBytes: maxPendingOutputBytes,
       ),
       _stderrOutput = _BoundedLineOutput(
         maxPendingLines: maxPendingOutputLines,
         maxPendingBytes: maxPendingOutputBytes,
       ),
       _stdoutDiagnostics = _BoundedLines(
         maxDiagnosticLines,
         maxDiagnosticBytes,
       ),
       _stderrDiagnostics = _BoundedLines(
         maxDiagnosticLines,
         maxDiagnosticBytes,
       ) {
    if (rootIdentity != null) _ownedIdentities.add(rootIdentity);
    _stdoutPump = _pump(
      _process.stdout,
      _stdoutOutput,
      _stdoutDiagnostics,
      maxLineBytes: maxLineBytes,
      maxLineCharacters: maxLineCharacters,
    );
    _stderrPump = _pump(
      _process.stderr,
      _stderrOutput,
      _stderrDiagnostics,
      maxLineBytes: maxLineBytes,
      maxLineCharacters: maxLineCharacters,
    );
    _rawExitCode = _process.exitCode.then((code) {
      _didExit = true;
      return code;
    });
    _publishedExitCode = _publishExitCode();
    unawaited(_monitorOwnership());
  }

  final Process _process;
  final ProcessControl processControl;
  final int maxDiagnosticLines;
  final int maxDiagnosticBytes;
  final int maxPendingOutputLines;
  final int maxPendingOutputBytes;
  final int maxLineBytes;
  final int maxLineCharacters;
  final Duration terminationGracePeriod;
  final Duration forceKillTimeout;
  final Duration cancellationTimeout;
  final Duration ownershipPollInterval;
  final Duration helperTimeout;
  final _BoundedLineOutput _stdoutOutput;
  final _BoundedLineOutput _stderrOutput;
  final _BoundedLines _stdoutDiagnostics;
  final _BoundedLines _stderrDiagnostics;
  late final Future<void> _stdoutPump;
  late final Future<void> _stderrPump;
  late final Future<int> _rawExitCode;
  late final Future<int> _publishedExitCode;
  final Set<ProcessIdentity> _ownedIdentities = {};
  Future<void>? _cancellation;
  var _cancellationRequested = false;
  var _didExit = false;
  var _stopOwnershipMonitor = false;

  static const outputTruncatedMarker = '[output truncated]';
  static const lineTruncatedMarker = BoundedUtf8LineDecoder.lineTruncatedMarker;

  @override
  int get pid => _process.pid;

  @override
  Stream<String> get stdoutLines => _stdoutOutput.stream;

  @override
  Stream<String> get stderrLines => _stderrOutput.stream;

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
    _stopOwnershipMonitor = true;
    final deadline = _Deadline(cancellationTimeout);
    if (processControl.isWindows) {
      await _cancelWindows(deadline);
    } else {
      await _cancelPosix(deadline);
    }
    await _publishedExitCode.timeout(deadline.remaining);
  }

  Future<void> _cancelWindows(_Deadline deadline) async {
    final rootIdentity = _rootIdentity;
    if (rootIdentity == null) {
      if (_didExit) return;
      throw StateError('Cannot safely cancel a process without its identity');
    }
    final current = await processControl
        .inspectIdentity(pid, timeout: deadline.remaining)
        .timeout(deadline.remaining);
    if (current == null) return;
    if (current != rootIdentity) {
      throw StateError('PID $pid no longer belongs to the started process');
    }
    final result = await processControl
        .terminateWindowsTree(pid, timeout: deadline.remaining)
        .timeout(deadline.remaining);
    if (result.exitCode == 0) return;

    final afterFailure = await processControl
        .inspectIdentity(pid, timeout: deadline.remaining)
        .timeout(deadline.remaining);
    if (afterFailure != rootIdentity) return;
    throw ProcessException(
      'taskkill.exe',
      ['/PID', '$pid', '/T', '/F'],
      result.stderrDiagnostics,
      result.exitCode,
    );
  }

  Future<void> _cancelPosix(_Deadline deadline) async {
    final gracefulDuration = terminationGracePeriod < deadline.remaining
        ? terminationGracePeriod
        : deadline.remaining;
    final terminated = await _cleanupPosixPhase(
      ProcessSignal.sigterm,
      phaseDeadline: _Deadline(gracefulDuration),
      overallDeadline: deadline,
    );
    if (terminated) return;

    final forceDuration = forceKillTimeout < deadline.remaining
        ? forceKillTimeout
        : deadline.remaining;
    final killed = await _cleanupPosixPhase(
      ProcessSignal.sigkill,
      phaseDeadline: _Deadline(forceDuration),
      overallDeadline: deadline,
    );
    if (!killed) {
      throw TimeoutException(
        'Process tree rooted at $pid did not terminate',
        cancellationTimeout,
      );
    }
  }

  Future<bool> _cleanupPosixPhase(
    ProcessSignal signal, {
    required _Deadline phaseDeadline,
    required _Deadline overallDeadline,
  }) async {
    var stableEmptyScans = 0;
    while (!phaseDeadline.expired && !overallDeadline.expired) {
      final timeout = _shorter(
        phaseDeadline.remaining,
        overallDeadline.remaining,
      );
      late final List<ProcessRecord> records;
      try {
        records = await processControl
            .inspectAll(timeout: timeout)
            .timeout(timeout);
      } on TimeoutException {
        if (phaseDeadline.expired && !overallDeadline.expired) return false;
        rethrow;
      }
      _recordOwnedDescendants(records);
      final liveOwned = records
          .where((record) => _ownedIdentities.contains(record.identity))
          .toList();
      if (liveOwned.isEmpty) {
        stableEmptyScans++;
        if (stableEmptyScans >= 2) return true;
      } else {
        stableEmptyScans = 0;
        final recordsByPid = {
          for (final record in records) record.identity.pid: record,
        };
        liveOwned.sort(
          (first, second) => _processDepth(
            second,
            recordsByPid,
          ).compareTo(_processDepth(first, recordsByPid)),
        );
        for (final record in liveOwned) {
          final signalTimeout = _shorter(
            phaseDeadline.remaining,
            overallDeadline.remaining,
          );
          try {
            await processControl
                .signal(record.identity, signal, timeout: signalTimeout)
                .timeout(signalTimeout);
          } on TimeoutException {
            if (phaseDeadline.expired && !overallDeadline.expired) return false;
            rethrow;
          }
        }
      }
      if (phaseDeadline.expired || overallDeadline.expired) return false;
      await Future<void>.delayed(
        _shorter(
          ownershipPollInterval,
          _shorter(phaseDeadline.remaining, overallDeadline.remaining),
        ),
      );
    }
    return false;
  }

  ProcessIdentity? get _rootIdentity =>
      _ownedIdentities.where((identity) => identity.pid == pid).firstOrNull;

  Future<void> _monitorOwnership() async {
    if (processControl.isWindows || _ownedIdentities.isEmpty) return;
    while (!_stopOwnershipMonitor) {
      try {
        final records = await processControl
            .inspectAll(timeout: helperTimeout)
            .timeout(helperTimeout);
        _recordOwnedDescendants(records);
      } on Object {
        // Cancellation performs its own strict, deadline-bound inspection.
      }
      if (_didExit) return;
      await Future<void>.delayed(ownershipPollInterval);
    }
  }

  void _recordOwnedDescendants(List<ProcessRecord> records) {
    final recordsByPid = {
      for (final record in records) record.identity.pid: record,
    };
    var changed = true;
    while (changed) {
      changed = false;
      for (final record in records) {
        if (_ownedIdentities.contains(record.identity)) continue;
        final parent = recordsByPid[record.parentPid];
        if (parent != null && _ownedIdentities.contains(parent.identity)) {
          _ownedIdentities.add(record.identity);
          changed = true;
        }
      }
    }
  }
}

Future<void> _pump(
  Stream<List<int>> bytes,
  _BoundedLineOutput output,
  _BoundedLines diagnostics, {
  required int maxLineBytes,
  required int maxLineCharacters,
}) async {
  final decoder = BoundedUtf8LineDecoder(
    maxLineBytes: maxLineBytes,
    maxLineCharacters: maxLineCharacters,
    onLine: (line) {
      diagnostics.add(line);
      output.add(line);
    },
  );
  try {
    await for (final chunk in bytes) {
      decoder.add(chunk);
    }
  } catch (error, stackTrace) {
    output.addError(error, stackTrace);
  } finally {
    decoder.close();
    output.close();
  }
}

int _processDepth(ProcessRecord record, Map<int, ProcessRecord> recordsByPid) {
  var depth = 0;
  var parentPid = record.parentPid;
  final visited = <int>{record.identity.pid};
  while (visited.add(parentPid)) {
    final parent = recordsByPid[parentPid];
    if (parent == null) break;
    depth++;
    parentPid = parent.parentPid;
  }
  return depth;
}

List<ProcessRecord> _parsePosixProcessRecords(String output) {
  final records = <ProcessRecord>[];
  for (final line in const LineSplitter().convert(output)) {
    final match = RegExp(r'^\s*(\d+)\s+(\d+)\s+(.+?)\s*$').firstMatch(line);
    if (match == null) continue;
    final pid = int.tryParse(match.group(1)!);
    final parentPid = int.tryParse(match.group(2)!);
    final startIdentity = match.group(3)!;
    if (pid == null || parentPid == null || startIdentity.isEmpty) continue;
    records.add(
      ProcessRecord(
        identity: ProcessIdentity(pid: pid, startIdentity: startIdentity),
        parentPid: parentPid,
      ),
    );
  }
  return records;
}

Duration _shorter(Duration first, Duration second) =>
    first < second ? first : second;

final class _Deadline {
  _Deadline(this.duration) : _stopwatch = Stopwatch()..start();

  final Duration duration;
  final Stopwatch _stopwatch;

  bool get expired => _stopwatch.elapsed >= duration;

  Duration get remaining {
    final value = duration - _stopwatch.elapsed;
    if (value <= Duration.zero) {
      throw TimeoutException('Operation deadline expired', duration);
    }
    return value;
  }
}

String _posixExecutable(String absolute, String fallback) =>
    File(absolute).existsSync() ? absolute : fallback;

String _taskkillExecutable(Map<String, String> environment) {
  final systemRoot = environment['SystemRoot'] ?? environment['WINDIR'];
  return systemRoot == null
      ? 'taskkill.exe'
      : '$systemRoot\\System32\\taskkill.exe';
}

String _tasklistExecutable(Map<String, String> environment) {
  final systemRoot = environment['SystemRoot'] ?? environment['WINDIR'];
  return systemRoot == null
      ? 'tasklist.exe'
      : '$systemRoot\\System32\\tasklist.exe';
}

const _safeParentEnvironmentKeys = {
  'PATH',
  'HOME',
  'TMPDIR',
  'TMP',
  'TEMP',
  'LANG',
  'LC_ALL',
  'LC_CTYPE',
  'TZ',
  'SystemRoot',
  'WINDIR',
  'COMSPEC',
  'PATHEXT',
  'USERPROFILE',
  'LOCALAPPDATA',
  'APPDATA',
};

Map<String, String> _safeEnvironment(
  Map<String, String> parent,
  Map<String, String> explicit,
) => {
  for (final key in _safeParentEnvironmentKeys) key: ?parent[key],
  ...explicit,
};

final class _BoundedByteTail {
  _BoundedByteTail(this.limit);

  final int limit;
  final Queue<int> _bytes = Queue();

  void add(List<int> bytes) {
    if (limit == 0) return;
    for (final byte in bytes) {
      if (_bytes.length == limit) _bytes.removeFirst();
      _bytes.addLast(byte);
    }
  }

  String get text => utf8.decode(_bytes.toList(), allowMalformed: true);
}

final class _BoundedLineOutput {
  _BoundedLineOutput({
    required this.maxPendingLines,
    required this.maxPendingBytes,
  }) {
    _controller = StreamController<String>(
      sync: true,
      onListen: _onListen,
      onPause: _onPause,
      onResume: _onResume,
      onCancel: _onCancel,
    );
  }

  final int maxPendingLines;
  final int maxPendingBytes;
  final Queue<_BufferedLine> _pending = Queue();
  late final StreamController<String> _controller;
  var _pendingBytes = 0;
  var _hasListener = false;
  var _paused = false;
  var _cancelled = false;
  var _done = false;
  var _truncated = false;

  Stream<String> get stream => _controller.stream;

  void add(String line) {
    if (_cancelled) return;
    if (_hasListener && !_paused) {
      _controller.add(line);
      return;
    }
    _buffer(line);
  }

  void addError(Object error, StackTrace stackTrace) {
    if (_cancelled) return;
    if (_hasListener && !_paused) {
      _controller.addError(error, stackTrace);
      return;
    }
    _truncated = true;
  }

  void close() {
    _done = true;
    if (_hasListener && !_paused && !_cancelled) {
      unawaited(_controller.close());
    }
  }

  void _buffer(String line) {
    final byteLength = utf8.encode(line).length;
    if (maxPendingLines == 0 ||
        maxPendingBytes == 0 ||
        byteLength > maxPendingBytes) {
      _truncated = true;
      return;
    }
    while (_pending.isNotEmpty &&
        (_pending.length >= maxPendingLines ||
            _pendingBytes + byteLength > maxPendingBytes)) {
      _pendingBytes -= _pending.removeFirst().byteLength;
      _truncated = true;
    }
    _pending.addLast(_BufferedLine(line, byteLength));
    _pendingBytes += byteLength;
  }

  void _onListen() {
    _hasListener = true;
    _flush();
  }

  void _onPause() => _paused = true;

  void _onResume() {
    _paused = false;
    _flush();
  }

  void _onCancel() {
    _cancelled = true;
    _pending.clear();
    _pendingBytes = 0;
  }

  void _flush() {
    if (_cancelled || !_hasListener || _paused) return;
    if (_truncated) {
      _controller.add(IoRunningProcess.outputTruncatedMarker);
      _truncated = false;
    }
    while (_pending.isNotEmpty && !_paused && !_cancelled) {
      final line = _pending.removeFirst();
      _pendingBytes -= line.byteLength;
      _controller.add(line.value);
    }
    if (_done && !_paused && !_cancelled) {
      unawaited(_controller.close());
    }
  }
}

final class _BufferedLine {
  const _BufferedLine(this.value, this.byteLength);

  final String value;
  final int byteLength;
}

final class _BoundedLines {
  _BoundedLines(this.lineLimit, this.byteLimit);

  final int lineLimit;
  final int byteLimit;
  final Queue<_BufferedLine> _lines = Queue();
  var _bytes = 0;

  void add(String line) {
    if (lineLimit == 0 || byteLimit == 0) return;
    final byteLength = utf8.encode(line).length;
    if (byteLength > byteLimit) return;
    while (_lines.isNotEmpty &&
        (_lines.length >= lineLimit || _bytes + byteLength > byteLimit)) {
      _bytes -= _lines.removeFirst().byteLength;
    }
    _lines.addLast(_BufferedLine(line, byteLength));
    _bytes += byteLength;
  }

  List<String> get snapshot =>
      List.unmodifiable(_lines.map((line) => line.value));
}
