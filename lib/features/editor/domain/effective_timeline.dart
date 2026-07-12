import 'dart:math';

import 'package:gapless/core/time/source_time_range.dart';
import 'package:gapless/features/editor/domain/timeline_segment.dart';

final class EffectiveTimeline {
  EffectiveTimeline._({
    required this.durationUs,
    required List<TimelineSegment> segments,
  }) : segments = List.unmodifiable(segments),
       editedDurationUs = segments.fold(
         0,
         (duration, segment) => duration + _editedDuration(segment),
       );

  factory EffectiveTimeline.compose({
    required int durationUs,
    required List<TimelineSegment> detected,
    required List<TimelineSegment> overrides,
  }) {
    if (durationUs <= 0) {
      throw ArgumentError.value(durationUs, 'durationUs');
    }

    final inputs = [...detected, ...overrides];
    for (final segment in inputs) {
      _validateRate(segment);
    }

    final boundaries = <int>{0, durationUs};
    for (final segment in inputs) {
      final startUs = min(segment.range.startUs, durationUs);
      final endUs = min(segment.range.endUs, durationUs);
      if (startUs < endUs) {
        boundaries
          ..add(startUs)
          ..add(endUs);
      }
    }

    final sortedBoundaries = boundaries.toList()..sort();
    final effective = <TimelineSegment>[];
    for (var index = 0; index < sortedBoundaries.length - 1; index++) {
      final startUs = sortedBoundaries[index];
      final endUs = sortedBoundaries[index + 1];
      final matching =
          _lastMatching(overrides, startUs, endUs) ??
          _lastMatching(detected, startUs, endUs);
      final next = TimelineSegment(
        range: SourceTimeRange(startUs, endUs),
        action: matching?.action ?? SegmentAction.keep,
        rate: matching?.rate ?? 1.0,
        origin: matching?.origin ?? SegmentOrigin.detected,
      );

      if (effective.isNotEmpty && _canMerge(effective.last, next)) {
        final previous = effective.removeLast();
        effective.add(
          TimelineSegment(
            range: SourceTimeRange(previous.range.startUs, endUs),
            action: previous.action,
            rate: previous.rate,
            origin: previous.origin,
          ),
        );
      } else {
        effective.add(next);
      }
    }

    return EffectiveTimeline._(durationUs: durationUs, segments: effective);
  }

  final int durationUs;
  final List<TimelineSegment> segments;
  final int editedDurationUs;

  int sourceUsForEditedUs(int editedUs) {
    if (editedUs < 0 || editedUs > editedDurationUs) {
      throw RangeError.range(editedUs, 0, editedDurationUs, 'editedUs');
    }
    if (editedUs == editedDurationUs) {
      return durationUs;
    }

    var editedStartUs = 0;
    for (final segment in segments) {
      final segmentEditedDurationUs = _editedDuration(segment);
      final editedEndUs = editedStartUs + segmentEditedDurationUs;
      if (segment.action != SegmentAction.cut && editedUs < editedEndUs) {
        final editedOffsetUs = editedUs - editedStartUs;
        return switch (segment.action) {
          SegmentAction.keep => segment.range.startUs + editedOffsetUs,
          SegmentAction.fastForward =>
            segment.range.startUs + (editedOffsetUs * segment.rate).round(),
          SegmentAction.cut => throw StateError('Unreachable cut mapping'),
        };
      }
      editedStartUs = editedEndUs;
    }

    throw StateError('Edited clock does not map to the source timeline');
  }

  int editedUsForSourceUs(int sourceUs) {
    if (sourceUs < 0 || sourceUs > durationUs) {
      throw RangeError.range(sourceUs, 0, durationUs, 'sourceUs');
    }
    if (sourceUs == durationUs) {
      return editedDurationUs;
    }

    var editedStartUs = 0;
    for (final segment in segments) {
      if (sourceUs < segment.range.endUs) {
        final sourceOffsetUs = sourceUs - segment.range.startUs;
        return switch (segment.action) {
          SegmentAction.keep => editedStartUs + sourceOffsetUs,
          SegmentAction.cut => editedStartUs,
          SegmentAction.fastForward =>
            editedStartUs + (sourceOffsetUs / segment.rate).round(),
        };
      }
      editedStartUs += _editedDuration(segment);
    }

    throw StateError('Source clock does not map to the edited timeline');
  }
}

TimelineSegment? _lastMatching(
  List<TimelineSegment> segments,
  int startUs,
  int endUs,
) {
  for (final segment in segments.reversed) {
    if (segment.range.startUs <= startUs && segment.range.endUs >= endUs) {
      return segment;
    }
  }
  return null;
}

bool _canMerge(TimelineSegment first, TimelineSegment second) =>
    first.range.endUs == second.range.startUs &&
    first.action == second.action &&
    first.rate == second.rate &&
    first.origin == second.origin;

void _validateRate(TimelineSegment segment) {
  if (!segment.rate.isFinite ||
      (segment.action == SegmentAction.fastForward
          ? segment.rate <= 1.0
          : segment.rate != 1.0)) {
    throw ArgumentError.value(segment.rate, 'rate');
  }
}

int _editedDuration(TimelineSegment segment) => switch (segment.action) {
  SegmentAction.keep => segment.range.durationUs,
  SegmentAction.cut => 0,
  SegmentAction.fastForward =>
    (segment.range.durationUs / segment.rate).round(),
};
