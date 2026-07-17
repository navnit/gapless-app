import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/core/time/source_time_range.dart';
import 'package:gapless/features/editor/domain/effective_timeline.dart';
import 'package:gapless/features/editor/domain/timeline_segment.dart';
import 'package:gapless/features/editor/presentation/editor_view_model.dart';
import 'package:gapless/features/editor/presentation/timeline_view_model.dart';
import 'package:gapless/features/editor/presentation/widgets/studio_toolbar.dart';
import 'package:gapless/features/editor/presentation/widgets/timeline_view.dart';
import 'package:gapless/features/editor/presentation/widgets/video_preview.dart';
import 'package:gapless/features/engine/domain/engine_models.dart';
import 'package:gapless/features/project/domain/project_document.dart';

void main() {
  testWidgets('transport and timeline controls expose stable semantic labels', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();

    await _pumpTimeline(tester);

    expect(find.bySemanticsLabel('Zoom out'), findsOneWidget);
    expect(find.bySemanticsLabel('Zoom in'), findsOneWidget);
    expect(find.bySemanticsLabel('Fit whole timeline'), findsOneWidget);
    expect(
      find.bySemanticsLabel(
        'Kept segment, 0.0 to 1.0 seconds, activate to remove',
      ),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(
        'Removed segment, 1.0 to 2.0 seconds, activate to keep',
      ),
      findsOneWidget,
    );

    await _pumpPreview(tester, isPlaying: false);
    expect(find.bySemanticsLabel('Play'), findsOneWidget);

    await _pumpPreview(tester, isPlaying: true);
    expect(find.bySemanticsLabel('Pause'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets(
    'toolbar traversal begins logically and has a visible focus cue',
    (tester) async {
      await _pumpToolbar(tester);
      final open = find.byKey(const ValueKey<String>('toolbar.open'));

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();

      expect(_hasFocusedDescendant(tester, open), isTrue);
      final orderValues = tester
          .widgetList<FocusTraversalOrder>(
            find.descendant(
              of: find.byType(StudioToolbar),
              matching: find.byType(FocusTraversalOrder),
            ),
          )
          .map((widget) => (widget.order as NumericFocusOrder).order);
      expect(orderValues, orderedEquals(<double>[1, 2, 3]));

      final inkWell = tester
          .widgetList<InkWell>(
            find.descendant(of: open, matching: find.byType(InkWell)),
          )
          .first;
      final focusColor =
          inkWell.focusColor ?? Theme.of(tester.element(open)).focusColor;
      expect(focusColor.a, greaterThan(0));
    },
  );

  testWidgets(
    'interactive editor targets are at least 40 by 40 logical pixels',
    (tester) async {
      final sizes = <String, Size>{};
      await _pumpTimeline(tester);
      sizes['Zoom out'] = tester.getSize(find.byTooltip('Zoom out'));
      sizes['Zoom in'] = tester.getSize(find.byTooltip('Zoom in'));
      sizes['Fit whole timeline'] = tester.getSize(
        find.byTooltip('Fit whole timeline'),
      );

      await _pumpPreview(tester, isPlaying: false);
      sizes['Play'] = tester.getSize(
        find.byKey(const ValueKey<String>('preview.playPause')),
      );

      await _pumpToolbar(tester);
      sizes['Preview mode'] = tester.getSize(
        find.byType(SegmentedButton<PreviewMode>),
      );

      final undersized = sizes.entries
          .where((entry) => entry.value.width < 40 || entry.value.height < 40)
          .map((entry) => '${entry.key}: ${entry.value}')
          .toList(growable: false);
      expect(
        undersized,
        isEmpty,
        reason: 'Desktop controls need a minimum 40x40 logical hit target.',
      );
    },
  );

  testWidgets('key timeline text meets light and dark contrast thresholds', (
    tester,
  ) async {
    final ratios = <Brightness, double>{};
    for (final brightness in Brightness.values) {
      await _pumpTimeline(tester, brightness: brightness);
      final label = tester.widget<Text>(find.text('TIMELINE'));
      final panel = tester
          .widgetList<Material>(
            find.descendant(
              of: find.byType(TimelineView),
              matching: find.byType(Material),
            ),
          )
          .first;
      ratios[brightness] = _contrastRatio(label.style!.color!, panel.color!);
    }

    final insufficient = ratios.entries
        .where((entry) => entry.value < 4.5)
        .map(
          (entry) => '${entry.key.name}: ${entry.value.toStringAsFixed(2)}:1',
        )
        .toList(growable: false);
    expect(
      insufficient,
      isEmpty,
      reason: 'Small timeline labels require at least 4.5:1 contrast.',
    );
  });

  testWidgets('reduced motion leaves timeline controls immediately usable', (
    tester,
  ) async {
    final intents = <TimelineIntent>[];
    await _pumpTimeline(tester, disableAnimations: true, onIntent: intents.add);

    await tester.tap(find.byTooltip('Zoom in'));
    await tester.pump();

    expect(intents, hasLength(1));
    expect(intents.single, isA<SetTimelineZoomIntent>());
    expect(tester.binding.transientCallbackCount, 0);
  });
}

Future<void> _pumpTimeline(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
  bool disableAnimations = false,
  ValueChanged<TimelineIntent>? onIntent,
}) => tester.pumpWidget(
  _testApp(
    brightness: brightness,
    disableAnimations: disableAnimations,
    child: SizedBox(
      width: 800,
      child: TimelineView(
        levels: _levels(),
        timeline: _timeline(),
        sourcePositionUs: 0,
        thresholdFraction: 0.1,
        waveformHeight: 60,
        onIntent: onIntent ?? (_) {},
      ),
    ),
  ),
);

Future<void> _pumpPreview(WidgetTester tester, {required bool isPlaying}) =>
    tester.pumpWidget(
      _testApp(
        child: SizedBox(
          width: 720,
          height: 360,
          child: VideoPreview(
            state: EditorState(
              phase: EditorPhase.ready,
              metadata: _metadata(),
              timeline: _timeline(),
              isPlaying: isPlaying,
            ),
            controller: null,
            onTogglePlayback: () {},
          ),
        ),
      ),
    );

Future<void> _pumpToolbar(WidgetTester tester) => tester.pumpWidget(
  _testApp(
    child: FocusTraversalGroup(
      policy: OrderedTraversalPolicy(),
      child: StudioToolbar(
        state: EditorState(phase: EditorPhase.ready, timeline: _timeline()),
        onOpenVideo: () {},
        onOpenProject: (_) {},
        onPreviewModeChanged: (_) {},
        onExport: () {},
      ),
    ),
  ),
);

Widget _testApp({
  required Widget child,
  Brightness brightness = Brightness.light,
  bool disableAnimations = false,
}) => MaterialApp(
  theme: ThemeData(useMaterial3: true, brightness: brightness),
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: Scaffold(body: Center(child: child)),
  ),
);

bool _hasFocusedDescendant(WidgetTester tester, Finder finder) {
  final target = tester.element(finder);
  final focusedContext = FocusManager.instance.primaryFocus?.context;
  if (focusedContext is! Element) return false;
  var containsFocus = identical(focusedContext, target);
  focusedContext.visitAncestorElements((ancestor) {
    containsFocus = containsFocus || identical(ancestor, target);
    return !containsFocus;
  });
  return containsFocus;
}

double _contrastRatio(Color foreground, Color background) {
  final foregroundLuminance = foreground.computeLuminance();
  final backgroundLuminance = background.computeLuminance();
  final lighter = foregroundLuminance > backgroundLuminance
      ? foregroundLuminance
      : backgroundLuminance;
  final darker = foregroundLuminance > backgroundLuminance
      ? backgroundLuminance
      : foregroundLuminance;
  return (lighter + 0.05) / (darker + 0.05);
}

AnalysisLevels _levels() => AnalysisLevels(
  samples: const <int>[4000, 12000, 30000, 8000, 2000, 26000, 9000, 1000],
  samplePeriodUs: 250000,
);

EffectiveTimeline _timeline() => EffectiveTimeline.compose(
  durationUs: 2000000,
  detected: <TimelineSegment>[
    TimelineSegment(
      range: SourceTimeRange(0, 1000000),
      action: SegmentAction.keep,
      origin: SegmentOrigin.detected,
    ),
    TimelineSegment(
      range: SourceTimeRange(1000000, 2000000),
      action: SegmentAction.cut,
      origin: SegmentOrigin.detected,
    ),
  ],
  overrides: const <TimelineSegment>[],
);

MediaMetadata _metadata() => MediaMetadata(
  durationUs: 2000000,
  timebaseNumerator: 1,
  timebaseDenominator: 30,
  resolution: SizeInt(1920, 1080),
  videoCodec: 'h264',
  hasAudio: true,
  sampleRate: 48000,
  audioLayout: 'stereo',
);
