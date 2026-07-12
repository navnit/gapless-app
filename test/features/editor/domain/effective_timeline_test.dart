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

      expect(_actions(timeline), ['cut:0-3', 'keep:3-6', 'cut:6-10']);
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

      expect(_actions(timeline), [
        'cut:0-2',
        'keep:2-4',
        'fastForward@2.0:4-6',
        'keep:6-8',
        'cut:8-10',
      ]);
    });

    test('clips ranges to the source duration', () {
      final timeline = EffectiveTimeline.compose(
        durationUs: _seconds(10),
        detected: [_segment(8, 15, SegmentAction.cut)],
        overrides: const [],
      );

      expect(_actions(timeline), ['keep:0-8', 'cut:8-10']);
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

      expect(_actions(timeline), ['keep:0-1', 'cut:1-5', 'keep:5-10']);
    });

    test('keeps the entire source when no gaps match', () {
      final timeline = EffectiveTimeline.compose(
        durationUs: _seconds(10),
        detected: [_segment(12, 15, SegmentAction.cut)],
        overrides: [_manual(20, 22, SegmentAction.fastForward, rate: 4)],
      );

      expect(_actions(timeline), ['keep:0-10']);
      expect(timeline.editedDurationUs, _seconds(10));
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

List<String> _actions(EffectiveTimeline timeline) =>
    timeline.segments.map((segment) {
      final start = segment.range.startUs ~/ 1000000;
      final end = segment.range.endUs ~/ 1000000;
      final rate = segment.action == SegmentAction.fastForward
          ? '@${segment.rate.toStringAsFixed(1)}'
          : '';
      return '${segment.action.name}$rate:$start-$end';
    }).toList();
