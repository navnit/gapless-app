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
