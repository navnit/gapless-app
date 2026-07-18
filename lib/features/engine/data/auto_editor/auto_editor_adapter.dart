import 'dart:async';
import 'dart:io';

import 'package:gapless/core/errors/app_failure.dart';
import 'package:gapless/core/process/process_runner.dart';
import 'package:gapless/features/editor/domain/analysis_settings.dart';
import 'package:gapless/features/engine/data/auto_editor/auto_editor_locator.dart';
import 'package:gapless/features/engine/data/auto_editor/auto_editor_output_collector.dart';
import 'package:gapless/features/engine/data/auto_editor/auto_editor_parsers.dart';
import 'package:gapless/features/engine/data/auto_editor/v3_codec.dart';
import 'package:gapless/features/engine/domain/engine_models.dart';
import 'package:gapless/features/engine/domain/engine_port.dart';
import 'package:path/path.dart' as p;

typedef TemporaryPathFactory = Future<Uri> Function(String extension);

/// Process adapter for the pinned Auto-Editor 31.2.0 command contract.
final class AutoEditorAdapter implements EnginePort {
  AutoEditorAdapter({
    required this.processRunner,
    required this.executableLocator,
    required this.temporaryPathFactory,
  });

  final ProcessRunner processRunner;
  final AutoEditorExecutableLocator executableLocator;
  final TemporaryPathFactory temporaryPathFactory;

  @override
  EngineTask<MediaMetadata> probe(Uri source) =>
      _task('probe', (context) async {
        final sourcePath = _absoluteFilePath(source, 'source');
        context.report(EngineStage.probing);
        return _probeMetadata(context, sourcePath, operation: 'probe');
      });

  @override
  EngineTask<AnalysisLevels> levels(Uri source, AnalysisMethod method) =>
      _task('levels', (context) async {
        final sourcePath = _absoluteFilePath(source, 'source');
        context.report(EngineStage.analyzing);
        final metadata = await _probeMetadata(
          context,
          sourcePath,
          operation: 'levels',
        );
        final timebase = _upstreamTimebase(metadata);
        final samplePeriodUs = _roundDiv(
          metadata.timebaseNumerator * Duration.microsecondsPerSecond,
          metadata.timebaseDenominator,
        );
        final methodExpression = switch (method) {
          AnalysisMethod.audio => 'audio',
          AnalysisMethod.motion => 'motion',
        };
        final output = await _runForMedia(
          context,
          [
            'levels',
            sourcePath,
            '--edit',
            methodExpression,
            '--timebase',
            timebase,
          ],
          operation: 'levels',
          source: source,
          retainStdout: true,
        );
        try {
          return AutoEditorParsers.parseLevels(
            output.stdout,
            samplePeriodUs: samplePeriodUs,
          );
        } on FormatException catch (error) {
          throw EngineContractFailure(
            operation: 'levels',
            reason: EngineContractReason.invalidOutput,
            diagnostics: _boundedDiagnostics([
              ...output.diagnostics,
              error.toString(),
            ]),
          );
        }
      });

  @override
  EngineTask<DetectedTimeline> detect(Uri source, AnalysisSettings settings) =>
      _task('detect', (context) async {
        _validateSettings(settings);
        final sourcePath = _absoluteFilePath(source, 'source');
        final temporaryUri = await temporaryPathFactory('.v3');
        final temporaryPath = _absoluteFilePath(temporaryUri, 'temporary v3');
        final temporary = File(temporaryPath);
        context.report(EngineStage.buildingTimeline);
        try {
          final metadata = await _probeMetadata(
            context,
            sourcePath,
            operation: 'detect',
          );
          final arguments = <String>[
            sourcePath,
            '--edit',
            '${_methodName(settings.method)}:'
                '${_formatNumber(settings.thresholdDb)}dB',
            '--margin',
            '${_formatSeconds(settings.marginBeforeUs)},'
                '${_formatSeconds(settings.marginAfterUs)}',
            if (settings.inactiveBehavior == InactiveBehavior.fastForward) ...[
              '--when-inactive',
              'speed:${_formatNumber(settings.fastForwardRate)}',
            ],
            '--export',
            'v3',
            '-o',
            temporaryPath,
          ];
          await _runForMedia(
            context,
            arguments,
            operation: 'detect',
            source: source,
          );
          context.throwIfCancelled();
          final text = await temporary.readAsString();
          context.throwIfCancelled();
          try {
            return V3Codec().decodeDetected(
              text,
              sourceDurationUs: metadata.durationUs,
            );
          } on EngineContractFailure catch (failure) {
            throw EngineContractFailure(
              operation: 'detect',
              reason: failure.reason,
              exitCode: failure.exitCode,
              diagnostics: failure.diagnostics,
            );
          }
        } finally {
          if (await temporary.exists()) await temporary.delete();
        }
      });

  @override
  EngineTask<Uri> render(RenderRequest request) =>
      _task('render', (context) async {
        final sourcePath = _absoluteFilePath(request.source, 'source');
        final destinationPath = _absoluteFilePath(
          request.partialDestination,
          'partialDestination',
        );
        final temporaryUri = await temporaryPathFactory('.v3');
        final temporaryPath = _absoluteFilePath(temporaryUri, 'temporary v3');
        final temporary = File(temporaryPath);
        final destination = File(destinationPath);
        if (await destination.exists()) {
          throw ArgumentError.value(
            request.partialDestination,
            'partialDestination',
            'must not already exist',
          );
        }
        var succeeded = false;
        try {
          final encoded = V3Codec().encodeEffective(
            request.timeline,
            request.metadata,
            source: Uri.file(sourcePath),
          );
          await temporary.writeAsString(encoded, flush: true);
          context.throwIfCancelled();
          context.report(EngineStage.rendering);
          await _run(
            context,
            [
              temporaryPath,
              '-o',
              destinationPath,
              ..._encodingArguments(request.preset),
            ],
            operation: 'render',
            progressStage: EngineStage.rendering,
          );
          context.throwIfCancelled();
          context.report(EngineStage.writing);
          succeeded = true;
          return request.partialDestination;
        } finally {
          if (await temporary.exists()) await temporary.delete();
          if (!succeeded && await destination.exists()) {
            await destination.delete();
          }
        }
      });

  _AdapterTask<T> _task<T>(
    String operation,
    Future<T> Function(_TaskContext context) body,
  ) => _AdapterTask<T>(operation: operation, body: body);

  Future<MediaMetadata> _probeMetadata(
    _TaskContext context,
    String sourcePath, {
    required String operation,
  }) async {
    final output = await _run(
      context,
      ['info', sourcePath, '--json'],
      operation: operation,
      retainStdout: true,
    );
    try {
      return AutoEditorParsers.parseInfoJson(output.stdout);
    } on FormatException catch (error) {
      throw EngineContractFailure(
        operation: operation,
        reason: EngineContractReason.invalidOutput,
        diagnostics: _boundedDiagnostics([
          ...output.diagnostics,
          error.toString(),
        ]),
      );
    }
  }

  Future<_ProcessOutput> _run(
    _TaskContext context,
    List<String> arguments, {
    required String operation,
    EngineStage? progressStage,
    bool retainStdout = false,
  }) async {
    context.throwIfCancelled();
    final executable = await executableLocator.locate();
    context.throwIfCancelled();
    final process = await processRunner.start(
      ProcessRequest(executable: executable, arguments: arguments),
    );
    context.attach(process);
    context.throwIfCancelled();
    final output = AutoEditorOutputCollector(retainStdout: retainStdout);
    final stdout = _collectLines(process.stdoutLines, onLine: output.addStdout);
    final stderr = _collectLines(
      process.stderrLines,
      onLine: (line) {
        output.addStderr(line);
        if (progressStage != null) {
          final parsed = _parseProgress(line, progressStage);
          if (parsed != null) {
            context.report(
              parsed.stage,
              percent: parsed.percent,
              eta: parsed.eta,
            );
          }
        }
      },
    );
    final exitCode = await process.exitCode;
    await stdout;
    await stderr;
    context.throwIfCancelled();
    final diagnostics = output.diagnostics;
    if (exitCode != 0) {
      throw EngineContractFailure(
        operation: operation,
        reason: EngineContractReason.unexpectedExit,
        exitCode: exitCode,
        diagnostics: diagnostics,
      );
    }
    return _ProcessOutput(stdout: output.stdout, diagnostics: diagnostics);
  }

  Future<_ProcessOutput> _runForMedia(
    _TaskContext context,
    List<String> arguments, {
    required String operation,
    required Uri source,
    bool retainStdout = false,
  }) async {
    try {
      return await _run(
        context,
        arguments,
        operation: operation,
        retainStdout: retainStdout,
      );
    } on EngineContractFailure catch (failure) {
      if (failure.reason == EngineContractReason.unexpectedExit &&
          failure.diagnostics.any(
            (line) => line.toLowerCase().contains('no audio stream'),
          )) {
        throw MediaReadFailure(
          source: source,
          reason: MediaReadReason.noAudio,
          diagnostics: failure.diagnostics,
        );
      }
      rethrow;
    }
  }
}

List<String> _encodingArguments(RenderPreset preset) => switch (preset) {
  RenderPreset.smaller => const [
    '-c:v',
    'libx264',
    '-crf',
    '28',
    '-preset',
    'medium',
    '-c:a',
    'aac',
    '-layout',
    'stereo',
    '-b:a',
    '128k',
  ],
  RenderPreset.balanced => const [
    '-c:v',
    'libx264',
    '-crf',
    '23',
    '-preset',
    'medium',
    '-c:a',
    'aac',
    '-layout',
    'stereo',
    '-b:a',
    '192k',
  ],
  RenderPreset.higherQuality => const [
    '-c:v',
    'libx264',
    '-crf',
    '18',
    '-preset',
    'slow',
    '-c:a',
    'aac',
    '-layout',
    'stereo',
    '-b:a',
    '256k',
  ],
};

Future<void> _collectLines(
  Stream<String> stream, {
  required void Function(String line) onLine,
}) async {
  await for (final line in stream) {
    onLine(line);
  }
}

EngineProgress? _parseProgress(String line, EngineStage stage) {
  final percentMatch = RegExp(r'(\d{1,3}(?:\.\d+)?)%').firstMatch(line);
  if (percentMatch == null) return null;
  final percent = double.tryParse(percentMatch.group(1)!);
  if (percent == null || !percent.isFinite || percent < 0 || percent > 100) {
    return null;
  }
  Duration? eta;
  final etaMatch = RegExp(
    r'ETA\s+(?:(\d+):)?(\d{1,2}):(\d{2})',
  ).firstMatch(line);
  if (etaMatch != null) {
    final hours = int.tryParse(etaMatch.group(1) ?? '0');
    final minutes = int.tryParse(etaMatch.group(2)!);
    final seconds = int.tryParse(etaMatch.group(3)!);
    if (hours != null &&
        minutes != null &&
        seconds != null &&
        minutes < 60 &&
        seconds < 60) {
      eta = Duration(hours: hours, minutes: minutes, seconds: seconds);
    }
  }
  return EngineProgress(stage: stage, percent: percent, eta: eta);
}

void _validateSettings(AnalysisSettings settings) {
  if (!settings.thresholdDb.isFinite ||
      settings.thresholdDb < -120 ||
      settings.thresholdDb > 0) {
    throw ArgumentError.value(settings.thresholdDb, 'thresholdDb');
  }
  if (settings.marginBeforeUs < 0) {
    throw ArgumentError.value(settings.marginBeforeUs, 'marginBeforeUs');
  }
  if (settings.marginAfterUs < 0) {
    throw ArgumentError.value(settings.marginAfterUs, 'marginAfterUs');
  }
  if (settings.inactiveBehavior == InactiveBehavior.fastForward &&
      (!settings.fastForwardRate.isFinite ||
          settings.fastForwardRate <= 1 ||
          settings.fastForwardRate >= 99999)) {
    throw ArgumentError.value(settings.fastForwardRate, 'fastForwardRate');
  }
}

String _methodName(AnalysisMethod method) => switch (method) {
  AnalysisMethod.audio => 'audio',
  AnalysisMethod.motion => 'motion',
};

String _formatSeconds(int microseconds) {
  final seconds = microseconds ~/ Duration.microsecondsPerSecond;
  final remainder = microseconds % Duration.microsecondsPerSecond;
  if (remainder == 0) return '${seconds}s';
  final fraction = remainder
      .toString()
      .padLeft(6, '0')
      .replaceFirst(RegExp(r'0+$'), '');
  return '$seconds.${fraction}s';
}

String _formatNumber(double value) {
  final normalized = value == 0 ? 0.0 : value;
  final text = normalized.toString();
  if (!text.contains('e') && !text.contains('E')) {
    return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
  }
  return normalized
      .toStringAsFixed(12)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

String _upstreamTimebase(MediaMetadata metadata) {
  final divisor = _gcd(
    metadata.timebaseDenominator,
    metadata.timebaseNumerator,
  );
  return '${metadata.timebaseDenominator ~/ divisor}/'
      '${metadata.timebaseNumerator ~/ divisor}';
}

int _roundDiv(int numerator, int denominator) {
  if (numerator < 0 || denominator <= 0) {
    throw const FormatException('Invalid rational timebase');
  }
  final result = (numerator + denominator ~/ 2) ~/ denominator;
  if (result <= 0 || result > 0x7fffffffffffffff) {
    throw const FormatException('Timebase conversion overflow');
  }
  return result;
}

int _gcd(int first, int second) {
  var a = first.abs();
  var b = second.abs();
  while (b != 0) {
    final remainder = a % b;
    a = b;
    b = remainder;
  }
  return a;
}

String _absoluteFilePath(Uri uri, String name) {
  if (!uri.isScheme('file')) throw ArgumentError.value(uri, name);
  final path = uri.toFilePath();
  if (!p.isAbsolute(path)) throw ArgumentError.value(uri, name);
  return path;
}

List<String> _boundedDiagnostics(Iterable<String> lines) {
  const maxLines = 40;
  const maxCharacters = 8192;
  final result = <String>[];
  var characters = 0;
  for (final raw in lines) {
    if (result.length == maxLines || characters == maxCharacters) break;
    final line = raw.replaceAll(RegExp(r'[\r\n]+'), ' ');
    final available = maxCharacters - characters;
    final bounded = line.length <= available
        ? line
        : '${line.substring(0, available > 1 ? available - 1 : 0)}…';
    result.add(bounded);
    characters += bounded.length;
  }
  return result;
}

final class _ProcessOutput {
  const _ProcessOutput({required this.stdout, required this.diagnostics});

  final String stdout;
  final List<String> diagnostics;
}

final class _TaskContext {
  _TaskContext(this.operation, this.progress);

  final String operation;
  final StreamController<EngineProgress> progress;
  RunningProcess? _running;
  var _cancelled = false;
  Future<void>? _cancelFuture;
  Future<void>? _runningCancelFuture;
  final _runningOrFinished = Completer<RunningProcess?>();
  final _finished = Completer<void>();

  void report(EngineStage stage, {double? percent, Duration? eta}) {
    if (!progress.isClosed) {
      progress.add(EngineProgress(stage: stage, percent: percent, eta: eta));
    }
  }

  void attach(RunningProcess process) {
    _running = process;
    if (!_runningOrFinished.isCompleted) {
      _runningOrFinished.complete(process);
    }
  }

  Future<void> cancel() {
    final cancellation = _cancelFuture;
    if (cancellation != null) return cancellation;
    if (_finished.isCompleted) return Future<void>.value();
    _cancelled = true;
    return _cancelFuture ??= _cancelAndWait();
  }

  Future<void> _cancelAndWait() async {
    final running = _running ?? await _runningOrFinished.future;
    if (running != null) await _cancelRunning(running);
    await _finished.future;
  }

  Future<void> _cancelRunning(RunningProcess process) =>
      _runningCancelFuture ??= process.cancel();

  void finish() {
    if (!_runningOrFinished.isCompleted) {
      _runningOrFinished.complete(null);
    }
    if (!_finished.isCompleted) _finished.complete();
  }

  void throwIfCancelled() {
    if (_cancelled) throw OperationCancelled(operation: operation);
  }
}

final class _AdapterTask<T> implements EngineTask<T> {
  _AdapterTask({
    required String operation,
    required Future<T> Function(_TaskContext context) body,
  }) : _progressController = StreamController<EngineProgress>.broadcast() {
    _context = _TaskContext(operation, _progressController);
    Future<void>(() async {
      try {
        _context.throwIfCancelled();
        final value = await body(_context);
        _context.throwIfCancelled();
        if (!_result.isCompleted) _result.complete(value);
      } on Object catch (error, stackTrace) {
        if (!_result.isCompleted) _result.completeError(error, stackTrace);
      } finally {
        unawaited(_progressController.close());
        _context.finish();
      }
    });
  }

  final StreamController<EngineProgress> _progressController;
  final Completer<T> _result = Completer<T>();
  late final _TaskContext _context;

  @override
  Stream<EngineProgress> get progress => _progressController.stream;

  @override
  Future<T> get result => _result.future;

  @override
  Future<void> cancel() => _context.cancel();
}
