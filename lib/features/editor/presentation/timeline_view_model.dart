import 'dart:math' as math;
import 'dart:ui';

import 'package:gapless/core/time/source_time_range.dart';
import 'package:gapless/features/editor/domain/effective_timeline.dart';
import 'package:gapless/features/editor/domain/timeline_segment.dart';
import 'package:gapless/features/engine/domain/engine_models.dart';

sealed class TimelineIntent {
  const TimelineIntent();
}

final class SeekTimelineIntent extends TimelineIntent {
  const SeekTimelineIntent(this.sourceUs);

  final int sourceUs;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SeekTimelineIntent && sourceUs == other.sourceUs;

  @override
  int get hashCode => sourceUs.hashCode;
}

final class ToggleSegmentIntent extends TimelineIntent {
  const ToggleSegmentIntent(this.range);

  final SourceTimeRange range;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ToggleSegmentIntent && range == other.range;

  @override
  int get hashCode => range.hashCode;
}

final class SetTimelineZoomIntent extends TimelineIntent {
  const SetTimelineZoomIntent(this.zoom, this.anchorSourceUs);

  final double zoom;
  final int anchorSourceUs;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SetTimelineZoomIntent &&
          zoom == other.zoom &&
          anchorSourceUs == other.anchorSourceUs;

  @override
  int get hashCode => Object.hash(zoom, anchorSourceUs);
}

final class TimelineViewportGeometry {
  const TimelineViewportGeometry({
    required this.zoom,
    required this.scrollPx,
    required this.anchorSourceUs,
  });

  final double zoom;
  final double scrollPx;
  final int anchorSourceUs;
}

final class WaveformBarPrimitive {
  const WaveformBarPrimitive({
    required this.rect,
    required this.peak,
    required this.action,
  });

  final Rect rect;
  final int peak;
  final SegmentAction action;
}

final class TimelineSegmentPrimitive {
  const TimelineSegmentPrimitive({
    required this.segment,
    required this.hitRect,
    required this.paintRect,
  });

  final TimelineSegment segment;
  final Rect hitRect;
  final Rect paintRect;
}

final class RulerTickPrimitive {
  const RulerTickPrimitive({
    required this.x,
    required this.sourceUs,
    required this.label,
  });

  final double x;
  final int sourceUs;
  final String label;
}

final class PlayheadPrimitive {
  const PlayheadPrimitive({
    required this.x,
    required this.lineRect,
    required this.capCenter,
    required this.capRadius,
  });

  final double x;
  final Rect lineRect;
  final Offset capCenter;
  final double capRadius;
}

final class TimelineViewModel {
  TimelineViewModel({
    required this.levels,
    required this.timeline,
    required int sourcePositionUs,
    required double viewportWidth,
    required double waveformHeight,
    required double zoom,
    required double scrollPx,
    required this.thresholdFraction,
  }) : viewportWidth = _requirePositiveFinite(viewportWidth, 'viewportWidth'),
       waveformHeight = _requirePositiveFinite(
         waveformHeight,
         'waveformHeight',
       ),
       zoom = _clampZoom(zoom),
       sourcePositionUs = sourcePositionUs.clamp(0, timeline.durationUs) {
    if (!thresholdFraction.isFinite ||
        thresholdFraction < 0 ||
        thresholdFraction > 1) {
      throw ArgumentError.value(thresholdFraction, 'thresholdFraction');
    }
    contentWidth = this.viewportWidth * this.zoom;
    maxScrollPx = math.max(0, contentWidth - this.viewportWidth);
    this.scrollPx = _finiteOrZero(scrollPx).clamp(0, maxScrollPx);

    waveformRect = Rect.fromLTWH(0, 0, this.viewportWidth, this.waveformHeight);
    decisionRect = Rect.fromLTWH(
      0,
      this.waveformHeight + waveformDecisionGap,
      this.viewportWidth,
      decisionStripHeight,
    );
    rulerRect = Rect.fromLTWH(
      0,
      decisionRect.bottom + decisionRulerGap,
      this.viewportWidth,
      rulerHeight,
    );
    surfaceHeight = rulerRect.bottom;

    segments = List.unmodifiable(_buildSegments());
    waveformBars = List.unmodifiable(_buildWaveformBars());
    rulerTicks = List.unmodifiable(_buildRulerTicks());
    playhead = _buildPlayhead();
  }

  static const double minimumZoom = 1;
  static const double maximumZoom = 12;
  static const double waveformDecisionGap = 6;
  static const double decisionStripHeight = 26;
  static const double decisionRulerGap = 4;
  static const double rulerHeight = 16;
  static const double waveformBarPitch = 4;
  static const double waveformBarGap = 1;
  static const double minimumRulerSpacing = 88;

  final AnalysisLevels levels;
  final EffectiveTimeline timeline;
  final int sourcePositionUs;
  final double viewportWidth;
  final double waveformHeight;
  final double zoom;
  final double thresholdFraction;

  late final double contentWidth;
  late final double maxScrollPx;
  late final double scrollPx;
  late final Rect waveformRect;
  late final Rect decisionRect;
  late final Rect rulerRect;
  late final double surfaceHeight;
  late final List<TimelineSegmentPrimitive> segments;
  late final List<WaveformBarPrimitive> waveformBars;
  late final List<RulerTickPrimitive> rulerTicks;
  late final PlayheadPrimitive? playhead;

  double get thresholdY =>
      waveformHeight - thresholdFraction * math.max(0, waveformHeight - 6);

  int sourceUsAtX(double x) {
    final visibleX = _finiteOrZero(x).clamp(0, viewportWidth);
    final fraction = (scrollPx + visibleX) / contentWidth;
    return (fraction * timeline.durationUs).round().clamp(
      0,
      timeline.durationUs,
    );
  }

  double xAtSourceUs(int sourceUs) {
    final clamped = sourceUs.clamp(0, timeline.durationUs);
    return clamped / timeline.durationUs * contentWidth - scrollPx;
  }

  TimelineViewportGeometry zoomAroundAnchor(
    double requestedZoom,
    double anchorX,
  ) {
    final nextZoom = _clampZoom(requestedZoom);
    final visibleAnchorX = _finiteOrZero(
      anchorX,
    ).clamp(0, viewportWidth).toDouble();
    final anchorSourceUs = sourceUsAtX(visibleAnchorX);
    final nextContentWidth = viewportWidth * nextZoom;
    final nextMaxScroll = math.max(0, nextContentWidth - viewportWidth);
    final nextScroll =
        (anchorSourceUs / timeline.durationUs * nextContentWidth -
                visibleAnchorX)
            .clamp(0, nextMaxScroll)
            .toDouble();
    return TimelineViewportGeometry(
      zoom: nextZoom,
      scrollPx: nextScroll,
      anchorSourceUs: anchorSourceUs,
    );
  }

  TimelineSegment? segmentAt(Offset position) {
    if (!decisionRect.contains(position) &&
        !(position.dx == viewportWidth &&
            position.dy >= decisionRect.top &&
            position.dy < decisionRect.bottom)) {
      return null;
    }
    final sourceUs = sourceUsAtX(position.dx);
    return _segmentForSource(sourceUs);
  }

  bool isSeekPosition(Offset position) =>
      waveformRect.contains(position) ||
      rulerRect.contains(position) ||
      (position.dx == viewportWidth &&
          (position.dy >= waveformRect.top &&
                  position.dy < waveformRect.bottom ||
              position.dy >= rulerRect.top && position.dy < rulerRect.bottom));

  static String formatRulerTime(int sourceUs) {
    final totalSeconds = sourceUs ~/ Duration.microsecondsPerSecond;
    final hours = totalSeconds ~/ 3600;
    final minutes = totalSeconds ~/ 60 % 60;
    final seconds = totalSeconds % 60;
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:'
          '${seconds.toString().padLeft(2, '0')}';
    }
    return '${totalSeconds ~/ 60}:${seconds.toString().padLeft(2, '0')}';
  }

  List<TimelineSegmentPrimitive> _buildSegments() {
    final result = <TimelineSegmentPrimitive>[];
    for (final segment in timeline.segments) {
      final rawLeft = xAtSourceUs(segment.range.startUs);
      final rawRight = xAtSourceUs(segment.range.endUs);
      if (rawRight <= 0 || rawLeft >= viewportWidth) {
        continue;
      }
      final left = rawLeft.clamp(0, viewportWidth).toDouble();
      final right = rawRight.clamp(0, viewportWidth).toDouble();
      final hitRect = Rect.fromLTRB(
        left,
        decisionRect.top,
        right,
        decisionRect.bottom,
      );
      final height = segment.action == SegmentAction.keep
          ? decisionRect.height
          : decisionRect.height * 0.62;
      final paintRect = Rect.fromLTWH(
        left,
        decisionRect.center.dy - height / 2,
        right - left,
        height,
      );
      result.add(
        TimelineSegmentPrimitive(
          segment: segment,
          hitRect: hitRect,
          paintRect: paintRect,
        ),
      );
    }
    return result;
  }

  List<WaveformBarPrimitive> _buildWaveformBars() {
    final barCount = math.max(1, (viewportWidth / waveformBarPitch).ceil());
    final bars = <WaveformBarPrimitive>[];
    for (var index = 0; index < barCount; index++) {
      final left = index * waveformBarPitch;
      if (left >= viewportWidth) break;
      final right = math.min(viewportWidth, left + waveformBarPitch);
      final sourceStartUs = sourceUsAtX(left);
      final sourceEndUs = sourceUsAtX(right);
      final peak = _maxSample(sourceStartUs, sourceEndUs);
      final availableHeight = math.max(0, waveformHeight - 6);
      final height = math.min(
        waveformHeight,
        math.max(2, peak / 65535 * availableHeight),
      );
      final paintRight = math.max(left, right - waveformBarGap);
      final midpointUs = sourceStartUs + (sourceEndUs - sourceStartUs) ~/ 2;
      bars.add(
        WaveformBarPrimitive(
          rect: Rect.fromLTRB(
            left,
            waveformHeight - height,
            paintRight,
            waveformHeight,
          ),
          peak: peak,
          action: _segmentForSource(midpointUs).action,
        ),
      );
    }
    return bars;
  }

  int _maxSample(int sourceStartUs, int sourceEndUs) {
    if (levels.samples.isEmpty) return 0;
    final safeEndUs = math.max(sourceStartUs + 1, sourceEndUs);
    final first = (sourceStartUs ~/ levels.samplePeriodUs).clamp(
      0,
      levels.samples.length,
    );
    final lastExclusive = ((safeEndUs - 1) ~/ levels.samplePeriodUs + 1).clamp(
      0,
      levels.samples.length,
    );
    if (first >= lastExclusive) return 0;
    var peak = 0;
    for (var index = first; index < lastExclusive; index++) {
      peak = math.max(peak, levels.samples[index]);
    }
    return peak;
  }

  List<RulerTickPrimitive> _buildRulerTicks() {
    final visibleStartUs = sourceUsAtX(0);
    final visibleEndUs = sourceUsAtX(viewportWidth);
    final sourceUsPerPixel = timeline.durationUs / contentWidth;
    final intervalUs = _niceIntervalUs(sourceUsPerPixel * minimumRulerSpacing);
    final firstTickUs = (visibleStartUs / intervalUs).ceil() * intervalUs;
    final ticks = <RulerTickPrimitive>[];
    for (
      var sourceUs = firstTickUs;
      sourceUs <= visibleEndUs && sourceUs <= timeline.durationUs;
      sourceUs += intervalUs
    ) {
      final x = xAtSourceUs(sourceUs);
      if (x >= 0 && x <= viewportWidth) {
        ticks.add(
          RulerTickPrimitive(
            x: x,
            sourceUs: sourceUs,
            label: formatRulerTime(sourceUs),
          ),
        );
      }
    }
    return ticks;
  }

  PlayheadPrimitive? _buildPlayhead() {
    final x = xAtSourceUs(sourcePositionUs);
    if (x < 0 || x > viewportWidth) return null;
    return PlayheadPrimitive(
      x: x,
      lineRect: Rect.fromLTWH(x - 1, 0, 2, decisionRect.bottom),
      capCenter: Offset(x, 5),
      capRadius: 5,
    );
  }

  TimelineSegment _segmentForSource(int sourceUs) {
    if (sourceUs == timeline.durationUs) return timeline.segments.last;
    for (final segment in timeline.segments) {
      if (sourceUs >= segment.range.startUs && sourceUs < segment.range.endUs) {
        return segment;
      }
    }
    throw StateError('Canonical timeline does not contain $sourceUs');
  }
}

double _requirePositiveFinite(double value, String name) {
  if (!value.isFinite || value <= 0) {
    throw ArgumentError.value(value, name);
  }
  return value;
}

double _finiteOrZero(double value) => value.isFinite ? value : 0;

double _clampZoom(double value) {
  if (!value.isFinite) return TimelineViewModel.minimumZoom;
  return value.clamp(
    TimelineViewModel.minimumZoom,
    TimelineViewModel.maximumZoom,
  );
}

int _niceIntervalUs(double requestedUs) {
  final minimum = Duration.microsecondsPerSecond.toDouble();
  final request = math.max(minimum, requestedUs);
  final exponent = math.pow(10, (math.log(request) / math.ln10).floor());
  final fraction = request / exponent;
  final niceFraction = fraction <= 1
      ? 1
      : fraction <= 2
      ? 2
      : fraction <= 5
      ? 5
      : 10;
  return (niceFraction * exponent).round();
}
