import 'package:gapless/core/time/source_time_range.dart';

enum SegmentAction { keep, cut, fastForward }

enum SegmentOrigin { detected, manual }

final class TimelineSegment {
  const TimelineSegment({
    required this.range,
    required this.action,
    this.rate = 1.0,
    required this.origin,
  });

  final SourceTimeRange range;
  final SegmentAction action;
  final double rate;
  final SegmentOrigin origin;
}
