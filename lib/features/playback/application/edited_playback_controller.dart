import 'dart:async';
import 'dart:math';

import 'package:gapless/features/editor/domain/effective_timeline.dart';
import 'package:gapless/features/editor/domain/timeline_segment.dart';
import 'package:gapless/features/playback/domain/playback_port.dart';

enum PlaybackMode { original, edited }

final class EditedPlaybackController {
  EditedPlaybackController({
    required this.player,
    required EffectiveTimeline timeline,
    required this.seekToleranceUs,
  }) : _timeline = timeline {
    if (seekToleranceUs <= 0) {
      throw ArgumentError.value(seekToleranceUs, 'seekToleranceUs');
    }
    _validateCanonicalTimeline(timeline);
    _currentEditedUs = timeline.editedUsForSourceUs(0);
    sourcePositionUs = _replay(_sourceChanges, () => _currentSourceUs);
    editedPositionUs = _replay(_editedChanges, () => _currentEditedUs);
    positionUs = _replay(_positionChanges, () => currentPositionUs);
    _positionSubscription = player.positionUs.listen(_onPosition);
    _playingSubscription = player.playing.listen(_onPlaying);
  }

  final PlaybackPort player;
  final int seekToleranceUs;

  late final Stream<int> sourcePositionUs;
  late final Stream<int> editedPositionUs;
  late final Stream<int> positionUs;

  final StreamController<int> _sourceChanges = StreamController<int>.broadcast(
    sync: true,
  );
  final StreamController<int> _editedChanges = StreamController<int>.broadcast(
    sync: true,
  );
  final StreamController<int> _positionChanges =
      StreamController<int>.broadcast(sync: true);

  late final StreamSubscription<int> _positionSubscription;
  late final StreamSubscription<bool> _playingSubscription;
  EffectiveTimeline _timeline;
  PlaybackMode _mode = PlaybackMode.edited;
  Future<void> _serial = Future<void>.value();
  Future<void>? _disposeFuture;
  _PendingSeek? _pendingSeek;
  double? _commandedRate;
  int _currentSourceUs = 0;
  int _currentEditedUs = 0;
  int _latestObservedSourceUs = 0;
  int _generation = 0;
  bool _playing = false;
  bool _pausedAtEnd = false;
  bool _disposed = false;

  PlaybackMode get mode => _mode;
  EffectiveTimeline get timeline => _timeline;
  int get currentSourceUs => _currentSourceUs;
  int get currentEditedUs => _currentEditedUs;
  int get currentPositionUs => switch (_mode) {
    PlaybackMode.original => _currentSourceUs,
    PlaybackMode.edited => _currentEditedUs,
  };

  Future<void> setMode(PlaybackMode mode) async {
    _ensureActive();
    final previousPositionUs = currentPositionUs;
    _mode = mode;
    if (mode == PlaybackMode.original) {
      _pendingSeek = null;
    }
    _publishPosition(_latestObservedSourceUs);
    if (currentPositionUs != previousPositionUs) {
      _positionChanges.add(currentPositionUs);
    }
    final generation = ++_generation;
    await _enqueue(() => _reconcile(_latestObservedSourceUs, generation));
  }

  Future<void> updateTimeline(EffectiveTimeline timeline) async {
    _ensureActive();
    _validateCanonicalTimeline(timeline);
    _timeline = timeline;
    _pendingSeek = null;
    _latestObservedSourceUs = _clampSource(_latestObservedSourceUs);
    _publishPosition(_latestObservedSourceUs);
    final generation = ++_generation;
    await _enqueue(() => _reconcile(_latestObservedSourceUs, generation));
  }

  Future<void> seekEdited(int editedUs) async {
    _ensureActive();
    if (editedUs < 0 || editedUs > _timeline.editedDurationUs) {
      throw RangeError.range(
        editedUs,
        0,
        _timeline.editedDurationUs,
        'editedUs',
      );
    }
    final sourceUs = _timeline.sourceUsForEditedUs(editedUs);
    final atEnd = editedUs == _timeline.editedDurationUs;
    final generation = ++_generation;
    await _enqueue(() async {
      if (!_isCurrent(generation)) return;
      await _commandSeek(targetUs: sourceUs, originUs: _latestObservedSourceUs);
      if (!_isCurrent(generation)) return;
      if (atEnd) {
        await _setRate(1.0);
        if (!_isCurrent(generation)) return;
        await _pauseAtEnd();
      }
    });
  }

  Future<void> dispose() {
    final existing = _disposeFuture;
    if (existing != null) return existing;
    _disposed = true;
    _generation += 1;
    final future = _dispose();
    _disposeFuture = future;
    return future;
  }

  Future<void> _dispose() async {
    await Future.wait<void>([
      _positionSubscription.cancel(),
      _playingSubscription.cancel(),
    ]);
    await _serial;
    await Future.wait<void>([
      _sourceChanges.close(),
      _editedChanges.close(),
      _positionChanges.close(),
    ]);
  }

  void _onPosition(int sourceUs) {
    if (_disposed) return;
    final clamped = _clampSource(sourceUs);
    _latestObservedSourceUs = clamped;
    final generation = ++_generation;
    unawaited(
      _enqueue(
        () => _reactToPosition(clamped, generation),
      ).then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  }

  void _onPlaying(bool playing) {
    if (_disposed) return;
    _playing = playing;
    if (playing) {
      _pausedAtEnd = false;
    }
  }

  Future<void> _reactToPosition(int sourceUs, int generation) async {
    if (!_isCurrent(generation)) return;
    final pending = _pendingSeek;
    if (pending != null) {
      if (_withinTolerance(sourceUs, pending.targetUs)) {
        _pendingSeek = null;
      } else if (_withinTolerance(sourceUs, pending.originUs)) {
        return;
      } else {
        _pendingSeek = null;
      }
    }
    if (!_isCurrent(generation)) return;
    _publishPosition(sourceUs);
    await _reconcile(sourceUs, generation);
  }

  Future<void> _reconcile(int sourceUs, int generation) async {
    if (!_isCurrent(generation)) return;
    if (_mode == PlaybackMode.original) {
      _pendingSeek = null;
      _pausedAtEnd = false;
      await _setRate(1.0);
      return;
    }

    if (sourceUs >= _timeline.durationUs) {
      _pendingSeek = null;
      await _setRate(1.0);
      if (!_isCurrent(generation)) return;
      await _pauseAtEnd();
      return;
    }

    _pausedAtEnd = false;
    final segmentIndex = _segmentIndexAt(sourceUs);
    final segment = _timeline.segments[segmentIndex];
    if (segment.action == SegmentAction.cut) {
      await _setRate(1.0);
      if (!_isCurrent(generation)) return;
      final targetUs = _nextPlayableBoundary(segmentIndex);
      final pending = _pendingSeek;
      if (pending == null || pending.targetUs != targetUs) {
        await _commandSeek(targetUs: targetUs, originUs: sourceUs);
      }
      if (!_isCurrent(generation)) return;
      if (targetUs == _timeline.durationUs) {
        await _pauseAtEnd();
      }
      return;
    }

    final rate = segment.action == SegmentAction.fastForward
        ? segment.rate
        : 1.0;
    await _setRate(rate);
  }

  Future<void> _commandSeek({
    required int targetUs,
    required int originUs,
  }) async {
    final pending = _PendingSeek(originUs: originUs, targetUs: targetUs);
    _pendingSeek = pending;
    try {
      await player.seek(targetUs);
    } on Object {
      if (identical(_pendingSeek, pending)) {
        _pendingSeek = null;
      }
      rethrow;
    }
  }

  Future<void> _setRate(double rate) async {
    if (_commandedRate == rate) return;
    await player.setRate(rate);
    _commandedRate = rate;
  }

  Future<void> _pauseAtEnd() async {
    if (_pausedAtEnd && !_playing) return;
    await player.pause();
    _playing = false;
    _pausedAtEnd = true;
  }

  Future<void> _enqueue(Future<void> Function() reaction) {
    final future = _serial.then((_) => reaction());
    _serial = future.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return future;
  }

  void _publishPosition(int sourceUs) {
    if (_disposed) return;
    final clamped = _clampSource(sourceUs);
    final edited = _timeline.editedUsForSourceUs(clamped);
    final previousCurrent = currentPositionUs;
    if (_currentSourceUs != clamped) {
      _currentSourceUs = clamped;
      _sourceChanges.add(clamped);
    }
    if (_currentEditedUs != edited) {
      _currentEditedUs = edited;
      _editedChanges.add(edited);
    }
    if (currentPositionUs != previousCurrent) {
      _positionChanges.add(currentPositionUs);
    }
  }

  int _clampSource(int sourceUs) => max(0, min(sourceUs, _timeline.durationUs));

  int _segmentIndexAt(int sourceUs) {
    for (var index = 0; index < _timeline.segments.length; index++) {
      final range = _timeline.segments[index].range;
      if (sourceUs >= range.startUs && sourceUs < range.endUs) return index;
    }
    throw StateError('Source position is outside the canonical timeline');
  }

  int _nextPlayableBoundary(int cutIndex) {
    for (var index = cutIndex + 1; index < _timeline.segments.length; index++) {
      final segment = _timeline.segments[index];
      if (segment.action != SegmentAction.cut) {
        return segment.range.startUs;
      }
    }
    return _timeline.durationUs;
  }

  bool _withinTolerance(int firstUs, int secondUs) =>
      (firstUs - secondUs).abs() <= seekToleranceUs;

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  void _ensureActive() {
    if (_disposed) {
      throw StateError('EditedPlaybackController is disposed');
    }
  }

  Stream<int> _replay(StreamController<int> changes, int Function() current) =>
      Stream<int>.multi((events) {
        if (_disposed) {
          events.close();
          return;
        }
        events.add(current());
        final subscription = changes.stream.listen(
          events.add,
          onError: events.addError,
          onDone: events.close,
        );
        events.onCancel = subscription.cancel;
      }, isBroadcast: true);
}

final class _PendingSeek {
  const _PendingSeek({required this.originUs, required this.targetUs});

  final int originUs;
  final int targetUs;
}

void _validateCanonicalTimeline(EffectiveTimeline timeline) {
  if (timeline.durationUs <= 0 || timeline.segments.isEmpty) {
    throw ArgumentError.value(timeline, 'timeline');
  }
  var expectedStartUs = 0;
  for (final segment in timeline.segments) {
    if (segment.range.startUs != expectedStartUs ||
        segment.range.endUs > timeline.durationUs ||
        !segment.rate.isFinite ||
        (segment.action == SegmentAction.fastForward
            ? segment.rate <= 1.0
            : segment.rate != 1.0)) {
      throw ArgumentError.value(timeline, 'timeline', 'Must be canonical');
    }
    expectedStartUs = segment.range.endUs;
  }
  if (expectedStartUs != timeline.durationUs) {
    throw ArgumentError.value(timeline, 'timeline', 'Must cover the source');
  }
}
