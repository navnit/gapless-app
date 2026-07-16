import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/core/time/source_time_range.dart';
import 'package:gapless/features/editor/domain/effective_timeline.dart';
import 'package:gapless/features/editor/domain/timeline_segment.dart';
import 'package:gapless/features/playback/application/edited_playback_controller.dart';
import 'package:gapless/features/playback/domain/playback_port.dart';

void main() {
  late _FakePlaybackPort player;
  final controllers = <EditedPlaybackController>[];

  setUp(() {
    player = _FakePlaybackPort();
  });

  tearDown(() async {
    for (final controller in controllers) {
      await controller.dispose();
    }
    await player.close();
  });

  EditedPlaybackController create(
    EffectiveTimeline timeline, {
    int toleranceUs = 40000,
  }) {
    final controller = EditedPlaybackController(
      player: player,
      timeline: timeline,
      seekToleranceUs: toleranceUs,
    );
    controllers.add(controller);
    return controller;
  }

  test('skips one cut and suppresses stale pre-seek feedback', () async {
    create(_timeline(10, [const _Part(3, 5, SegmentAction.cut)]));

    player.emitPosition(_seconds(3) + 10000);
    await _settle();
    expect(player.seeks, [_seconds(5)]);

    player.emitPosition(_seconds(3) + 20000);
    player.emitPosition(_seconds(3) + 30000);
    await _settle();
    expect(player.seeks, [_seconds(5)]);

    player.emitPosition(_seconds(5));
    await _settle();
    expect(player.seeks, [_seconds(5)]);
  });

  test(
    'coalesces adjacent trailing cuts and pauses at effective end',
    () async {
      create(
        EffectiveTimeline.compose(
          durationUs: _seconds(10),
          detected: [_segment(2, 6, SegmentAction.cut)],
          overrides: [_manual(6, 10, SegmentAction.cut)],
        ),
      );

      player.emitPosition(_seconds(2) + 10000);
      await _settle();

      expect(player.seeks, [_seconds(10)]);
      expect(player.pauseCount, 1);

      player.emitPosition(_seconds(2) + 20000);
      player.emitPosition(_seconds(10));
      await _settle();
      expect(player.seeks, [_seconds(10)]);
      expect(player.pauseCount, 1);
    },
  );

  test(
    'enters exact fast-forward rate and resets on keep original and end',
    () async {
      final controller = create(
        _timeline(10, [
          const _Part(3, 5, SegmentAction.fastForward, rate: 2.5),
        ]),
      );

      player.emitPosition(_seconds(3) + 10000);
      await _settle();
      expect(player.rates, [2.5]);

      player.emitPosition(_seconds(5) + 10000);
      await _settle();
      expect(player.rates, [2.5, 1.0]);

      player.emitPosition(_seconds(4));
      await _settle();
      expect(player.rates.last, 2.5);
      await controller.setMode(PlaybackMode.original);
      expect(player.rates.last, 1.0);

      await controller.setMode(PlaybackMode.edited);
      expect(player.rates.last, 2.5);
      player.emitPosition(_seconds(10));
      await _settle();
      expect(player.rates.last, 1.0);
      expect(player.pauseCount, 1);
    },
  );

  test('original mode never skips a detected cut', () async {
    final controller = create(
      _timeline(10, [const _Part(3, 5, SegmentAction.cut)]),
    );
    await controller.setMode(PlaybackMode.original);

    player.emitPosition(_seconds(4));
    await _settle();

    expect(player.seeks, isEmpty);
    expect(player.rates, [1.0]);
    expect(controller.currentSourceUs, _seconds(4));
    expect(controller.currentEditedUs, _seconds(3));
    expect(controller.currentPositionUs, _seconds(4));
  });

  test('maps edited seeks at segment boundaries and total end', () async {
    final controller = create(
      _timeline(10, [const _Part(3, 5, SegmentAction.cut)]),
    );

    await controller.seekEdited(_seconds(2));
    await controller.seekEdited(_seconds(3));
    await controller.seekEdited(_seconds(8));

    expect(player.seeks, [_seconds(2), _seconds(5), _seconds(10)]);
    expect(player.pauseCount, 1);
    await expectLater(controller.seekEdited(-1), throwsRangeError);
    await expectLater(controller.seekEdited(_seconds(8) + 1), throwsRangeError);
  });

  test(
    'serializes delayed reactions and finishes in the newest state',
    () async {
      player.delayRates = true;
      create(
        _timeline(8, [const _Part(2, 4, SegmentAction.fastForward, rate: 4)]),
      );

      player.emitPosition(_seconds(2) + 10000);
      await _settle();
      expect(player.rates, [4.0]);

      player.emitPosition(_seconds(4) + 10000);
      await _settle();
      expect(player.rates, [4.0]);
      expect(player.maxInFlight, 1);

      player.completeNextRate();
      await _settle();
      expect(player.rates, [4.0, 1.0]);
      expect(player.maxInFlight, 1);

      player.completeNextRate();
      await _settle();
      expect(player.inFlight, 0);
    },
  );

  test('drains a delayed seek without issuing stale end commands', () async {
    player.delaySeeks = true;
    final controller = create(
      _timeline(10, [const _Part(8, 10, SegmentAction.cut)]),
    );
    player.emitPosition(_seconds(8) + 10000);
    await _settle();
    expect(player.seeks, [_seconds(10)]);
    expect(player.pauseCount, 0);

    var modeChanged = false;
    final modeFuture = controller
        .setMode(PlaybackMode.original)
        .then((_) => modeChanged = true);
    await _settle();
    expect(modeChanged, isFalse);
    expect(player.seekInFlight, 1);

    player.completeNextSeek();
    await modeFuture;
    expect(player.pauseCount, 0);
    expect(player.rates.last, 1.0);
    expect(player.maxSeekInFlight, 1);
  });

  test(
    'retains an observed trailing-cut target across later stale feedback',
    () async {
      player.delaySeeks = true;
      final controller = create(
        _timeline(10, [const _Part(8, 10, SegmentAction.cut)]),
      );
      final sources = <int>[];
      final subscription = controller.sourcePositionUs.listen(sources.add);
      await _settle();

      player.emitPosition(_seconds(8) + 10000);
      await _settle();
      expect(player.seeks, [_seconds(10)]);
      expect(player.seekInFlight, 1);

      player.emitPosition(_seconds(10));
      player.emitPosition(_seconds(8) + 20000);
      await _settle();
      player.completeNextSeek();
      await _settle();

      expect(controller.currentSourceUs, _seconds(10));
      expect(sources.last, _seconds(10));
      expect(player.seeks, [_seconds(10)]);
      expect(player.pauseCount, 1);
      await subscription.cancel();
    },
  );

  test(
    'normalizes near-target trailing-cut feedback to the exact end',
    () async {
      player.delaySeeks = true;
      final controller = create(
        _timeline(10, [const _Part(8, 10, SegmentAction.cut)]),
      );
      final sources = <int>[];
      final subscription = controller.sourcePositionUs.listen(sources.add);
      await _settle();

      player.emitPosition(_seconds(8) + 10000);
      await _settle();
      expect(player.seeks, [_seconds(10)]);

      player.emitPosition(_seconds(10) - 20000);
      player.emitPosition(_seconds(8) + 20000);
      await _settle();
      player.delaySeeks = false;
      player.completeNextSeek();
      await _settle();

      expect(controller.currentSourceUs, _seconds(10));
      expect(sources.last, _seconds(10));
      expect(player.seeks, [_seconds(10)]);
      expect(player.pauseCount, 1);
      await subscription.cancel();
    },
  );

  test(
    'retains a backward seek target across distant origin-side feedback',
    () async {
      final controller = create(_timeline(10, const []));
      final sources = <int>[];
      final subscription = controller.sourcePositionUs.listen(sources.add);
      player.emitPosition(_seconds(8));
      await _settle();
      player.delaySeeks = true;

      final seekFuture = controller.seekEdited(_seconds(2));
      await _settle();
      expect(player.seeks, [_seconds(2)]);
      expect(player.seekInFlight, 1);

      player.emitPosition(_seconds(2));
      player.emitPosition(_seconds(6));
      await _settle();
      player.completeNextSeek();
      await seekFuture;
      await _settle();

      expect(controller.currentSourceUs, _seconds(2));
      expect(sources.last, _seconds(2));
      expect(player.seeks, [_seconds(2)]);
      expect(player.pauseCount, 0);
      await subscription.cancel();
    },
  );

  test(
    'mode and timeline updates reconcile the latest source position',
    () async {
      final controller = create(_timeline(10, const []));
      player.emitPosition(_seconds(4));
      await _settle();

      await controller.setMode(PlaybackMode.original);
      await controller.updateTimeline(
        _timeline(10, [const _Part(3, 5, SegmentAction.cut)]),
      );
      expect(player.seeks, isEmpty);

      await controller.setMode(PlaybackMode.edited);
      expect(player.seeks, [_seconds(5)]);

      player.emitPosition(_seconds(5));
      await _settle();
      await controller.updateTimeline(
        _timeline(10, [const _Part(5, 7, SegmentAction.cut)]),
      );
      expect(player.seeks, [_seconds(5), _seconds(7)]);
    },
  );

  test(
    'publishes replay-safe clamped integer clocks and switches atomically',
    () async {
      final controller = create(
        _timeline(10, [const _Part(3, 5, SegmentAction.cut)]),
      );
      final sources = <int>[];
      final edited = <int>[];
      final current = <int>[];
      final sourceSubscription = controller.sourcePositionUs.listen(
        sources.add,
      );
      final editedSubscription = controller.editedPositionUs.listen(edited.add);
      final currentSubscription = controller.positionUs.listen(current.add);
      await _settle();
      expect(sources, [0]);
      expect(edited, [0]);
      expect(current, [0]);

      player.emitPosition(_seconds(6) + 500000);
      await _settle();
      expect(controller.currentSourceUs, _seconds(6) + 500000);
      expect(controller.currentEditedUs, _seconds(4) + 500000);
      expect(controller.currentPositionUs, _seconds(4) + 500000);

      await controller.setMode(PlaybackMode.original);
      expect(controller.currentPositionUs, _seconds(6) + 500000);
      expect(current.last, _seconds(6) + 500000);

      player.emitPosition(-7);
      player.emitPosition(_seconds(11));
      await _settle();
      expect(sources.last, _seconds(10));
      expect(edited.last, _seconds(8));

      await controller.dispose();
      final lengths = (sources.length, edited.length, current.length);
      player.emitPosition(_seconds(5));
      await _settle();
      expect((sources.length, edited.length, current.length), lengths);

      await sourceSubscription.cancel();
      await editedSubscription.cancel();
      await currentSubscription.cancel();
    },
  );

  test('validates inputs and owns subscriptions but not the player', () async {
    expect(
      () => EditedPlaybackController(
        player: player,
        timeline: _timeline(1, const []),
        seekToleranceUs: 0,
      ),
      throwsArgumentError,
    );
    final controller = create(_timeline(1, const []));
    expect(player.positionListenCount, 1);
    expect(player.playingListenCount, 1);

    await controller.dispose();
    await controller.dispose();

    expect(player.positionCancelCount, 1);
    expect(player.playingCancelCount, 1);
    expect(player.disposeCount, 0);
    await expectLater(
      controller.setMode(PlaybackMode.original),
      throwsStateError,
    );
    await expectLater(controller.seekEdited(0), throwsStateError);
    await expectLater(
      controller.updateTimeline(_timeline(1, const [])),
      throwsStateError,
    );
  });
}

final class _FakePlaybackPort implements PlaybackPort {
  _FakePlaybackPort() {
    _positions = StreamController<int>.broadcast(
      sync: true,
      onListen: () => positionListenCount += 1,
      onCancel: () => positionCancelCount += 1,
    );
    _playing = StreamController<bool>.broadcast(
      sync: true,
      onListen: () => playingListenCount += 1,
      onCancel: () => playingCancelCount += 1,
    );
  }

  late final StreamController<int> _positions;
  late final StreamController<bool> _playing;
  final List<int> seeks = [];
  final List<double> rates = [];
  final List<Completer<void>> _rateCompletions = [];
  final List<Completer<void>> _seekCompletions = [];
  bool delayRates = false;
  bool delaySeeks = false;
  int playCount = 0;
  int pauseCount = 0;
  int disposeCount = 0;
  int positionListenCount = 0;
  int positionCancelCount = 0;
  int playingListenCount = 0;
  int playingCancelCount = 0;
  int inFlight = 0;
  int maxInFlight = 0;
  int seekInFlight = 0;
  int maxSeekInFlight = 0;

  @override
  Stream<int> get positionUs => _positions.stream;

  @override
  Stream<bool> get playing => _playing.stream;

  @override
  Future<void> open(Uri source) async {}

  @override
  Future<void> play() async => playCount += 1;

  @override
  Future<void> pause() async => pauseCount += 1;

  @override
  Future<void> seek(int sourceUs) async {
    seeks.add(sourceUs);
    if (!delaySeeks) return;
    seekInFlight += 1;
    if (seekInFlight > maxSeekInFlight) maxSeekInFlight = seekInFlight;
    final completer = Completer<void>();
    _seekCompletions.add(completer);
    await completer.future;
    seekInFlight -= 1;
  }

  @override
  Future<void> setRate(double rate) async {
    rates.add(rate);
    if (!delayRates) return;
    inFlight += 1;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    final completer = Completer<void>();
    _rateCompletions.add(completer);
    await completer.future;
    inFlight -= 1;
  }

  @override
  Future<void> dispose() async => disposeCount += 1;

  void emitPosition(int sourceUs) => _positions.add(sourceUs);

  void completeNextRate() {
    _rateCompletions.removeAt(0).complete();
  }

  void completeNextSeek() {
    _seekCompletions.removeAt(0).complete();
  }

  Future<void> close() async {
    for (final completer in _rateCompletions) {
      if (!completer.isCompleted) completer.complete();
    }
    for (final completer in _seekCompletions) {
      if (!completer.isCompleted) completer.complete();
    }
    await _positions.close();
    await _playing.close();
  }
}

final class _Part {
  const _Part(this.startSeconds, this.endSeconds, this.action, {this.rate = 1});

  final int startSeconds;
  final int endSeconds;
  final SegmentAction action;
  final double rate;
}

EffectiveTimeline _timeline(int durationSeconds, List<_Part> parts) =>
    EffectiveTimeline.compose(
      durationUs: _seconds(durationSeconds),
      detected: [
        for (final part in parts)
          _segment(
            part.startSeconds,
            part.endSeconds,
            part.action,
            rate: part.rate,
          ),
      ],
      overrides: const [],
    );

TimelineSegment _segment(
  int startSeconds,
  int endSeconds,
  SegmentAction action, {
  double rate = 1,
}) => TimelineSegment(
  range: SourceTimeRange(_seconds(startSeconds), _seconds(endSeconds)),
  action: action,
  rate: rate,
  origin: SegmentOrigin.detected,
);

TimelineSegment _manual(
  int startSeconds,
  int endSeconds,
  SegmentAction action,
) => TimelineSegment(
  range: SourceTimeRange(_seconds(startSeconds), _seconds(endSeconds)),
  action: action,
  origin: SegmentOrigin.manual,
);

int _seconds(int value) => value * 1000000;

Future<void> _settle() async {
  for (var index = 0; index < 10; index++) {
    await Future<void>.delayed(Duration.zero);
  }
}
