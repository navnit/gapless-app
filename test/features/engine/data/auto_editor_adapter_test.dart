import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/core/errors/app_failure.dart';
import 'package:gapless/core/process/process_runner.dart';
import 'package:gapless/core/time/source_time_range.dart';
import 'package:gapless/features/editor/domain/analysis_settings.dart';
import 'package:gapless/features/editor/domain/effective_timeline.dart';
import 'package:gapless/features/editor/domain/timeline_segment.dart';
import 'package:gapless/features/engine/data/auto_editor/auto_editor_adapter.dart';
import 'package:gapless/features/engine/data/auto_editor/auto_editor_locator.dart';
import 'package:gapless/features/engine/domain/engine_models.dart';

void main() {
  late Directory temp;
  late FakeProcessRunner runner;
  late AutoEditorAdapter adapter;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('gapless-adapter-test-');
    runner = FakeProcessRunner();
    adapter = AutoEditorAdapter(
      processRunner: runner,
      executableLocator: const FakeExecutableLocator('/bundle/auto-editor'),
      temporaryPathFactory: (extension) async =>
          Uri.file('${temp.path}/temporary$extension'),
    );
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test(
    'probe uses exact discrete arguments and reports its owned stage',
    () async {
      runner.enqueue(FakeRunningProcess(stdout: _fixtureText('info.json')));
      final source = Uri.file('/absolute/source with spaces.mp4');

      final task = adapter.probe(source);
      final progress = task.progress.toList();
      final result = await task.result;

      expect(result.durationUs, 42_400_000);
      expect(runner.requests.single.executable, '/bundle/auto-editor');
      expect(runner.requests.single.arguments, [
        'info',
        source.toFilePath(),
        '--json',
      ]);
      expect(await progress, [EngineProgress(stage: EngineStage.probing)]);
      expect(identical(task.result, task.result), isTrue);
    },
  );

  test('levels probes then supplies exact non-30 rational timebase', () async {
    runner
      ..enqueue(FakeRunningProcess(stdout: _infoWithTimebase('24000/1001')))
      ..enqueue(FakeRunningProcess(stdout: '@start\n0.0\n0.5\n1.0\n'));
    final source = Uri.file('/absolute/non-30.mp4');

    final task = adapter.levels(source, AnalysisMethod.audio);
    final progress = task.progress.toList();
    final result = await task.result;

    expect(result.samplePeriodUs, 41_708);
    expect(result.samples, [0, 32768, 65535]);
    expect(runner.requests.map((request) => request.arguments), [
      ['info', source.toFilePath(), '--json'],
      [
        'levels',
        source.toFilePath(),
        '--edit',
        'audio',
        '--timebase',
        '24000/1001',
      ],
    ]);
    expect(await progress, [EngineProgress(stage: EngineStage.analyzing)]);
  });

  test('levels preserves exact 30/1 timing and motion expression', () async {
    runner
      ..enqueue(FakeRunningProcess(stdout: _fixtureText('info.json')))
      ..enqueue(FakeRunningProcess(stdout: '@start\n0.25\n'));
    final source = Uri.file('/absolute/30fps.mp4');

    final result = await adapter.levels(source, AnalysisMethod.motion).result;

    expect(result.samplePeriodUs, 33_333);
    expect(runner.requests.last.arguments, [
      'levels',
      source.toFilePath(),
      '--edit',
      'motion',
      '--timebase',
      '30/1',
    ]);
  });

  test('levels maps invalid probed timebase to a structured failure', () async {
    runner.enqueue(FakeRunningProcess(stdout: _infoWithTimebase('30/0')));

    await expectLater(
      adapter
          .levels(Uri.file('/absolute/invalid.mp4'), AnalysisMethod.audio)
          .result,
      throwsA(
        isA<EngineContractFailure>()
            .having((failure) => failure.operation, 'operation', 'levels')
            .having(
              (failure) => failure.reason,
              'reason',
              EngineContractReason.invalidOutput,
            ),
      ),
    );
    expect(runner.requests, hasLength(1));
  });

  test(
    'levels maps Auto-Editor no-audio exit to typed media failure',
    () async {
      runner
        ..enqueue(FakeRunningProcess(stdout: _fixtureText('info.json')))
        ..enqueue(
          FakeRunningProcess(code: 1, stderr: 'Error! No audio stream'),
        );
      final source = Uri.file('/absolute/video-only.mp4');

      await expectLater(
        adapter.levels(source, AnalysisMethod.audio).result,
        throwsA(
          isA<MediaReadFailure>()
              .having((failure) => failure.source, 'source', source)
              .having(
                (failure) => failure.reason,
                'reason',
                MediaReadReason.noAudio,
              ),
        ),
      );
    },
  );

  test('levels and detected v3 use compatible non-30 tick timing', () async {
    final source = Uri.file('/absolute/non-30-compatible.mp4');
    final info = _infoWithTimebase('24000/1001');
    final temporaryV3 = File('${temp.path}/temporary.v3');
    final v3 =
        '''
{
  "version":"3","templateFile":"${source.toFilePath()}",
  "timebase":"24000/1001","background":"#000000",
  "resolution":[1280,720],"samplerate":48000,"layout":"stereo",
  "langs":["und","und"],
  "v":[[{"src":"${source.toFilePath()}","start":0,"dur":10,"offset":0,"stream":0}]],
  "a":[[{"src":"${source.toFilePath()}","start":0,"dur":10,"offset":0,"stream":0}]]
}
''';
    runner
      ..enqueue(FakeRunningProcess(stdout: info))
      ..enqueue(FakeRunningProcess(stdout: '@start\n0.5\n'))
      ..enqueue(FakeRunningProcess(stdout: info))
      ..enqueue(
        FakeRunningProcess(onStart: (_) => temporaryV3.writeAsStringSync(v3)),
      );

    final levels = await adapter.levels(source, AnalysisMethod.audio).result;
    final detected = await adapter
        .detect(
          source,
          AnalysisSettings(
            method: AnalysisMethod.audio,
            thresholdDb: -19,
            marginBeforeUs: 0,
            marginAfterUs: 0,
            inactiveBehavior: InactiveBehavior.cut,
          ),
        )
        .result;

    final detectedTickUs = detected.segments.first.range.endUs ~/ 10;
    expect(
      (detectedTickUs - levels.samplePeriodUs).abs(),
      lessThanOrEqualTo(1),
    );
    expect(runner.requests[1].arguments.last, '24000/1001');
  });

  test(
    'detect probes then uses exact validated cut arguments and cleans v3',
    () async {
      final source = Uri.file('/absolute/source with spaces.mp4');
      final temporaryV3 = File('${temp.path}/temporary.v3');
      runner
        ..enqueue(FakeRunningProcess(stdout: _fixtureText('info.json')))
        ..enqueue(
          FakeRunningProcess(
            onStart: (request) => temporaryV3.writeAsStringSync(
              _fixtureText(
                'detected.v3',
              ).replaceAll('example.mp4', source.toFilePath()),
            ),
          ),
        );
      final settings = AnalysisSettings(
        method: AnalysisMethod.audio,
        thresholdDb: -19,
        marginBeforeUs: 200_000,
        marginAfterUs: 200_000,
        inactiveBehavior: InactiveBehavior.cut,
      );

      final task = adapter.detect(source, settings);
      final progress = task.progress.toList();
      final result = await task.result;

      expect(result.durationUs, 42_400_000);
      expect(runner.requests.map((request) => request.arguments), [
        ['info', source.toFilePath(), '--json'],
        [
          source.toFilePath(),
          '--edit',
          'audio:-19dB',
          '--margin',
          '0.2s,0.2s',
          '--export',
          'v3',
          '-o',
          temporaryV3.path,
        ],
      ]);
      expect(await progress, [
        EngineProgress(stage: EngineStage.buildingTimeline),
      ]);
      expect(temporaryV3.existsSync(), isFalse);
    },
  );

  test(
    'detect formats motion, margins, and non-integer speed without locale',
    () async {
      final source = Uri.file('/absolute/motion.mp4');
      final temporaryV3 = File('${temp.path}/temporary.v3');
      runner
        ..enqueue(FakeRunningProcess(stdout: _fixtureText('info.json')))
        ..enqueue(
          FakeRunningProcess(
            onStart: (_) =>
                temporaryV3.writeAsStringSync(_fixtureText('detected.v3')),
          ),
        );
      final settings = AnalysisSettings(
        method: AnalysisMethod.motion,
        thresholdDb: -19.25,
        marginBeforeUs: 1,
        marginAfterUs: 1_234_567,
        inactiveBehavior: InactiveBehavior.fastForward,
        fastForwardRate: 2.5,
      );

      await adapter.detect(source, settings).result;

      expect(runner.requests.last.arguments, [
        source.toFilePath(),
        '--edit',
        'motion:-19.25dB',
        '--margin',
        '0.000001s,1.234567s',
        '--when-inactive',
        'speed:2.5',
        '--export',
        'v3',
        '-o',
        temporaryV3.path,
      ]);
    },
  );

  test(
    'detect rejects invalid dB, margins, and rates before a process',
    () async {
      final source = Uri.file('/absolute/invalid-settings.mp4');
      final invalid = [
        AnalysisSettings(
          method: AnalysisMethod.audio,
          thresholdDb: double.nan,
          marginBeforeUs: 0,
          marginAfterUs: 0,
          inactiveBehavior: InactiveBehavior.cut,
        ),
        AnalysisSettings(
          method: AnalysisMethod.audio,
          thresholdDb: -19,
          marginBeforeUs: -1,
          marginAfterUs: 0,
          inactiveBehavior: InactiveBehavior.cut,
        ),
        AnalysisSettings(
          method: AnalysisMethod.audio,
          thresholdDb: -19,
          marginBeforeUs: 0,
          marginAfterUs: 0,
          inactiveBehavior: InactiveBehavior.fastForward,
          fastForwardRate: 1,
        ),
      ];

      for (final settings in invalid) {
        await expectLater(
          adapter.detect(source, settings).result,
          throwsArgumentError,
        );
      }
      expect(runner.requests, isEmpty);
    },
  );

  test(
    'render writes v3, uses exact balanced args, and reports progress',
    () async {
      final source = Uri.file('/absolute/source.mp4');
      final destination = Uri.file('${temp.path}/result.partial.mp4');
      final temporaryV3 = File('${temp.path}/temporary.v3');
      runner.enqueue(
        FakeRunningProcess(
          stderr: 'Rendering 42.5% ETA 00:10',
          onStart: (_) => File(destination.toFilePath()).writeAsBytesSync([1]),
        ),
      );
      final request = _renderRequest(
        source: source,
        destination: destination,
        preset: RenderPreset.balanced,
      );

      final task = adapter.render(request);
      final progress = task.progress.toList();
      final result = await task.result;

      expect(result, destination);
      expect(temporaryV3.existsSync(), isFalse);
      expect(runner.requests.single.arguments, [
        temporaryV3.path,
        '-o',
        destination.toFilePath(),
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
      ]);
      expect(await progress, [
        EngineProgress(stage: EngineStage.rendering),
        EngineProgress(
          stage: EngineStage.rendering,
          percent: 42.5,
          eta: const Duration(seconds: 10),
        ),
        EngineProgress(stage: EngineStage.writing),
      ]);
    },
  );

  test('render preset arrays are fixed and exhaustive', () async {
    final expected = {
      RenderPreset.smaller: ['28', 'medium', '128k'],
      RenderPreset.balanced: ['23', 'medium', '192k'],
      RenderPreset.higherQuality: ['18', 'slow', '256k'],
    };

    for (final entry in expected.entries) {
      runner.enqueue(FakeRunningProcess());
      await adapter
          .render(
            _renderRequest(
              source: Uri.file('/absolute/source.mp4'),
              destination: Uri.file(
                '${temp.path}/${entry.key.name}.partial.mp4',
              ),
              preset: entry.key,
            ),
          )
          .result;
      final arguments = runner.requests.last.arguments;
      expect(arguments[6], entry.value[0]);
      expect(arguments[8], entry.value[1]);
      expect(arguments[12], 'stereo');
      expect(arguments[14], entry.value[2]);
    }
  });

  test(
    'render maps bounded diagnostics and removes incomplete files',
    () async {
      final destination = Uri.file('${temp.path}/failed.partial.mp4');
      final temporaryV3 = File('${temp.path}/temporary.v3');
      runner.enqueue(
        FakeRunningProcess(
          code: 7,
          stderr: List.generate(
            100,
            (index) => 'diagnostic-$index-${'x' * 300}',
          ).join('\n'),
          onStart: (_) => File(destination.toFilePath()).writeAsBytesSync([1]),
        ),
      );

      await expectLater(
        adapter
            .render(
              _renderRequest(
                source: Uri.file('/absolute/source.mp4'),
                destination: destination,
                preset: RenderPreset.balanced,
              ),
            )
            .result,
        throwsA(
          isA<EngineContractFailure>()
              .having((failure) => failure.exitCode, 'exitCode', 7)
              .having(
                (failure) => failure.diagnostics.length,
                'diagnostic lines',
                lessThanOrEqualTo(40),
              )
              .having(
                (failure) => failure.diagnostics.join().length,
                'diagnostic characters',
                lessThanOrEqualTo(8192),
              ),
        ),
      );
      expect(temporaryV3.existsSync(), isFalse);
      expect(File(destination.toFilePath()).existsSync(), isFalse);
    },
  );

  test('render cancellation is typed, idempotent, and cleans files', () async {
    final destination = Uri.file('${temp.path}/cancelled.partial.mp4');
    final temporaryV3 = File('${temp.path}/temporary.v3');
    final process = BlockingFakeRunningProcess(
      onStart: (_) => File(destination.toFilePath()).writeAsBytesSync([1]),
    );
    runner.enqueue(process);
    final task = adapter.render(
      _renderRequest(
        source: Uri.file('/absolute/source.mp4'),
        destination: destination,
        preset: RenderPreset.balanced,
      ),
    );
    await _waitFor(() => runner.requests.isNotEmpty);
    final resultExpectation = expectLater(
      task.result,
      throwsA(
        isA<OperationCancelled>().having(
          (failure) => failure.operation,
          'operation',
          'render',
        ),
      ),
    );

    await Future.wait([task.cancel(), task.cancel()]);

    await resultExpectation;
    expect(process.cancelCount, 1);
    expect(temporaryV3.existsSync(), isFalse);
    expect(File(destination.toFilePath()).existsSync(), isFalse);
  });

  test(
    'cancel waits when requested while process start is still pending',
    () async {
      final delayedRunner = DelayedProcessRunner();
      final delayedAdapter = AutoEditorAdapter(
        processRunner: delayedRunner,
        executableLocator: const FakeExecutableLocator('/bundle/auto-editor'),
        temporaryPathFactory: (extension) async =>
            Uri.file('${temp.path}/delayed$extension'),
      );
      final destination = Uri.file('${temp.path}/delayed.partial.mp4');
      final process = BlockingFakeRunningProcess(
        onStart: (_) => File(destination.toFilePath()).writeAsBytesSync([1]),
      );
      final task = delayedAdapter.render(
        _renderRequest(
          source: Uri.file('/absolute/source.mp4'),
          destination: destination,
          preset: RenderPreset.balanced,
        ),
      );
      await _waitFor(() => delayedRunner.requests.isNotEmpty);
      var cancelCompleted = false;
      final resultExpectation = expectLater(
        task.result,
        throwsA(isA<OperationCancelled>()),
      );

      final cancellation = task.cancel().then((_) => cancelCompleted = true);
      await Future<void>.delayed(Duration.zero);
      expect(cancelCompleted, isFalse);
      delayedRunner.release(process);
      await cancellation;

      await resultExpectation;
      expect(process.cancelCount, 1);
      expect(File(destination.toFilePath()).existsSync(), isFalse);
      expect(File('${temp.path}/delayed.v3').existsSync(), isFalse);
    },
  );

  test(
    'early cancel waits for later attached native cleanup after task finish',
    () async {
      final delayedRunner = DelayedProcessRunner();
      final delayedAdapter = AutoEditorAdapter(
        processRunner: delayedRunner,
        executableLocator: const FakeExecutableLocator('/bundle/auto-editor'),
        temporaryPathFactory: (extension) async =>
            Uri.file('${temp.path}/native-cleanup$extension'),
      );
      final process = DelayedCancellationRunningProcess();
      final task = delayedAdapter.render(
        _renderRequest(
          source: Uri.file('/absolute/source.mp4'),
          destination: Uri.file('${temp.path}/native-cleanup.partial.mp4'),
          preset: RenderPreset.balanced,
        ),
      );
      await _waitFor(() => delayedRunner.requests.isNotEmpty);
      final resultExpectation = expectLater(
        task.result,
        throwsA(isA<OperationCancelled>()),
      );
      var firstCancelCompleted = false;
      var secondCancelCompleted = false;

      final firstCancellation = task.cancel().then(
        (_) => firstCancelCompleted = true,
      );
      final secondCancellation = task.cancel().then(
        (_) => secondCancelCompleted = true,
      );
      delayedRunner.release(process);
      await _waitFor(() => process.cancelCount == 1);
      await resultExpectation;
      var postFinishCancelCompleted = false;
      final postFinishCancellation = task.cancel().then(
        (_) => postFinishCancelCompleted = true,
      );
      await Future<void>.delayed(Duration.zero);

      expect(firstCancelCompleted, isFalse);
      expect(secondCancelCompleted, isFalse);
      expect(postFinishCancelCompleted, isFalse);
      process.completeCancellation();
      await Future.wait([
        firstCancellation,
        secondCancellation,
        postFinishCancellation,
      ]);
      expect(process.cancelCount, 1);
    },
  );

  test('cancel before task body starts completes without a process', () async {
    final task = adapter.render(
      _renderRequest(
        source: Uri.file('/absolute/source.mp4'),
        destination: Uri.file('${temp.path}/pre-body.partial.mp4'),
        preset: RenderPreset.balanced,
      ),
    );
    final resultExpectation = expectLater(
      task.result,
      throwsA(isA<OperationCancelled>()),
    );

    await task.cancel().timeout(const Duration(seconds: 1));

    await resultExpectation;
    expect(runner.requests, isEmpty);
  });

  test('cancel completes when a pending process start fails', () async {
    final failingRunner = DelayedFailingProcessRunner();
    final failingAdapter = AutoEditorAdapter(
      processRunner: failingRunner,
      executableLocator: const FakeExecutableLocator('/bundle/auto-editor'),
      temporaryPathFactory: (extension) async =>
          Uri.file('${temp.path}/start-failure$extension'),
    );
    final task = failingAdapter.render(
      _renderRequest(
        source: Uri.file('/absolute/source.mp4'),
        destination: Uri.file('${temp.path}/start-failure.partial.mp4'),
        preset: RenderPreset.balanced,
      ),
    );
    await _waitFor(() => failingRunner.requests.isNotEmpty);
    final resultExpectation = expectLater(
      task.result,
      throwsA(isA<StateError>()),
    );

    final cancellation = task.cancel();
    failingRunner.fail(StateError('start failed'));
    await cancellation.timeout(const Duration(seconds: 1));

    await resultExpectation;
  });
}

final class FakeExecutableLocator implements AutoEditorExecutableLocator {
  const FakeExecutableLocator(this.path);

  final String path;

  @override
  Future<String> locate() async => path;
}

final class FakeProcessRunner implements ProcessRunner {
  final requests = <ProcessRequest>[];
  final _processes = <FakeRunningProcess>[];

  void enqueue(FakeRunningProcess process) => _processes.add(process);

  @override
  Future<RunningProcess> start(ProcessRequest request) async {
    requests.add(request);
    if (_processes.isEmpty) throw StateError('No fake process queued');
    return _processes.removeAt(0)..start(request);
  }
}

final class DelayedProcessRunner implements ProcessRunner {
  final requests = <ProcessRequest>[];
  final _release = Completer<RunningProcess>();

  @override
  Future<RunningProcess> start(ProcessRequest request) {
    requests.add(request);
    return _release.future.then((process) {
      if (process is FakeRunningProcess) process.start(request);
      return process;
    });
  }

  void release(RunningProcess process) => _release.complete(process);
}

final class DelayedFailingProcessRunner implements ProcessRunner {
  final requests = <ProcessRequest>[];
  final _release = Completer<RunningProcess>();

  @override
  Future<RunningProcess> start(ProcessRequest request) {
    requests.add(request);
    return _release.future;
  }

  void fail(Object error) => _release.completeError(error);
}

class FakeRunningProcess implements RunningProcess {
  FakeRunningProcess({
    this.stdout = '',
    this.stderr = '',
    this.code = 0,
    this.onStart,
  });

  final String stdout;
  final String stderr;
  final int code;
  final void Function(ProcessRequest request)? onStart;
  var cancelCount = 0;

  void start(ProcessRequest request) => onStart?.call(request);

  @override
  int get pid => 42;

  @override
  Stream<String> get stdoutLines =>
      Stream.fromIterable(stdout.split('\n').where((line) => line.isNotEmpty));

  @override
  Stream<String> get stderrLines =>
      Stream.fromIterable(stderr.split('\n').where((line) => line.isNotEmpty));

  @override
  Future<int> get exitCode async => code;

  @override
  Future<void> cancel() async {
    cancelCount++;
  }
}

final class BlockingFakeRunningProcess extends FakeRunningProcess {
  BlockingFakeRunningProcess({super.onStart});

  final _exit = Completer<int>();

  @override
  Future<int> get exitCode => _exit.future;

  @override
  Future<void> cancel() async {
    await super.cancel();
    if (!_exit.isCompleted) _exit.complete(255);
  }
}

final class DelayedCancellationRunningProcess extends FakeRunningProcess {
  final _exit = Completer<int>();
  final _cancellation = Completer<void>();

  @override
  Future<int> get exitCode => _exit.future;

  @override
  Future<void> cancel() {
    cancelCount++;
    if (!_exit.isCompleted) _exit.complete(255);
    return _cancellation.future;
  }

  void completeCancellation() => _cancellation.complete();
}

String _fixtureText(String name) =>
    File('test/fixtures/auto_editor/31.2.0/$name').readAsStringSync();

String _infoWithTimebase(String timebase) =>
    _fixtureText('info.json').replaceFirst(
      '"recommendedTimebase": "30/1"',
      '"recommendedTimebase": "$timebase"',
    );

RenderRequest _renderRequest({
  required Uri source,
  required Uri destination,
  required RenderPreset preset,
}) {
  final metadata = MediaMetadata(
    durationUs: 2_000_000,
    timebaseNumerator: 1,
    timebaseDenominator: 30,
    resolution: SizeInt(1920, 1080),
    videoCodec: 'h264',
    hasAudio: true,
    sampleRate: 48_000,
    audioLayout: 'stereo',
  );
  return RenderRequest(
    source: source,
    metadata: metadata,
    timeline: EffectiveTimeline.compose(
      durationUs: metadata.durationUs,
      detected: [
        TimelineSegment(
          range: SourceTimeRange(0, metadata.durationUs),
          action: SegmentAction.keep,
          origin: SegmentOrigin.detected,
        ),
      ],
      overrides: const [],
    ),
    partialDestination: destination,
    preset: preset,
  );
}

Future<void> _waitFor(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('Condition was not reached');
}
