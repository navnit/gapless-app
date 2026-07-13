import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:gapless/core/process/bounded_utf8_line_decoder.dart';
import 'package:gapless/core/process/native_process_host.dart';
import 'package:gapless/core/process/process_runner.dart';

final class IoProcessRunner implements ProcessRunner {
  IoProcessRunner({
    NativeProcessHost? nativeProcessHost,
    this.maxDiagnosticLines = 200,
    this.maxDiagnosticBytes = 64 * 1024,
    this.maxPendingOutputLines = 256,
    this.maxPendingOutputBytes = 64 * 1024,
    this.maxLineBytes = 16 * 1024,
    this.maxLineCharacters = 16 * 1024,
    this.terminationGracePeriod = const Duration(seconds: 2),
    this.forceKillTimeout = const Duration(seconds: 5),
    this.cancellationTimeout = const Duration(seconds: 7),
    Map<String, String>? parentEnvironment,
  }) : nativeProcessHost = nativeProcessHost ?? NativeProcessHost(),
       parentEnvironment = Map.unmodifiable(
         parentEnvironment ?? Platform.environment,
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
  }

  final NativeProcessHost nativeProcessHost;
  final int maxDiagnosticLines;
  final int maxDiagnosticBytes;
  final int maxPendingOutputLines;
  final int maxPendingOutputBytes;
  final int maxLineBytes;
  final int maxLineCharacters;
  final Duration terminationGracePeriod;
  final Duration forceKillTimeout;
  final Duration cancellationTimeout;
  final Map<String, String> parentEnvironment;

  @override
  Future<IoRunningProcess> start(ProcessRequest request) async {
    final process = await nativeProcessHost.start(
      request,
      environment: _safeEnvironment(parentEnvironment, request.environment),
      terminationGracePeriod: terminationGracePeriod,
      forceKillTimeout: forceKillTimeout,
    );
    return IoRunningProcess._(
      process,
      maxDiagnosticLines: maxDiagnosticLines,
      maxDiagnosticBytes: maxDiagnosticBytes,
      maxPendingOutputLines: maxPendingOutputLines,
      maxPendingOutputBytes: maxPendingOutputBytes,
      maxLineBytes: maxLineBytes,
      maxLineCharacters: maxLineCharacters,
      cancellationTimeout: cancellationTimeout,
    );
  }
}

final class IoRunningProcess implements RunningProcess {
  IoRunningProcess._(
    this._process, {
    required this.maxDiagnosticLines,
    required this.maxDiagnosticBytes,
    required this.maxPendingOutputLines,
    required this.maxPendingOutputBytes,
    required this.maxLineBytes,
    required this.maxLineCharacters,
    required this.cancellationTimeout,
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
    _rawExitCode = _process.exitCode;
    _publishedExitCode = _publishExitCode();
  }

  final Process _process;
  final int maxDiagnosticLines;
  final int maxDiagnosticBytes;
  final int maxPendingOutputLines;
  final int maxPendingOutputBytes;
  final int maxLineBytes;
  final int maxLineCharacters;
  final Duration cancellationTimeout;
  final _BoundedLineOutput _stdoutOutput;
  final _BoundedLineOutput _stderrOutput;
  final _BoundedLines _stdoutDiagnostics;
  final _BoundedLines _stderrDiagnostics;
  late final Future<void> _stdoutPump;
  late final Future<void> _stderrPump;
  late final Future<int> _rawExitCode;
  late final Future<int> _publishedExitCode;
  Future<void>? _cancellation;
  var _cancellationRequested = false;

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
    final deadline = _Deadline(cancellationTimeout);
    try {
      _process.stdin.write(NativeProcessHost.controlCancelMessage);
      await _process.stdin.flush().timeout(deadline.remaining);
    } on Object {
      // An already-closing host still provides the authoritative exit result.
    }
    try {
      await _process.stdin.close().timeout(deadline.remaining);
    } on Object {
      // EOF or host exit has already closed the private control channel.
    }
    await _publishedExitCode.timeout(deadline.remaining);
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

final class _Deadline {
  _Deadline(this.duration) : _stopwatch = Stopwatch()..start();

  final Duration duration;
  final Stopwatch _stopwatch;

  Duration get remaining {
    final value = duration - _stopwatch.elapsed;
    if (value <= Duration.zero) {
      throw TimeoutException('Operation deadline expired', duration);
    }
    return value;
  }
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
