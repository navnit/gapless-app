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
import 'package:gapless/features/editor/presentation/editor_screen.dart';
import 'package:gapless/features/editor/presentation/editor_view_model.dart';
import 'package:gapless/features/engine/data/auto_editor/auto_editor_adapter.dart';
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
  Future<void> open(Uri source) async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> seek(int sourceUs) async => seekCalls.add(sourceUs);

  @override
  Future<void> setRate(double rate) async => rateCalls.add(rate);
}

final class _MemoryRecents implements RecentProjectsPort {
  @override
  Future<bool> exists(Uri project) async => false;

  @override
  Future<List<Uri>> load() async => const <Uri>[];

  @override
  Future<void> save(List<Uri> projects) async {}
}
