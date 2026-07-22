import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/app/app_dependencies.dart';
import 'package:gapless/app/gapless_app.dart';
import 'package:gapless/core/process/process_runner.dart';
import 'package:gapless/core/time/source_time_range.dart';
import 'package:gapless/features/editor/domain/effective_timeline.dart';
import 'package:gapless/features/editor/domain/timeline_segment.dart';
import 'package:gapless/features/editor/domain/analysis_settings.dart';
import 'package:gapless/features/editor/presentation/editor_screen.dart';
import 'package:gapless/features/editor/presentation/editor_view_model.dart';
import 'package:gapless/features/engine/data/auto_editor/auto_editor_adapter.dart';
import 'package:gapless/features/engine/domain/engine_models.dart';
import 'package:gapless/features/engine/domain/engine_port.dart';
import 'package:gapless/features/export/presentation/export_dialog.dart';
import 'package:gapless/features/playback/domain/playback_port.dart';
import 'package:gapless/features/project/domain/project_document.dart';

void main() {
  testWidgets('shows the Gapless empty workspace', (tester) async {
    await tester.pumpWidget(GaplessApp(dependencies: AppDependencies.empty()));

    expect(find.text('Gapless'), findsOneWidget);
    expect(find.text('Open Video'), findsOneWidget);
    expect(find.text('Drop a video here'), findsOneWidget);
  });

  testWidgets('uses the injected editor and approved light theme tokens', (
    tester,
  ) async {
    var created = 0;
    await tester.pumpWidget(
      GaplessApp(
        dependencies: AppDependencies(
          editorViewModelFactory: () {
            created += 1;
            return EditorViewModel.empty();
          },
        ),
      ),
    );

    final context = tester.element(find.byType(EditorScreen));
    final theme = Theme.of(context);
    expect(created, 1);
    expect(theme.textTheme.bodyMedium?.fontFamily, 'InstrumentSans');
    expect(theme.scaffoldBackgroundColor, const Color(0xFFE6E7E9));
    expect(theme.colorScheme.primary, const Color(0xFFE3A63B));
  });

  testWidgets('opens the export dialog when a request is dispatched', (
    tester,
  ) async {
    final host = AppExportDialogHost();
    final dependencies = AppDependencies(
      editorViewModelFactory: () => EditorViewModel.empty(),
      exportDialogs: AppExportDialogServices(
        host: host,
        engine: _StubEngine(),
        destinationPicker: _StubPicker(),
        revealInFolder: _StubRevealer(),
      ),
    );

    await tester.pumpWidget(GaplessApp(dependencies: dependencies));

    unawaited(
      host.request(
        EditorExportRequest(
          source: Uri.file('/videos/interview.mp4'),
          metadata: _metadata(),
          timeline: _timeline(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('export.dialog')), findsOneWidget);
  });

  test(
    'production composition creates a real runtime without starting native work',
    () async {
      final root = Directory.systemTemp.absolute;
      final processRunner = _NoStartProcessRunner();
      final playback = _FakePlayback();
      final dependencies = await AppDependencies.production(
        loadDirectories: () async => AppDirectories(
          applicationSupport: Directory('${root.path}/gapless-support'),
          cache: Directory('${root.path}/gapless-cache'),
          temporary: Directory('${root.path}/gapless-temp'),
          flutterAssets: Directory('${root.path}/gapless-assets'),
        ),
        processRunner: processRunner,
        playbackFactory: () => AppPlayback(playback: playback),
        recents: _MemoryRecents(),
      );

      final editor = dependencies.createEditorViewModel();
      addTearDown(editor.dispose);
      await Future<void>.delayed(Duration.zero);

      expect(editor.runtime, isNotNull);
      expect(editor.runtime!.picker, isA<FileSelectorEditorFilePicker>());
      expect(editor.runtime!.engine, isA<AutoEditorAdapter>());
      expect(editor.runtime!.analysis, isA<CoordinatedEditorAnalysis>());
      expect(
        editor.runtime!.sourceResolver,
        isA<ProjectRepositorySourceResolver>(),
      );
      expect(editor.runtime!.playback, same(playback));
      expect(dependencies.exportDialogs, isNotNull);
      expect(editor.runtime!.exporter, same(dependencies.exportDialogs!.host));
      expect(dependencies.videoController, isNull);
      expect(processRunner.startCalls, 0);

      final timeline = EffectiveTimeline.compose(
        durationUs: 200,
        detected: <TimelineSegment>[
          TimelineSegment(
            range: SourceTimeRange(0, 100),
            action: SegmentAction.cut,
            origin: SegmentOrigin.detected,
          ),
          TimelineSegment(
            range: SourceTimeRange(100, 200),
            action: SegmentAction.keep,
            origin: SegmentOrigin.detected,
          ),
        ],
        overrides: const <TimelineSegment>[],
      );
      await editor.runtime!.onTimelineChanged!(timeline);
      expect(playback.seekCalls, <int>[100]);
      expect(playback.rateCalls, <double>[1]);
      await editor.runtime!.onPreviewModeChanged!(PreviewMode.original);

      editor.dispose();
      await playback.disposed.future;
      expect(playback.events.last, 'playback-dispose');
      expect(playback.events, contains('position-cancel'));
      expect(playback.events, contains('playing-cancel'));
    },
  );

  test(
    'production playback drops the old timeline before opening a new source',
    () async {
      final root = Directory.systemTemp.absolute;
      final playback = _FakePlayback();
      final dependencies = await AppDependencies.production(
        loadDirectories: () async => AppDirectories(
          applicationSupport: Directory('${root.path}/gapless-support'),
          cache: Directory('${root.path}/gapless-cache'),
          temporary: Directory('${root.path}/gapless-temp'),
          flutterAssets: Directory('${root.path}/gapless-assets'),
        ),
        processRunner: _NoStartProcessRunner(),
        playbackFactory: () => AppPlayback(playback: playback),
        recents: _MemoryRecents(),
      );
      final editor = dependencies.createEditorViewModel();
      addTearDown(editor.dispose);
      await Future<void>.delayed(Duration.zero);
      final runtime = editor.runtime!;
      final cutAtStart = EffectiveTimeline.compose(
        durationUs: 200,
        detected: <TimelineSegment>[
          TimelineSegment(
            range: SourceTimeRange(0, 100),
            action: SegmentAction.cut,
            origin: SegmentOrigin.detected,
          ),
          TimelineSegment(
            range: SourceTimeRange(100, 200),
            action: SegmentAction.keep,
            origin: SegmentOrigin.detected,
          ),
        ],
        overrides: const <TimelineSegment>[],
      );
      await runtime.onTimelineChanged!(cutAtStart);
      expect(playback.seekCalls, <int>[100]);
      playback.seekCalls.clear();

      await runtime.onSourceWillOpen!(PreviewMode.original);
      final source = Uri.file('/videos/new-source.mp4');
      await runtime.playback.open(source);
      playback.emitPosition(0);
      await Future<void>.delayed(Duration.zero);

      expect(playback.opened, <Uri>[source]);
      expect(playback.seekCalls, isEmpty);

      await runtime.onTimelineChanged!(cutAtStart);
      expect(playback.seekCalls, isEmpty);

      editor.dispose();
      await playback.disposed.future;
      expect(
        playback.events.where((event) => event == 'playback-dispose'),
        hasLength(1),
      );
    },
  );
}

final class _NoStartProcessRunner implements ProcessRunner {
  var startCalls = 0;

  @override
  Future<RunningProcess> start(ProcessRequest request) {
    startCalls += 1;
    throw StateError('Production composition started a process eagerly.');
  }
}

final class _FakePlayback implements PlaybackPort {
  _FakePlayback() {
    _positions = StreamController<int>.broadcast(
      sync: true,
      onCancel: () => events.add('position-cancel'),
    );
    _playing = StreamController<bool>.broadcast(
      sync: true,
      onCancel: () => events.add('playing-cancel'),
    );
  }

  late final StreamController<int> _positions;
  late final StreamController<bool> _playing;
  final events = <String>[];
  final opened = <Uri>[];
  final seekCalls = <int>[];
  final rateCalls = <double>[];
  final disposed = Completer<void>();

  @override
  Stream<bool> get playing => _playing.stream;

  @override
  Stream<int> get positionUs => _positions.stream;

  @override
  Future<void> dispose() async {
    events.add('playback-dispose');
    await _positions.close();
    await _playing.close();
    if (!disposed.isCompleted) disposed.complete();
  }

  @override
  Future<void> open(Uri source) async => opened.add(source);

  @override
  Future<void> pause() async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> seek(int sourceUs) async => seekCalls.add(sourceUs);

  @override
  Future<void> setRate(double rate) async => rateCalls.add(rate);

  void emitPosition(int sourceUs) => _positions.add(sourceUs);
}

final class _MemoryRecents implements RecentProjectsPort {
  @override
  Future<bool> exists(Uri project) async => false;

  @override
  Future<List<Uri>> load() async => const <Uri>[];

  @override
  Future<void> save(List<Uri> projects) async {}
}

final class _StubEngine implements EnginePort {
  @override
  EngineTask<Uri> render(RenderRequest request) => throw UnimplementedError();

  @override
  EngineTask<DetectedTimeline> detect(Uri source, AnalysisSettings settings) =>
      throw UnimplementedError();

  @override
  EngineTask<AnalysisLevels> levels(Uri source, AnalysisMethod method) =>
      throw UnimplementedError();

  @override
  EngineTask<MediaMetadata> probe(Uri source) => throw UnimplementedError();
}

final class _StubPicker implements ExportDestinationPicker {
  @override
  Future<Uri?> chooseMp4Destination(Uri? suggested) async => null;
}

final class _StubRevealer implements ExportRevealInFolder {
  @override
  Future<void> reveal(Uri file) async {}
}

MediaMetadata _metadata() => MediaMetadata(
  durationUs: 1000000,
  timebaseNumerator: 1,
  timebaseDenominator: 30,
  resolution: SizeInt(1920, 1080),
  videoCodec: 'h264',
  hasAudio: true,
  sampleRate: 48000,
  audioLayout: 'stereo',
);

EffectiveTimeline _timeline() => EffectiveTimeline.compose(
  durationUs: 1000000,
  detected: <TimelineSegment>[
    TimelineSegment(
      range: SourceTimeRange(0, 700000),
      action: SegmentAction.keep,
      origin: SegmentOrigin.detected,
    ),
    TimelineSegment(
      range: SourceTimeRange(700000, 1000000),
      action: SegmentAction.cut,
      origin: SegmentOrigin.detected,
    ),
  ],
  overrides: const <TimelineSegment>[],
);
