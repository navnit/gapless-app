import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/core/time/source_time_range.dart';
import 'package:gapless/features/editor/domain/effective_timeline.dart';
import 'package:gapless/features/editor/domain/timeline_segment.dart';
import 'package:gapless/features/editor/presentation/timeline_view_model.dart';
import 'package:gapless/features/engine/domain/engine_models.dart';

void main() {
  group('timeline intents', () {
    test('have structural equality and hash codes', () {
      expect(const SeekTimelineIntent(42), const SeekTimelineIntent(42));
      expect(
        ToggleSegmentIntent(SourceTimeRange(1, 2)),
        ToggleSegmentIntent(SourceTimeRange(1, 2)),
      );
      expect(
        const SetTimelineZoomIntent(2.5, 42),
        const SetTimelineZoomIntent(2.5, 42),
      );
      final uniqueIntents = <TimelineIntent>{};
      uniqueIntents.addAll(<TimelineIntent>[
        const SeekTimelineIntent(42),
        const SeekTimelineIntent(42),
        ToggleSegmentIntent(SourceTimeRange(1, 2)),
        ToggleSegmentIntent(SourceTimeRange(1, 2)),
      ]);
      expect(uniqueIntents, hasLength(2));
    });
  });

  group('source-time geometry', () {
    test('maps zoomed and scrolled coordinates exactly in source time', () {
      final model = _model(viewportWidth: 1000, zoom: 2, scrollPx: 500);

      expect(model.contentWidth, 2000);
      expect(model.maxScrollPx, 1000);
      expect(model.scrollPx, 500);
      expect(model.sourceUsAtX(500), 5_000_000);
      expect(model.xAtSourceUs(5_000_000), 500);

      for (final x in <double>[0, 125.5, 500, 999.25, 1000]) {
        expect(
          model.sourceUsAtX(model.xAtSourceUs(model.sourceUsAtX(x))),
          closeTo(model.sourceUsAtX(x), 1),
        );
      }
    });

    test('clamps zoom, scroll, coordinates, and anchor-preserving zoom', () {
      expect(_model(zoom: 0.2).zoom, 1);
      expect(_model(zoom: 40).zoom, 12);
      expect(_model(zoom: 2, scrollPx: -20).scrollPx, 0);
      expect(_model(zoom: 2, scrollPx: 20_000).scrollPx, 1000);

      final model = _model(viewportWidth: 1000, zoom: 2, scrollPx: 500);
      final before = model.sourceUsAtX(320);
      final viewport = model.zoomAroundAnchor(4, 320);
      final zoomed = _model(
        viewportWidth: 1000,
        zoom: viewport.zoom,
        scrollPx: viewport.scrollPx,
      );

      expect(viewport.anchorSourceUs, before);
      expect(zoomed.sourceUsAtX(320), closeTo(before, 1));
      expect(model.zoomAroundAnchor(0, 500).zoom, 1);
      expect(model.zoomAroundAnchor(99, 500).zoom, 12);
      expect(model.sourceUsAtX(-50), 2_500_000);
      expect(model.sourceUsAtX(1050), 7_500_000);
    });
  });

  group('segment geometry and hit testing', () {
    test('clips visible actions and preserves exact source ranges', () {
      final model = _model(viewportWidth: 1000, zoom: 2, scrollPx: 500);

      expect(
        model.segments.map((primitive) => primitive.segment.action),
        <SegmentAction>[
          SegmentAction.cut,
          SegmentAction.fastForward,
          SegmentAction.keep,
        ],
      );
      expect(
        model.segments.map((primitive) => primitive.segment.range),
        <SourceTimeRange>[
          SourceTimeRange(2_000_000, 4_000_000),
          SourceTimeRange(4_000_000, 6_000_000),
          SourceTimeRange(6_000_000, 8_000_000),
        ],
      );
      expect(model.segments.first.paintRect.left, 0);
      expect(model.segments.last.paintRect.right, 1000);
      expect(model.segments.last.segment.origin, SegmentOrigin.manual);
      expect(model.segments[1].segment.rate, 4);
    });

    test('uses half-open boundaries and total duration selects the last', () {
      final zoomed = _model(viewportWidth: 1000, zoom: 2, scrollPx: 500);
      final y = zoomed.decisionRect.center.dy;
      final boundaryX = zoomed.xAtSourceUs(4_000_000);

      expect(
        zoomed.segmentAt(Offset(boundaryX - 0.001, y))?.action,
        SegmentAction.cut,
      );
      expect(
        zoomed.segmentAt(Offset(boundaryX, y))?.action,
        SegmentAction.fastForward,
      );
      expect(zoomed.segmentAt(Offset(boundaryX, 2)), isNull);

      final fitted = _model(viewportWidth: 1000);
      expect(
        fitted.segmentAt(Offset(1000, fitted.decisionRect.center.dy))?.range,
        SourceTimeRange(8_000_000, 10_000_000),
      );
    });
  });

  group('visible drawing primitives', () {
    test('max-downsamples only visible samples into bottom-aligned bars', () {
      final samples = List<int>.filled(80, 1000)
        ..[15] = 50_000
        ..[62] = 60_000;

      for (final height in <double>[28, 52, 170]) {
        final model = _model(
          viewportWidth: 8,
          waveformHeight: height,
          samples: samples,
          samplePeriodUs: 125_000,
        );

        expect(model.waveformBars, hasLength(2));
        expect(model.waveformBars.map((bar) => bar.peak), <int>[
          50_000,
          60_000,
        ]);
        expect(
          model.waveformBars.every(
            (bar) =>
                bar.rect.left >= 0 &&
                bar.rect.right <= 8 &&
                bar.rect.bottom == height,
          ),
          isTrue,
        );
      }
    });

    test('adapts visible ruler ticks with stable intervals and labels', () {
      final model = _model(
        durationUs: 600_000_000,
        viewportWidth: 960,
        samples: const [0],
        samplePeriodUs: 600_000_000,
      );

      expect(model.rulerTicks.length, greaterThanOrEqualTo(5));
      expect(model.rulerTicks.first.label, '0:00');
      final interval =
          model.rulerTicks[1].sourceUs - model.rulerTicks.first.sourceUs;
      expect(_isOneTwoFive(interval), isTrue);
      expect(
        model.rulerTicks.map((tick) => tick.x).toList().fold<double>(
          double.infinity,
          (gap, x) {
            final index = model.rulerTicks.indexWhere((tick) => tick.x == x);
            if (index == 0) return gap;
            return (x - model.rulerTicks[index - 1].x).clamp(0, gap);
          },
        ),
        greaterThanOrEqualTo(80),
      );
      expect(TimelineViewModel.formatRulerTime(3_661_000_000), '1:01:01');
    });

    test('clips playhead geometry to the visible viewport', () {
      final hidden = _model(
        viewportWidth: 1000,
        zoom: 2,
        scrollPx: 500,
        sourcePositionUs: 1_000_000,
      );
      final visible = _model(
        viewportWidth: 1000,
        zoom: 2,
        scrollPx: 500,
        sourcePositionUs: 5_000_000,
      );

      expect(hidden.playhead, isNull);
      expect(visible.playhead?.x, 500);
      expect(visible.playhead?.lineRect.width, 2);
      expect(visible.playhead?.capRadius, 5);
    });
  });

  test('rejects invalid finite geometry and threshold inputs', () {
    expect(() => _model(viewportWidth: 0), throwsArgumentError);
    expect(() => _model(waveformHeight: double.nan), throwsArgumentError);
    expect(() => _model(thresholdFraction: -0.1), throwsArgumentError);
    expect(() => _model(thresholdFraction: 1.1), throwsArgumentError);
  });
}

TimelineViewModel _model({
  int durationUs = 10_000_000,
  double viewportWidth = 1000,
  double waveformHeight = 52,
  double zoom = 1,
  double scrollPx = 0,
  double thresholdFraction = 0.35,
  int sourcePositionUs = 5_000_000,
  List<int>? samples,
  int samplePeriodUs = 100_000,
}) {
  final detected = <TimelineSegment>[];
  final overrides = <TimelineSegment>[];
  if (durationUs == 10_000_000) {
    detected.addAll(<TimelineSegment>[
      TimelineSegment(
        range: SourceTimeRange(2_000_000, 4_000_000),
        action: SegmentAction.cut,
        origin: SegmentOrigin.detected,
      ),
      TimelineSegment(
        range: SourceTimeRange(4_000_000, 6_000_000),
        action: SegmentAction.fastForward,
        rate: 4,
        origin: SegmentOrigin.detected,
      ),
    ]);
    overrides.add(
      TimelineSegment(
        range: SourceTimeRange(6_000_000, 8_000_000),
        action: SegmentAction.keep,
        origin: SegmentOrigin.manual,
      ),
    );
  }

  return TimelineViewModel(
    levels: AnalysisLevels(
      samples: samples ?? List<int>.generate(100, (index) => index * 600),
      samplePeriodUs: samplePeriodUs,
    ),
    timeline: EffectiveTimeline.compose(
      durationUs: durationUs,
      detected: detected,
      overrides: overrides,
    ),
    sourcePositionUs: sourcePositionUs.clamp(0, durationUs),
    viewportWidth: viewportWidth,
    waveformHeight: waveformHeight,
    zoom: zoom,
    scrollPx: scrollPx,
    thresholdFraction: thresholdFraction,
  );
}

bool _isOneTwoFive(int intervalUs) {
  var value = intervalUs;
  while (value >= 10 && value % 10 == 0) {
    value ~/= 10;
  }
  return value == 1 || value == 2 || value == 5;
}
