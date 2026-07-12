import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/core/time/source_time_range.dart';
import 'package:gapless/features/editor/domain/effective_timeline.dart';
import 'package:gapless/features/editor/domain/timeline_segment.dart';

void main() {
  group('EffectiveTimeline clock', () {
    test('maps edited time across removed source ranges', () {
      final timeline = _timeline(
        durationSeconds: 10,
        segments: [_segment(3, 5, SegmentAction.cut)],
      );

      expect(timeline.sourceUsForEditedUs(_seconds(4)), _seconds(6));
      expect(timeline.editedDurationUs, _seconds(8));
    });

    test('maps cut boundaries consistently in both directions', () {
      final timeline = _timeline(
        durationSeconds: 10,
        segments: [_segment(3, 5, SegmentAction.cut)],
      );

      expect(timeline.editedUsForSourceUs(_seconds(3)), _seconds(3));
      expect(timeline.editedUsForSourceUs(_seconds(4)), _seconds(3));
      expect(timeline.editedUsForSourceUs(_seconds(5)), _seconds(3));
      expect(timeline.sourceUsForEditedUs(_seconds(3)), _seconds(5));
      expect(timeline.sourceUsForEditedUs(0), 0);
      expect(timeline.sourceUsForEditedUs(_seconds(8)), _seconds(10));
    });

    test('maps fast-forward spans and their boundaries', () {
      final timeline = _timeline(
        durationSeconds: 8,
        segments: [_segment(2, 6, SegmentAction.fastForward, rate: 2)],
      );

      expect(timeline.editedDurationUs, _seconds(6));
      expect(timeline.sourceUsForEditedUs(_seconds(3)), _seconds(4));
      expect(timeline.editedUsForSourceUs(_seconds(5)), 3500000);
      expect(timeline.sourceUsForEditedUs(_seconds(4)), _seconds(6));
      expect(timeline.editedUsForSourceUs(_seconds(6)), _seconds(4));
    });

    test('rounds a fractional fast-forward rate to integer microseconds', () {
      final timeline = _rawTimeline(
        durationUs: 10,
        segments: [_rawSegment(1, 8, SegmentAction.fastForward, rate: 2.5)],
      );

      expect(timeline.editedDurationUs, 6);
      _expectClockMappings(
        timeline,
        editedToSource: {0: 0, 1: 1, 2: 4, 3: 6, 4: 8, 5: 9, 6: 10},
        sourceToEdited: {
          0: 0,
          1: 1,
          2: 1,
          3: 2,
          4: 2,
          5: 3,
          6: 3,
          7: 3,
          8: 4,
          9: 5,
          10: 6,
        },
      );
    });

    test('maps multiple cut and fast-forward discontinuities exactly', () {
      final timeline = _rawTimeline(
        durationUs: 20,
        segments: [
          _rawSegment(2, 4, SegmentAction.cut),
          _rawSegment(6, 10, SegmentAction.fastForward, rate: 2),
          _rawSegment(12, 15, SegmentAction.cut),
        ],
      );

      expect(timeline.editedDurationUs, 13);
      _expectClockMappings(
        timeline,
        editedToSource: {
          0: 0,
          1: 1,
          2: 4,
          3: 5,
          4: 6,
          5: 8,
          6: 10,
          7: 11,
          8: 15,
          9: 16,
          13: 20,
        },
        sourceToEdited: {
          0: 0,
          1: 1,
          2: 2,
          3: 2,
          4: 2,
          5: 3,
          6: 4,
          8: 5,
          10: 6,
          11: 7,
          12: 8,
          14: 8,
          15: 8,
          16: 9,
          20: 13,
        },
      );
    });

    test('maps leading and trailing cuts at starts, interiors, and ends', () {
      final timeline = _rawTimeline(
        durationUs: 10,
        segments: [
          _rawSegment(0, 2, SegmentAction.cut),
          _rawSegment(8, 10, SegmentAction.cut),
        ],
      );

      expect(timeline.editedDurationUs, 6);
      _expectClockMappings(
        timeline,
        editedToSource: {0: 2, 1: 3, 5: 7, 6: 10},
        sourceToEdited: {0: 0, 1: 0, 2: 0, 3: 1, 7: 5, 8: 6, 9: 6, 10: 6},
      );
    });

    test('maps an all-cut timeline to its collapsed edited clock', () {
      final timeline = _rawTimeline(
        durationUs: 10,
        segments: [_rawSegment(0, 10, SegmentAction.cut)],
      );

      expect(timeline.editedDurationUs, 0);
      _expectClockMappings(
        timeline,
        editedToSource: {0: 10},
        sourceToEdited: {0: 0, 1: 0, 5: 0, 9: 0, 10: 0},
      );
    });

    test('rejects positions outside either clock', () {
      final timeline = _timeline(durationSeconds: 2, segments: const []);

      expect(() => timeline.sourceUsForEditedUs(-1), throwsRangeError);
      expect(
        () => timeline.sourceUsForEditedUs(_seconds(2) + 1),
        throwsRangeError,
      );
      expect(() => timeline.editedUsForSourceUs(-1), throwsRangeError);
      expect(
        () => timeline.editedUsForSourceUs(_seconds(2) + 1),
        throwsRangeError,
      );
    });
  });
}

EffectiveTimeline _timeline({
  required int durationSeconds,
  required List<TimelineSegment> segments,
}) => EffectiveTimeline.compose(
  durationUs: _seconds(durationSeconds),
  detected: segments,
  overrides: const [],
);

EffectiveTimeline _rawTimeline({
  required int durationUs,
  required List<TimelineSegment> segments,
}) => EffectiveTimeline.compose(
  durationUs: durationUs,
  detected: segments,
  overrides: const [],
);

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

TimelineSegment _rawSegment(
  int startUs,
  int endUs,
  SegmentAction action, {
  double rate = 1,
}) => TimelineSegment(
  range: SourceTimeRange(startUs, endUs),
  action: action,
  rate: rate,
  origin: SegmentOrigin.detected,
);

void _expectClockMappings(
  EffectiveTimeline timeline, {
  required Map<int, int> editedToSource,
  required Map<int, int> sourceToEdited,
}) {
  for (final entry in editedToSource.entries) {
    expect(
      timeline.sourceUsForEditedUs(entry.key),
      entry.value,
      reason: 'edited ${entry.key}us must map to source ${entry.value}us',
    );
  }
  for (final entry in sourceToEdited.entries) {
    expect(
      timeline.editedUsForSourceUs(entry.key),
      entry.value,
      reason: 'source ${entry.key}us must map to edited ${entry.value}us',
    );
  }
}
