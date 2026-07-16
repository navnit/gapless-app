import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/core/time/source_time_range.dart';
import 'package:gapless/features/editor/domain/effective_timeline.dart';
import 'package:gapless/features/editor/domain/timeline_segment.dart';
import 'package:gapless/features/editor/presentation/timeline_view_model.dart';
import 'package:gapless/features/editor/presentation/widgets/timeline_painter.dart';
import 'package:gapless/features/editor/presentation/widgets/timeline_view.dart';
import 'package:gapless/features/engine/domain/engine_models.dart';

void main() {
  test('fast-forward waveform uses the inactive palette treatment', () {
    final palette = TimelinePalette.fromBrightness(Brightness.dark);

    expect(palette.waveformColorFor(SegmentAction.keep), palette.keptWaveform);
    expect(palette.waveformColorFor(SegmentAction.cut), palette.cutWaveform);
    expect(
      palette.waveformColorFor(SegmentAction.fastForward),
      palette.cutWaveform,
    );
  });

  testWidgets('segment click emits only its exact toggle intent', (
    tester,
  ) async {
    _setScreen(tester, const Size(800, 400));
    final intents = <TimelineIntent>[];
    await tester.pumpWidget(_harness(onIntent: intents.add));

    final model = _paintedModel(tester);
    final surface = tester.getTopLeft(find.byKey(TimelineView.surfaceKey));
    await tester.tapAt(
      surface +
          Offset(model.xAtSourceUs(4_000_000), model.decisionRect.center.dy),
    );
    await tester.pump();

    expect(intents, <TimelineIntent>[
      ToggleSegmentIntent(SourceTimeRange(3_000_000, 5_000_000)),
    ]);
  });

  testWidgets('waveform tap and drag emit clamped source-time seeks', (
    tester,
  ) async {
    _setScreen(tester, const Size(800, 400));
    final intents = <TimelineIntent>[];
    await tester.pumpWidget(_harness(onIntent: intents.add));

    final model = _paintedModel(tester);
    final origin = tester.getTopLeft(find.byKey(TimelineView.surfaceKey));
    await tester.tapAt(
      origin + Offset(model.viewportWidth * 0.25, model.waveformHeight / 2),
    );
    await tester.pump();
    expect(intents.single, const SeekTimelineIntent(2_500_000));

    intents.clear();
    await tester.dragFrom(
      origin + Offset(model.viewportWidth * 0.25, model.rulerRect.center.dy),
      Offset(model.viewportWidth, 0),
    );
    await tester.pump();
    expect(intents, isNotEmpty);
    expect(intents, everyElement(isA<SeekTimelineIntent>()));
    expect(intents.last, const SeekTimelineIntent(10_000_000));
  });

  testWidgets('modifier wheel zooms around pointer and plain wheel scrolls', (
    tester,
  ) async {
    _setScreen(tester, const Size(800, 400));
    final intents = <TimelineIntent>[];
    await tester.pumpWidget(_harness(onIntent: intents.add));

    final surfaceFinder = find.byKey(TimelineView.surfaceKey);
    final before = _paintedModel(tester);
    final localX = before.viewportWidth * 0.3;
    final pointer = tester.getTopLeft(surfaceFinder) + Offset(localX, 20);
    final sourceUnderPointer = before.sourceUsAtX(localX);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendEventToBinding(
      PointerScrollEvent(position: pointer, scrollDelta: const Offset(0, -180)),
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    final afterZoom = _paintedModel(tester);
    expect(afterZoom.zoom, greaterThan(1));
    expect(afterZoom.sourceUsAtX(localX), closeTo(sourceUnderPointer, 1));
    expect(intents.single, isA<SetTimelineZoomIntent>());
    expect(
      intents.single,
      SetTimelineZoomIntent(afterZoom.zoom, sourceUnderPointer),
    );

    intents.clear();
    final scrollBefore = afterZoom.scrollPx;
    await tester.sendEventToBinding(
      PointerScrollEvent(position: pointer, scrollDelta: const Offset(90, 0)),
    );
    await tester.pump();
    expect(_paintedModel(tester).scrollPx, greaterThan(scrollBefore));
    expect(intents, isEmpty);
  });

  testWidgets('zoom controls anchor consistently, clamp, and Fit resets', (
    tester,
  ) async {
    _setScreen(tester, const Size(800, 400));
    final intents = <TimelineIntent>[];
    await tester.pumpWidget(_harness(onIntent: intents.add));

    for (var index = 0; index < 8; index++) {
      await tester.tap(find.byTooltip('Zoom in'));
      await tester.pump();
    }
    expect(_paintedModel(tester).zoom, 12);
    expect(find.text('1200%'), findsOneWidget);
    expect(intents.last, isA<SetTimelineZoomIntent>());

    await tester.tap(find.byTooltip('Fit whole timeline'));
    await tester.pump();
    final fitted = _paintedModel(tester);
    expect(fitted.zoom, 1);
    expect(fitted.scrollPx, 0);
    expect(find.text('100%'), findsOneWidget);

    await tester.tap(find.byTooltip('Zoom out'));
    await tester.pump();
    expect(_paintedModel(tester).zoom, 1);
  });

  testWidgets('publishes actionable segment semantics for every state', (
    tester,
  ) async {
    _setScreen(tester, const Size(1000, 500));
    final semantics = tester.ensureSemantics();
    final intents = <TimelineIntent>[];
    await tester.pumpWidget(
      _harness(timeline: _semanticTimeline(), onIntent: intents.add),
    );

    const removed = 'Removed segment, 2.0 to 4.0 seconds, activate to keep';
    const kept = 'Kept segment, 0.0 to 2.0 seconds, activate to remove';
    const fast =
        'Fast-forward 4× segment, 4.0 to 6.0 seconds, '
        'activate to keep at normal speed';
    const manual =
        'Kept segment, 6.0 to 8.0 seconds, manual edit, activate to remove';

    for (final label in <String>[removed, kept, fast, manual]) {
      final finder = find.bySemanticsLabel(label);
      expect(finder, findsOneWidget);
      expect(
        tester
            .getSemantics(finder)
            .getSemanticsData()
            .hasAction(SemanticsAction.tap),
        isTrue,
      );
    }

    tester.semantics.tap(find.semantics.byLabel(removed));
    await tester.pump();
    expect(
      intents.single,
      ToggleSegmentIntent(SourceTimeRange(2_000_000, 4_000_000)),
    );
    expect(find.byTooltip('Zoom in'), findsOneWidget);
    expect(find.byTooltip('Zoom out'), findsOneWidget);
    expect(find.byTooltip('Fit whole timeline'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('rebuilds geometry for resize, theme, and replacement inputs', (
    tester,
  ) async {
    _setScreen(tester, const Size(1280, 832));
    await tester.pumpWidget(_harness(brightness: Brightness.dark));
    expect(tester.takeException(), isNull);
    expect(_paintedModel(tester).viewportWidth, 1248);
    expect(_painter(tester).palette.panel, const Color(0xFF1A1C20));
    final oldPlayheadX = _paintedModel(tester).playhead!.x;

    await tester.pumpWidget(
      _harness(
        brightness: Brightness.light,
        sourcePositionUs: 8_000_000,
        levels: AnalysisLevels(
          samples: const [65535, 0, 65535, 0],
          samplePeriodUs: 2_500_000,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(_painter(tester).palette.panel, const Color(0xFFF5F5F6));
    expect(_paintedModel(tester).playhead!.x, isNot(oldPlayheadX));

    _setScreen(tester, const Size(960, 640));
    await tester.pumpWidget(_harness(brightness: Brightness.light));
    expect(tester.takeException(), isNull);
    expect(_paintedModel(tester).viewportWidth, 928);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomLeft,
            child: SizedBox(width: 700, child: _timeline()),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(_paintedModel(tester).viewportWidth, 668);
  });

  testWidgets('matches the reviewed dark timeline baseline', (tester) async {
    _setScreen(tester, const Size(1280, 832));
    await tester.pumpWidget(
      _harness(brightness: Brightness.dark, golden: true),
    );
    await expectLater(
      find.byKey(const ValueKey<String>('timeline.golden')),
      matchesGoldenFile('../../../goldens/timeline_dark.png'),
    );
  });

  testWidgets('matches the reviewed light timeline baseline', (tester) async {
    _setScreen(tester, const Size(1280, 832));
    await tester.pumpWidget(
      _harness(brightness: Brightness.light, golden: true),
    );
    await expectLater(
      find.byKey(const ValueKey<String>('timeline.golden')),
      matchesGoldenFile('../../../goldens/timeline_light.png'),
    );
  });
}

Widget _harness({
  Brightness brightness = Brightness.dark,
  EffectiveTimeline? timeline,
  AnalysisLevels? levels,
  int sourcePositionUs = 5_000_000,
  ValueChanged<TimelineIntent>? onIntent,
  bool golden = false,
}) {
  final background = brightness == Brightness.dark
      ? const Color(0xFF121316)
      : const Color(0xFFE6E7E9);
  final child = MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(brightness: brightness, useMaterial3: true),
    home: Scaffold(
      backgroundColor: background,
      body: Align(
        alignment: Alignment.bottomCenter,
        child: TimelineView(
          levels: levels ?? _levels(),
          timeline: timeline ?? _timelineValue(),
          sourcePositionUs: sourcePositionUs,
          thresholdFraction: 0.34,
          waveformHeight: 52,
          onIntent: onIntent ?? (_) {},
        ),
      ),
    ),
  );
  if (!golden) return child;
  return RepaintBoundary(
    key: const ValueKey<String>('timeline.golden'),
    child: child,
  );
}

Widget _timeline() => Material(
  child: TimelineView(
    levels: _levels(),
    timeline: _timelineValue(),
    sourcePositionUs: 5_000_000,
    thresholdFraction: 0.34,
    waveformHeight: 52,
    onIntent: (_) {},
  ),
);

AnalysisLevels _levels() => AnalysisLevels(
  samples: List<int>.generate(240, (index) {
    final wave = (index % 31 - 15).abs();
    return (6000 + wave * 3500).clamp(0, 65535);
  }),
  samplePeriodUs: 41_667,
);

EffectiveTimeline _timelineValue() => EffectiveTimeline.compose(
  durationUs: 10_000_000,
  detected: <TimelineSegment>[
    TimelineSegment(
      range: SourceTimeRange(3_000_000, 5_000_000),
      action: SegmentAction.cut,
      origin: SegmentOrigin.detected,
    ),
    TimelineSegment(
      range: SourceTimeRange(7_000_000, 8_500_000),
      action: SegmentAction.fastForward,
      rate: 4,
      origin: SegmentOrigin.detected,
    ),
  ],
  overrides: <TimelineSegment>[
    TimelineSegment(
      range: SourceTimeRange(5_000_000, 6_000_000),
      action: SegmentAction.keep,
      origin: SegmentOrigin.manual,
    ),
  ],
);

EffectiveTimeline _semanticTimeline() => EffectiveTimeline.compose(
  durationUs: 10_000_000,
  detected: <TimelineSegment>[
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
  ],
  overrides: <TimelineSegment>[
    TimelineSegment(
      range: SourceTimeRange(6_000_000, 8_000_000),
      action: SegmentAction.keep,
      origin: SegmentOrigin.manual,
    ),
  ],
);

TimelinePainter _painter(WidgetTester tester) =>
    tester.widget<CustomPaint>(find.byKey(TimelineView.surfaceKey)).painter!
        as TimelinePainter;

TimelineViewModel _paintedModel(WidgetTester tester) => _painter(tester).model;

void _setScreen(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}
