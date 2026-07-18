import 'dart:async';

import 'package:gapless/core/errors/app_failure.dart';
import 'package:gapless/features/analysis/data/analysis_cache.dart';
import 'package:gapless/features/editor/domain/effective_timeline.dart';
import 'package:gapless/features/engine/domain/engine_models.dart';
import 'package:gapless/features/engine/domain/engine_port.dart';
import 'package:gapless/features/project/domain/project_document.dart';

sealed class AnalysisState {
  const AnalysisState();
}

final class AnalysisIdle extends AnalysisState {
  const AnalysisIdle();
}

final class AnalysisRunning extends AnalysisState {
  const AnalysisRunning(this.previous, this.progress);

  final EffectiveTimeline? previous;
  final EngineProgress progress;
}

final class AnalysisReady extends AnalysisState {
  const AnalysisReady(this.timeline, this.levels);

  final EffectiveTimeline timeline;
  final AnalysisLevels levels;
}

final class AnalysisFailed extends AnalysisState {
  const AnalysisFailed(this.failure, this.previous);

  final AppFailure failure;
  final EffectiveTimeline? previous;
}

abstract interface class AnalysisTimer {
  bool get isActive;
  void cancel();
}

abstract interface class AnalysisClock {
  AnalysisTimer schedule(Duration delay, void Function() callback);
}

final class SystemAnalysisClock implements AnalysisClock {
  const SystemAnalysisClock();

  @override
  AnalysisTimer schedule(Duration delay, void Function() callback) =>
      _SystemAnalysisTimer(Timer(delay, callback));
}

final class _SystemAnalysisTimer implements AnalysisTimer {
  const _SystemAnalysisTimer(this._timer);

  final Timer _timer;

  @override
  bool get isActive => _timer.isActive;

  @override
  void cancel() => _timer.cancel();
}

final class AnalysisCoordinator {
  AnalysisCoordinator({
    required this.engine,
    required this.cache,
    required this.engineVersion,
    this.debounce = const Duration(milliseconds: 250),
    this.clock = const SystemAnalysisClock(),
  }) {
    if (engineVersion.trim().isEmpty) {
      throw ArgumentError.value(engineVersion, 'engineVersion');
    }
    if (debounce.isNegative) {
      throw ArgumentError.value(debounce, 'debounce');
    }
    states = Stream<AnalysisState>.multi((events) {
      events.add(_state);
      final subscription = _stateChanges.stream.listen(
        events.add,
        onError: events.addError,
        onDone: events.close,
      );
      events.onCancel = subscription.cancel;
    }, isBroadcast: true);
  }

  final EnginePort engine;
  final AnalysisCacheStore cache;
  final String engineVersion;
  final Duration debounce;
  final AnalysisClock clock;

  late final Stream<AnalysisState> states;
  AnalysisState _state = const AnalysisIdle();
  AnalysisState get state => _state;

  final StreamController<AnalysisState> _stateChanges =
      StreamController<AnalysisState>.broadcast(sync: true);
  final Set<_AnalysisRun> _runs = {};
  AnalysisTimer? _timer;
  EffectiveTimeline? _lastReady;
  _AnalysisArtifacts? _lastArtifacts;
  _AnalysisRequest? _currentRequest;
  Future<void> _cancellationBarrier = Future<void>.value();
  Future<void>? _disposeFuture;
  int _generation = 0;
  bool _disposed = false;

  void request(ProjectDocument document) {
    _ensureActive();
    final key = AnalysisCacheKey(
      sampledSha256: document.source.fingerprint.sampledSha256,
      engineVersion: engineVersion,
      settings: document.settings,
    );
    final generation = ++_generation;
    final current = _currentRequest;
    if (current != null && current.matches(document, key)) {
      final previousGeneration = current.generation;
      current.generation = generation;
      current.document = document;
      for (final run in _runs) {
        if (run.generation == previousGeneration && !run.cancelled) {
          run.generation = generation;
        }
      }
      final isPending =
          (_timer?.isActive ?? false) ||
          _runs.any(
            (run) => run.generation == current.generation && !run.finished,
          );
      if (isPending) return;
      if (_lastArtifacts case final artifacts?
          when artifacts.stableKey == key.stableKey) {
        _publishReady(artifacts, document);
        return;
      }
    }

    final request = _AnalysisRequest(
      generation: generation,
      key: key,
      document: document,
    );
    _currentRequest = request;
    _timer?.cancel();
    _timer = null;

    final cancellations = _runs.map((run) => run.cancel()).toList();
    final previousBarrier = _cancellationBarrier;
    _cancellationBarrier = Future.wait<void>([
      previousBarrier,
      ...cancellations,
    ]).then((_) {});

    _timer = clock.schedule(debounce, () {
      _timer = null;
      if (!_isCurrent(request.generation)) return;
      final run = _AnalysisRun(request.generation);
      _runs.add(run);
      unawaited(
        _analyze(run, request).whenComplete(() {
          _runs.remove(run);
        }),
      );
    });
  }

  Future<void> cancel() {
    _ensureActive();
    _generation += 1;
    _currentRequest = null;
    _timer?.cancel();
    _timer = null;
    final previousBarrier = _cancellationBarrier;
    final future = Future.wait<void>([
      previousBarrier,
      ..._runs.map((run) => run.cancel()),
    ]).then((_) {});
    _cancellationBarrier = future;
    return future;
  }

  Future<void> dispose() {
    final existing = _disposeFuture;
    if (existing != null) return existing;
    _disposed = true;
    _generation += 1;
    _timer?.cancel();
    _timer = null;
    final future = _dispose();
    _disposeFuture = future;
    return future;
  }

  Future<void> _dispose() async {
    await Future.wait<void>(_runs.map((run) => run.cancel()));
    await _stateChanges.close();
    await Future<void>.value();
  }

  Future<void> _analyze(_AnalysisRun run, _AnalysisRequest request) async {
    try {
      await _cancellationBarrier;
      if (!_canPublish(run)) return;
      _publish(
        AnalysisRunning(
          _lastReady,
          EngineProgress(stage: EngineStage.analyzing),
        ),
      );

      final key = request.key;
      AnalysisLevels? levels;
      DetectedTimeline? detected;
      if (_lastArtifacts case final artifacts?
          when artifacts.stableKey == key.stableKey) {
        levels = artifacts.levels;
        detected = artifacts.detected;
      } else {
        levels = await _readLevels(key);
        if (!_canPublish(run)) return;
        detected = await _readTimeline(key);
      }
      if (!_canPublish(run)) return;

      final document = request.document;
      final source = Uri.file(request.sourcePath);
      if (levels == null) {
        final computedLevels = await _runTask(
          run,
          engine.levels(source, document.settings.method),
        );
        levels = computedLevels;
        if (!_canPublish(run)) return;
        unawaited(_writeLevels(key, computedLevels));
      }
      if (detected == null) {
        final computedTimeline = await _runTask(
          run,
          engine.detect(source, document.settings),
        );
        detected = computedTimeline;
        if (!_canPublish(run)) return;
        unawaited(_writeTimeline(key, computedTimeline));
      }
      if (!_canPublish(run)) return;

      final resolvedLevels = levels;
      final resolvedDetected = detected;
      final artifacts = _AnalysisArtifacts(
        key.stableKey,
        resolvedLevels,
        resolvedDetected,
      );
      _lastArtifacts = artifacts;
      run.finished = true;
      _publishReady(artifacts, request.document);
    } on Object catch (error) {
      if (!_canPublish(run)) return;
      final failure = error is AppFailure
          ? error
          : EngineContractFailure(
              operation: 'coordinate-analysis',
              reason: EngineContractReason.invalidOutput,
              diagnostics: [_boundedMessage(error)],
            );
      _publish(AnalysisFailed(failure, _lastReady));
    }
  }

  Future<T> _runTask<T>(_AnalysisRun run, EngineTask<T> task) async {
    final resources = run.track(
      task.cancel,
      task.progress.listen((progress) {
        if (_canPublish(run)) {
          _publish(AnalysisRunning(_lastReady, progress));
        }
      }),
    );
    try {
      return await task.result;
    } finally {
      await run.release(resources);
    }
  }

  void _publishReady(_AnalysisArtifacts artifacts, ProjectDocument document) {
    final timeline = EffectiveTimeline.compose(
      durationUs: artifacts.detected.durationUs,
      detected: artifacts.detected.segments,
      overrides: document.manualOverrides,
    );
    _lastReady = timeline;
    _publish(AnalysisReady(timeline, artifacts.levels));
  }

  Future<AnalysisLevels?> _readLevels(AnalysisCacheKey key) async {
    try {
      return await cache.readLevels(key);
    } on Object {
      return null;
    }
  }

  Future<DetectedTimeline?> _readTimeline(AnalysisCacheKey key) async {
    try {
      return await cache.readDetectedTimeline(key);
    } on Object {
      return null;
    }
  }

  Future<void> _writeLevels(AnalysisCacheKey key, AnalysisLevels levels) async {
    try {
      await cache.writeLevels(key, levels);
    } on Object {
      // Cache writes are best effort.
    }
  }

  Future<void> _writeTimeline(
    AnalysisCacheKey key,
    DetectedTimeline timeline,
  ) async {
    try {
      await cache.writeDetectedTimeline(key, timeline);
    } on Object {
      // Cache writes are best effort.
    }
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  bool _canPublish(_AnalysisRun run) =>
      !run.cancelled && _isCurrent(run.generation);

  void _publish(AnalysisState next) {
    if (_disposed) return;
    _state = next;
    _stateChanges.add(next);
  }

  void _ensureActive() {
    if (_disposed) throw StateError('AnalysisCoordinator is disposed');
  }
}

final class _AnalysisArtifacts {
  const _AnalysisArtifacts(this.stableKey, this.levels, this.detected);

  final String stableKey;
  final AnalysisLevels levels;
  final DetectedTimeline detected;
}

final class _AnalysisRequest {
  _AnalysisRequest({
    required this.generation,
    required this.key,
    required this.document,
  }) : sourcePath = document.source.absolutePath;

  int generation;
  final AnalysisCacheKey key;
  final String sourcePath;
  ProjectDocument document;

  bool matches(ProjectDocument other, AnalysisCacheKey otherKey) =>
      sourcePath == other.source.absolutePath &&
      key.stableKey == otherKey.stableKey;
}

final class _AnalysisRun {
  _AnalysisRun(this.generation);

  int generation;
  final Set<_TaskResources> _tasks = {};
  bool cancelled = false;
  bool finished = false;
  Future<void>? _cancelFuture;

  _TaskResources track(
    Future<void> Function() cancelTask,
    StreamSubscription<EngineProgress> progress,
  ) {
    final resources = _TaskResources(cancelTask, progress);
    _tasks.add(resources);
    return resources;
  }

  Future<void> release(_TaskResources resources) async {
    _tasks.remove(resources);
    await resources.closeProgress();
  }

  Future<void> cancel() {
    final existing = _cancelFuture;
    if (existing != null) return existing;
    cancelled = true;
    final future = Future.wait<void>(_tasks.map((task) => task.cancel()));
    _cancelFuture = future;
    return future;
  }
}

final class _TaskResources {
  _TaskResources(this._cancelTask, this._progress);

  final Future<void> Function() _cancelTask;
  final StreamSubscription<EngineProgress> _progress;
  Future<void>? _cancelFuture;
  Future<void>? _closeProgressFuture;

  Future<void> closeProgress() =>
      _closeProgressFuture ??= _ignoreFailure(_progress.cancel());

  Future<void> cancel() => _cancelFuture ??= Future.wait<void>([
    closeProgress(),
    _ignoreFailure(_cancelTask()),
  ]).then((_) {});
}

Future<void> _ignoreFailure(Future<void> future) async {
  try {
    await future;
  } on Object {
    // Cancellation is best effort, but every cleanup path is still attempted.
  }
}

String _boundedMessage(Object error) {
  final message = error.toString();
  const limit = 500;
  return message.length <= limit ? message : message.substring(0, limit);
}
