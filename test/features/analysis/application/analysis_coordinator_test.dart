import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/core/errors/app_failure.dart';
import 'package:gapless/core/time/source_time_range.dart';
import 'package:gapless/features/analysis/application/analysis_coordinator.dart';
import 'package:gapless/features/analysis/data/analysis_cache.dart';
import 'package:gapless/features/editor/domain/analysis_settings.dart';
import 'package:gapless/features/editor/domain/timeline_segment.dart';
import 'package:gapless/features/engine/domain/engine_models.dart';
import 'package:gapless/features/engine/domain/engine_port.dart';
import 'package:gapless/features/project/domain/project_document.dart';
import 'package:gapless/features/project/domain/source_reference.dart';

void main() {
  late FakeAnalysisClock clock;
  late RecordingCache cache;
  late _ControlledEngine engine;
  late AnalysisCoordinator coordinator;

  setUp(() {
    clock = FakeAnalysisClock();
    cache = RecordingCache();
    engine = _ControlledEngine();
    coordinator = AnalysisCoordinator(
      engine: engine,
      cache: cache,
      engineVersion: '31.2.0',
      clock: clock,
    );
  });

  tearDown(() async {
    await coordinator.dispose();
  });

  test('debounces for 250 ms and executes only the newest request', () async {
    final states = <AnalysisState>[];
    final subscription = coordinator.states.listen(states.add);

    coordinator.request(_project(thresholdDb: -30));
    clock.elapse(const Duration(milliseconds: 100));
    coordinator.request(_project(thresholdDb: -19));
    clock.elapse(const Duration(milliseconds: 249));
    await _pump();
    expect(engine.levelsCalls, isEmpty);
    expect(engine.detectCalls, isEmpty);

    clock.elapse(const Duration(milliseconds: 1));
    await _pump();
    expect(engine.levelsCalls, hasLength(1));
    engine.levelTasks.single.complete(_levels());
    await _pump();
    expect(engine.detectCalls.single.settings.thresholdDb, -19);
    engine.detectTasks.single.complete(_detected());
    await _pump();

    expect(states.whereType<AnalysisReady>(), hasLength(1));
    expect(coordinator.state, isA<AnalysisReady>());
    await subscription.cancel();
  });

  test('stale progress, result, and failure cannot publish', () async {
    final states = <AnalysisState>[];
    final subscription = coordinator.states.listen(states.add);

    coordinator.request(_project(thresholdDb: -30));
    clock.elapse(const Duration(milliseconds: 250));
    await _pump();
    engine.levelTasks.single.complete(_levels());
    await _pump();
    final staleDetection = engine.detectTasks.single;

    coordinator.request(_project(thresholdDb: -19));
    expect(staleDetection.cancelCount, 1);
    clock.elapse(const Duration(milliseconds: 250));
    await _pump();
    staleDetection.emit(
      EngineProgress(stage: EngineStage.analyzing, percent: 91),
    );
    staleDetection.fail(const OperationCancelled(operation: 'stale-detection'));
    await _pump();

    engine.levelTasks.last.complete(_levels(samples: const [2]));
    await _pump();
    engine.detectTasks.last.complete(_detected(cutStartUs: 600000));
    await _pump();

    expect(
      states.whereType<AnalysisRunning>().map(
        (state) => state.progress.percent,
      ),
      isNot(contains(91)),
    );
    expect(states.whereType<AnalysisFailed>(), isEmpty);
    expect(states.whereType<AnalysisReady>(), hasLength(1));
    final ready = coordinator.state as AnalysisReady;
    expect(ready.timeline.segments.last.range.startUs, 600000);
    await subscription.cancel();
  });

  test(
    'keeps the last ready timeline during re-analysis and failure',
    () async {
      await _completeRequest(
        coordinator,
        clock,
        engine,
        _project(thresholdDb: -30),
        detected: _detected(cutStartUs: 400000),
      );
      final previous = (coordinator.state as AnalysisReady).timeline;
      final failure = MediaReadFailure(
        source: Uri.file('/source/interview.mp4'),
        reason: MediaReadReason.corrupt,
      );

      coordinator.request(_project(thresholdDb: -19));
      clock.elapse(const Duration(milliseconds: 250));
      await _pump();
      final running = coordinator.state as AnalysisRunning;
      expect(identical(running.previous, previous), isTrue);
      engine.levelTasks.last.fail(failure);
      await _pump();

      final failed = coordinator.state as AnalysisFailed;
      expect(identical(failed.failure, failure), isTrue);
      expect(identical(failed.previous, previous), isTrue);
    },
  );

  test(
    'recomposes manual overrides locally without another engine call',
    () async {
      final base = _project();
      await _completeRequest(coordinator, clock, engine, base);
      final levelsCalls = engine.levelsCalls.length;
      final detectCalls = engine.detectCalls.length;
      final override = TimelineSegment(
        range: SourceTimeRange(700000, 900000),
        action: SegmentAction.keep,
        origin: SegmentOrigin.manual,
      );

      coordinator.request(_project(manualOverrides: [override]));
      clock.elapse(const Duration(milliseconds: 250));
      await _pump();

      expect(engine.levelsCalls, hasLength(levelsCalls));
      expect(engine.detectCalls, hasLength(detectCalls));
      final ready = coordinator.state as AnalysisReady;
      expect(
        ready.timeline.segments,
        contains(
          isA<TimelineSegment>()
              .having((segment) => segment.range, 'range', override.range)
              .having((segment) => segment.action, 'action', SegmentAction.keep)
              .having(
                (segment) => segment.origin,
                'origin',
                SegmentOrigin.manual,
              ),
        ),
      );
    },
  );

  test(
    'manual override update keeps the original scheduled debounce',
    () async {
      final override = TimelineSegment(
        range: SourceTimeRange(700000, 900000),
        action: SegmentAction.keep,
        origin: SegmentOrigin.manual,
      );
      coordinator.request(_project());
      clock.elapse(const Duration(milliseconds: 100));

      coordinator.request(_project(manualOverrides: [override]));
      clock.elapse(const Duration(milliseconds: 149));
      await _pump();
      expect(engine.levelsCalls, isEmpty);

      clock.elapse(const Duration(milliseconds: 1));
      await _pump();
      expect(engine.levelsCalls, hasLength(1));
      engine.levelTasks.single.complete(_levels());
      await _pump();
      engine.detectTasks.single.complete(_detected());
      await _pump();
      expect(
        (coordinator.state as AnalysisReady).timeline.segments,
        contains(
          isA<TimelineSegment>().having(
            (segment) => segment.origin,
            'origin',
            SegmentOrigin.manual,
          ),
        ),
      );
    },
  );

  test(
    'manual override update does not cancel or restart in-flight work',
    () async {
      final override = TimelineSegment(
        range: SourceTimeRange(700000, 900000),
        action: SegmentAction.keep,
        origin: SegmentOrigin.manual,
      );
      coordinator.request(_project());
      clock.elapse(const Duration(milliseconds: 250));
      await _pump();
      final levelsTask = engine.levelTasks.single;

      coordinator.request(_project(manualOverrides: [override]));
      expect(levelsTask.cancelCount, 0);
      expect(clock.activeTimerCount, 0);
      levelsTask.complete(_levels());
      await _pump();
      engine.detectTasks.single.complete(_detected());
      await _pump();

      expect(engine.levelsCalls, hasLength(1));
      expect(engine.detectCalls, hasLength(1));
      expect(
        (coordinator.state as AnalysisReady).timeline.segments,
        contains(
          isA<TimelineSegment>().having(
            (segment) => segment.origin,
            'origin',
            SegmentOrigin.manual,
          ),
        ),
      );
    },
  );

  test(
    'reads partial cache hits independently and runs only the miss',
    () async {
      cache.levels[_cacheKey(_project())] = _levels();

      coordinator.request(_project());
      clock.elapse(const Duration(milliseconds: 250));
      await _pump();
      expect(engine.levelsCalls, isEmpty);
      expect(engine.detectCalls, hasLength(1));
      engine.detectTasks.single.complete(_detected());
      await _pump();
      expect(coordinator.state, isA<AnalysisReady>());

      await coordinator.dispose();
      clock = FakeAnalysisClock();
      cache = RecordingCache();
      cache.timelines[_cacheKey(_project())] = _detected();
      engine = _ControlledEngine();
      coordinator = AnalysisCoordinator(
        engine: engine,
        cache: cache,
        engineVersion: '31.2.0',
        clock: clock,
      );

      coordinator.request(_project());
      clock.elapse(const Duration(milliseconds: 250));
      await _pump();
      expect(engine.levelsCalls, hasLength(1));
      expect(engine.detectCalls, isEmpty);
      engine.levelTasks.single.complete(_levels());
      await _pump();
      expect(coordinator.state, isA<AnalysisReady>());
    },
  );

  test(
    'cache read and write failures cannot fail successful analysis',
    () async {
      cache.failReads = true;
      cache.failWrites = true;

      await _completeRequest(coordinator, clock, engine, _project());

      expect(coordinator.state, isA<AnalysisReady>());
    },
  );

  test(
    'state is replayed to late listeners and supports concurrent listeners',
    () async {
      await _completeRequest(coordinator, clock, engine, _project());

      final first = await coordinator.states.first;
      final second = await coordinator.states.first;

      expect(first, same(coordinator.state));
      expect(second, same(coordinator.state));
    },
  );

  test(
    'cancel stops scheduled and in-flight work without late publication',
    () async {
      final states = <AnalysisState>[];
      final subscription = coordinator.states.listen(states.add);
      coordinator.request(_project());
      clock.elapse(const Duration(milliseconds: 250));
      await _pump();
      final task = engine.levelTasks.single;

      await coordinator.cancel();
      expect(task.cancelCount, 1);
      final stateCount = states.length;

      task.complete(_levels());
      await _pump();
      expect(states, hasLength(stateCount));
      expect(engine.detectCalls, isEmpty);
      await subscription.cancel();
    },
  );

  test(
    'dispose cancels in-flight work once and suppresses late publication',
    () async {
      final states = <AnalysisState>[];
      var streamClosed = false;
      final subscription = coordinator.states.listen(
        states.add,
        onDone: () => streamClosed = true,
      );
      coordinator.request(_project());
      clock.elapse(const Duration(milliseconds: 250));
      await _pump();
      final task = engine.levelTasks.single;

      final firstDispose = coordinator.dispose();
      final secondDispose = coordinator.dispose();
      await Future.wait([firstDispose, secondDispose]);
      expect(task.cancelCount, 1);
      expect(streamClosed, isTrue);
      expect(clock.activeTimerCount, 0);
      final stateCount = states.length;

      task.emit(EngineProgress(stage: EngineStage.analyzing, percent: 50));
      task.complete(_levels());
      await _pump();
      expect(states, hasLength(stateCount));
      expect(() => coordinator.request(_project()), throwsStateError);
      await subscription.cancel();
    },
  );
}

Future<void> _completeRequest(
  AnalysisCoordinator coordinator,
  FakeAnalysisClock clock,
  _ControlledEngine engine,
  ProjectDocument project, {
  DetectedTimeline? detected,
}) async {
  coordinator.request(project);
  clock.elapse(const Duration(milliseconds: 250));
  await _pump();
  engine.levelTasks.last.complete(_levels());
  await _pump();
  engine.detectTasks.last.complete(detected ?? _detected());
  await _pump();
}

Future<void> _pump() async {
  for (var index = 0; index < 12; index++) {
    await Future<void>.value();
  }
}

AnalysisSettings _settings({double thresholdDb = -19}) => AnalysisSettings(
  method: AnalysisMethod.audio,
  thresholdDb: thresholdDb,
  marginBeforeUs: 200000,
  marginAfterUs: 200000,
  inactiveBehavior: InactiveBehavior.cut,
  fastForwardRate: 4,
);

ProjectDocument _project({
  double thresholdDb = -19,
  List<TimelineSegment> manualOverrides = const [],
}) => ProjectDocument(
  schemaVersion: ProjectDocument.currentSchemaVersion,
  appVersion: '0.1.0',
  source: SourceReference(
    relativePath: 'media/interview.mp4',
    absolutePath: '/source/interview.mp4',
    fingerprint: SourceFingerprint(
      size: 1024,
      modifiedAtUtc: DateTime.utc(2026, 7, 11),
      sampledSha256: 'f' * 64,
    ),
  ),
  settings: _settings(thresholdDb: thresholdDb),
  detectedSegments: const [],
  manualOverrides: manualOverrides,
  ui: const ProjectUiState(
    previewMode: PreviewMode.edited,
    timelineZoom: 1,
    sidebarWidth: 264,
    waveformHeight: 52,
  ),
);

String _cacheKey(ProjectDocument project) => AnalysisCacheKey(
  sampledSha256: project.source.fingerprint.sampledSha256,
  engineVersion: '31.2.0',
  settings: project.settings,
).stableKey;

AnalysisLevels _levels({List<int> samples = const [1]}) =>
    AnalysisLevels(samples: samples, samplePeriodUs: 20000);

DetectedTimeline _detected({int cutStartUs = 500000}) => DetectedTimeline(
  durationUs: 1000000,
  segments: [
    TimelineSegment(
      range: SourceTimeRange(0, cutStartUs),
      action: SegmentAction.keep,
      origin: SegmentOrigin.detected,
    ),
    TimelineSegment(
      range: SourceTimeRange(cutStartUs, 1000000),
      action: SegmentAction.cut,
      origin: SegmentOrigin.detected,
    ),
  ],
);

final class FakeAnalysisClock implements AnalysisClock {
  Duration _elapsed = Duration.zero;
  final List<_FakeTimer> _timers = [];

  int get activeTimerCount => _timers.where((timer) => timer.isActive).length;

  void elapse(Duration duration) {
    _elapsed += duration;
    final due = _timers
        .where((timer) => timer.isActive && timer.due <= _elapsed)
        .toList();
    for (final timer in due) {
      timer.fire();
    }
  }

  @override
  AnalysisTimer schedule(Duration delay, void Function() callback) {
    final timer = _FakeTimer(_elapsed + delay, callback);
    _timers.add(timer);
    return timer;
  }
}

final class _FakeTimer implements AnalysisTimer {
  _FakeTimer(this.due, this._callback);

  final Duration due;
  final void Function() _callback;
  bool _active = true;

  @override
  bool get isActive => _active;

  @override
  void cancel() => _active = false;

  void fire() {
    if (!_active) return;
    _active = false;
    _callback();
  }
}

final class RecordingCache implements AnalysisCacheStore {
  final Map<String, AnalysisLevels> levels = {};
  final Map<String, DetectedTimeline> timelines = {};
  bool failReads = false;
  bool failWrites = false;

  @override
  Future<AnalysisLevels?> readLevels(AnalysisCacheKey key) async {
    if (failReads) throw FileSystemException('read levels failed');
    return levels[key.stableKey];
  }

  @override
  Future<DetectedTimeline?> readDetectedTimeline(AnalysisCacheKey key) async {
    if (failReads) throw FileSystemException('read timeline failed');
    return timelines[key.stableKey];
  }

  @override
  Future<void> writeLevels(AnalysisCacheKey key, AnalysisLevels value) async {
    if (failWrites) throw FileSystemException('write levels failed');
    levels[key.stableKey] = value;
  }

  @override
  Future<void> writeDetectedTimeline(
    AnalysisCacheKey key,
    DetectedTimeline timeline,
  ) async {
    if (failWrites) throw FileSystemException('write timeline failed');
    timelines[key.stableKey] = timeline;
  }
}

final class _LevelsCall {
  const _LevelsCall(this.source, this.method);
  final Uri source;
  final AnalysisMethod method;
}

final class _DetectCall {
  const _DetectCall(this.source, this.settings);
  final Uri source;
  final AnalysisSettings settings;
}

final class _ControlledEngine implements EnginePort {
  final List<_LevelsCall> levelsCalls = [];
  final List<_DetectCall> detectCalls = [];
  final List<ControlledTask<AnalysisLevels>> levelTasks = [];
  final List<ControlledTask<DetectedTimeline>> detectTasks = [];

  @override
  EngineTask<AnalysisLevels> levels(Uri source, AnalysisMethod method) {
    levelsCalls.add(_LevelsCall(source, method));
    final task = ControlledTask<AnalysisLevels>();
    levelTasks.add(task);
    return task;
  }

  @override
  EngineTask<DetectedTimeline> detect(Uri source, AnalysisSettings settings) {
    detectCalls.add(_DetectCall(source, settings));
    final task = ControlledTask<DetectedTimeline>();
    detectTasks.add(task);
    return task;
  }

  @override
  EngineTask<MediaMetadata> probe(Uri source) => throw UnimplementedError();

  @override
  EngineTask<Uri> render(RenderRequest request) => throw UnimplementedError();
}

final class ControlledTask<T> implements EngineTask<T> {
  final Completer<T> _result = Completer<T>();
  final StreamController<EngineProgress> _progress =
      StreamController<EngineProgress>.broadcast(sync: true);
  int cancelCount = 0;

  @override
  Stream<EngineProgress> get progress => _progress.stream;

  @override
  Future<T> get result => _result.future;

  @override
  Future<void> cancel() async {
    cancelCount += 1;
  }

  void emit(EngineProgress progress) => _progress.add(progress);

  void complete(T value) {
    if (!_result.isCompleted) _result.complete(value);
  }

  void fail(Object error) {
    if (!_result.isCompleted) _result.completeError(error);
  }
}
