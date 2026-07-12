import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/core/time/source_time_range.dart';
import 'package:gapless/features/editor/domain/effective_timeline.dart';
import 'package:gapless/features/editor/domain/timeline_segment.dart';

void main() {
  group('EffectiveTimeline.compose', () {
    test('manual keep splits and overrides a detected cut', () {
      final timeline = EffectiveTimeline.compose(
        durationUs: _seconds(10),
        detected: [_segment(0, 10, SegmentAction.cut)],
        overrides: [_manual(3, 6, SegmentAction.keep)],
      );

      expect(_segments(timeline), [
        _expected(0, 3, SegmentAction.cut),
        _expected(3, 6, SegmentAction.keep, origin: SegmentOrigin.manual),
        _expected(6, 10, SegmentAction.cut),
      ]);
    });

    test('last matching manual override wins', () {
      final timeline = EffectiveTimeline.compose(
        durationUs: _seconds(10),
        detected: [_segment(0, 10, SegmentAction.cut)],
        overrides: [
          _manual(2, 8, SegmentAction.keep),
          _manual(4, 6, SegmentAction.fastForward, rate: 2),
        ],
      );

      expect(_segments(timeline), [
        _expected(0, 2, SegmentAction.cut),
        _expected(2, 4, SegmentAction.keep, origin: SegmentOrigin.manual),
        _expected(
          4,
          6,
          SegmentAction.fastForward,
          rate: 2,
          origin: SegmentOrigin.manual,
        ),
        _expected(6, 8, SegmentAction.keep, origin: SegmentOrigin.manual),
        _expected(8, 10, SegmentAction.cut),
      ]);
    });

    test('clips ranges to the source duration', () {
      final timeline = EffectiveTimeline.compose(
        durationUs: _seconds(10),
        detected: [_segment(8, 15, SegmentAction.cut)],
        overrides: const [],
      );

      expect(_segments(timeline), [
        _expected(0, 8, SegmentAction.keep),
        _expected(8, 10, SegmentAction.cut),
      ]);
    });

    test('merges adjacent identical effective actions', () {
      final timeline = EffectiveTimeline.compose(
        durationUs: _seconds(10),
        detected: [
          _segment(1, 3, SegmentAction.cut),
          _segment(3, 5, SegmentAction.cut),
        ],
        overrides: const [],
      );

      expect(_segments(timeline), [
        _expected(0, 1, SegmentAction.keep),
        _expected(1, 5, SegmentAction.cut),
        _expected(5, 10, SegmentAction.keep),
      ]);
    });

    test('keeps the entire source when no gaps match', () {
      final timeline = EffectiveTimeline.compose(
        durationUs: _seconds(10),
        detected: [_segment(12, 15, SegmentAction.cut)],
        overrides: [_manual(20, 22, SegmentAction.fastForward, rate: 4)],
      );

      expect(_segments(timeline), [_expected(0, 10, SegmentAction.keep)]);
      expect(timeline.editedDurationUs, _seconds(10));
    });

    test('rejects zero and negative source durations', () {
      for (final durationUs in [0, -1]) {
        expect(
          () => EffectiveTimeline.compose(
            durationUs: durationUs,
            detected: const [],
            overrides: const [],
          ),
          throwsArgumentError,
          reason: 'duration $durationUs must be rejected',
        );
      }
    });

    test(
      'does not merge adjacent fast-forward segments at different rates',
      () {
        final timeline = EffectiveTimeline.compose(
          durationUs: _seconds(4),
          detected: [
            _segment(0, 2, SegmentAction.fastForward, rate: 2),
            _segment(2, 4, SegmentAction.fastForward, rate: 4),
          ],
          overrides: const [],
        );

        expect(_segments(timeline), [
          _expected(0, 2, SegmentAction.fastForward, rate: 2),
          _expected(2, 4, SegmentAction.fastForward, rate: 4),
        ]);
      },
    );

    test(
      'does not merge adjacent identical actions from different origins',
      () {
        final timeline = EffectiveTimeline.compose(
          durationUs: _seconds(4),
          detected: [_segment(0, 2, SegmentAction.cut)],
          overrides: [_manual(2, 4, SegmentAction.cut)],
        );

        expect(_segments(timeline), [
          _expected(0, 2, SegmentAction.cut),
          _expected(2, 4, SegmentAction.cut, origin: SegmentOrigin.manual),
        ]);
      },
    );

    test('last matching detected segment wins when detections overlap', () {
      final cutThenFastForward = EffectiveTimeline.compose(
        durationUs: _seconds(6),
        detected: [
          _segment(0, 6, SegmentAction.cut),
          _segment(2, 4, SegmentAction.fastForward, rate: 2),
        ],
        overrides: const [],
      );
      final fastForwardThenCut = EffectiveTimeline.compose(
        durationUs: _seconds(6),
        detected: [
          _segment(2, 4, SegmentAction.fastForward, rate: 2),
          _segment(0, 6, SegmentAction.cut),
        ],
        overrides: const [],
      );

      expect(_segments(cutThenFastForward), [
        _expected(0, 2, SegmentAction.cut),
        _expected(2, 4, SegmentAction.fastForward, rate: 2),
        _expected(4, 6, SegmentAction.cut),
      ]);
      expect(_segments(fastForwardThenCut), [
        _expected(0, 6, SegmentAction.cut),
      ]);
    });

    test('preserves valid fast-forward rates', () {
      final timeline = EffectiveTimeline.compose(
        durationUs: _seconds(4),
        detected: [_segment(0, 4, SegmentAction.fastForward, rate: 4)],
        overrides: const [],
      );

      expect(timeline.segments.single.rate, 4);
      expect(timeline.editedDurationUs, _seconds(1));
    });

    test('rejects non-finite and out-of-range rates', () {
      for (final rate in [double.nan, double.infinity, 0.0, 1.0]) {
        expect(
          () => EffectiveTimeline.compose(
            durationUs: _seconds(1),
            detected: [_segment(0, 1, SegmentAction.fastForward, rate: rate)],
            overrides: const [],
          ),
          throwsArgumentError,
          reason: 'rate $rate must be rejected for fast-forward',
        );
      }

      expect(
        () => EffectiveTimeline.compose(
          durationUs: _seconds(1),
          detected: [_segment(0, 1, SegmentAction.keep, rate: 2)],
          overrides: const [],
        ),
        throwsArgumentError,
      );
    });
  });
}

int _seconds(int value) => value * 1000000;

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
  SegmentAction action, {
  double rate = 1,
}) => TimelineSegment(
  range: SourceTimeRange(_seconds(startSeconds), _seconds(endSeconds)),
  action: action,
  rate: rate,
  origin: SegmentOrigin.manual,
);

typedef _ExpectedSegment = ({
  SourceTimeRange range,
  SegmentAction action,
  double rate,
  SegmentOrigin origin,
});

_ExpectedSegment _expected(
  int startSeconds,
  int endSeconds,
  SegmentAction action, {
  double rate = 1,
  SegmentOrigin origin = SegmentOrigin.detected,
}) => (
  range: SourceTimeRange(_seconds(startSeconds), _seconds(endSeconds)),
  action: action,
  rate: rate,
  origin: origin,
);

List<_ExpectedSegment> _segments(EffectiveTimeline timeline) => timeline
    .segments
    .map(
      (segment) => (
        range: segment.range,
        action: segment.action,
        rate: segment.rate,
        origin: segment.origin,
      ),
    )
    .toList();
