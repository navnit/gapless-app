import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/core/errors/app_failure.dart';
import 'package:gapless/core/time/source_time_range.dart';
import 'package:gapless/app/app_dependencies.dart';
import 'package:gapless/app/gapless_app.dart';
import 'package:gapless/features/analysis/application/analysis_coordinator.dart';
import 'package:gapless/features/editor/domain/analysis_settings.dart';
import 'package:gapless/features/editor/domain/effective_timeline.dart';
import 'package:gapless/features/editor/domain/timeline_segment.dart';
import 'package:gapless/features/editor/presentation/editor_screen.dart';
import 'package:gapless/features/editor/presentation/editor_view_model.dart';
import 'package:gapless/features/editor/presentation/timeline_view_model.dart';
import 'package:gapless/features/engine/domain/engine_models.dart';
import 'package:gapless/features/engine/domain/engine_port.dart';
import 'package:gapless/features/playback/domain/playback_port.dart';
import 'package:gapless/features/project/application/autosave_controller.dart';
import 'package:gapless/features/project/data/project_repository.dart';
import 'package:gapless/features/project/domain/project_document.dart';
import 'package:gapless/features/project/domain/source_reference.dart';
import 'package:path/path.dart' as p;

import '../../../helpers/tolerant_golden_comparator.dart';

void main() {
  setUpAll(() async {
    installTolerantGoldenComparator();
    final font = rootBundle.load(
      'assets/fonts/InstrumentSans-VariableFont_wdth,wght.ttf',
    );
    await (FontLoader('InstrumentSans')..addFont(font)).load();
    await (FontLoader('monospace')..addFont(font)).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  testWidgets('shows approved controls for a ready project', (tester) async {
    await _pumpEditor(tester, _readyState());

    expect(find.text('Audio'), findsOneWidget);
    expect(find.text('Motion'), findsOneWidget);
    expect(find.text('THRESHOLD'), findsOneWidget);
    expect(find.text('MARGIN'), findsOneWidget);
    expect(find.text('Cut out'), findsOneWidget);
    expect(find.text('Fast-forward'), findsOneWidget);
    expect(find.text('Original'), findsOneWidget);
    expect(find.text('Edited'), findsOneWidget);
    expect(find.text('Export…'), findsOneWidget);
    expect(find.text('Saved'), findsOneWidget);
    expect(find.text('EDITED'), findsOneWidget);
  });

  testWidgets('shows the beginner empty workspace', (tester) async {
    await _pumpEditor(tester, const EditorState.empty());

    expect(find.text('Gapless'), findsOneWidget);
    expect(find.text('Drop a video here'), findsOneWidget);
    expect(find.text('Open Video'), findsOneWidget);
    expect(find.byIcon(Icons.remove), findsNothing);
    expect(find.byIcon(Icons.crop_square), findsNothing);
    expect(find.byIcon(Icons.close), findsNothing);
    expect(find.text('THRESHOLD'), findsNothing);
  });

  testWidgets('shows a graceful failure message in the empty workspace', (
    tester,
  ) async {
    await _pumpEditor(
      tester,
      const EditorState(
        phase: EditorPhase.empty,
        message:
            'A video file is required. Audio-only files are not supported yet. '
            'Choose a video file and try again.',
      ),
    );

    expect(find.textContaining('Audio-only files are not supported'), findsOne);
    expect(find.text('Open Video'), findsOneWidget);
    expect(find.textContaining('Instance of'), findsNothing);
  });

  testWidgets('offers Copy diagnostics for an engine failure', (tester) async {
    final captured = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          captured.add((call.arguments as Map<Object?, Object?>)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    final ready = _readyState();
    final failing =
        EditorState.analyzing(
          project: ready.project!,
          projectUri: ready.projectUri!,
          metadata: ready.metadata!,
          message:
              'Editing engine could not finish. Your project is safe. '
              'Try again or copy diagnostics for more detail.',
        ).copyWith(
          failure: EngineContractFailure(
            operation: 'detect',
            reason: EngineContractReason.invalidTimeline,
            diagnostics: const <String>['boundary drift'],
          ),
        );

    await _pumpEditor(tester, failing);

    expect(find.text('Copy diagnostics'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('failure.copyDiagnostics')),
    );
    await tester.pump();

    expect(captured, hasLength(1));
    expect(captured.single, contains('Gapless diagnostics'));
    expect(captured.single, contains('EngineContractFailure'));
  });

  testWidgets('hides Copy diagnostics when there is no failure', (tester) async {
    await _pumpEditor(
      tester,
      const EditorState(phase: EditorPhase.empty, message: 'Just a status.'),
    );

    expect(find.text('Copy diagnostics'), findsNothing);
  });

  testWidgets('shows analysis progress without leaving the studio', (
    tester,
  ) async {
    final ready = _readyState();
    await _pumpEditor(
      tester,
      EditorState.analyzing(
        project: ready.project!,
        projectUri: ready.projectUri!,
        metadata: ready.metadata!,
        message: 'Reading audio loudness…',
      ),
    );

    expect(find.text('Analyzing…'), findsOneWidget);
    expect(find.text('Reading audio loudness…'), findsOneWidget);
    expect(find.text('Audio'), findsOneWidget);
  });

  testWidgets('offers recovery when autosave fails', (tester) async {
    await _pumpEditor(
      tester,
      _readyState().copyWith(saveStatus: EditorSaveStatus.failed),
    );

    expect(find.text('Saving failed'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Save As…'), findsOneWidget);
  });

  testWidgets('offers Motion when the source has no audio track', (
    tester,
  ) async {
    await _pumpEditor(tester, _readyState().copyWith(audioUnavailable: true));

    expect(find.text('This video has no audio track.'), findsOneWidget);
    expect(find.text('Use Motion'), findsOneWidget);
  });

  test(
    'manual timeline toggles autosave without requesting analysis',
    () async {
      final analysis = _FakeAnalysis();
      final store = _MemoryProjectStore();
      final runtime = _runtime(analysis: analysis, store: store);
      final viewModel = EditorViewModel(
        initialState: _readyState(),
        runtime: runtime,
      );
      addTearDown(viewModel.dispose);

      await viewModel.handleTimelineIntent(
        ToggleSegmentIntent(_segments[1].range),
      );

      expect(viewModel.state.project!.manualOverrides, hasLength(1));
      expect(
        viewModel.state.project!.manualOverrides.single.action,
        SegmentAction.keep,
      );
      expect(analysis.requests, isEmpty);
      expect(store.savedDocuments, hasLength(1));
      expect(viewModel.state.saveStatus, EditorSaveStatus.saved);
    },
  );

  test(
    'manual timeline toggles persist before playback reconciliation fails',
    () async {
      final analysis = _FakeAnalysis();
      final store = _MemoryProjectStore();
      final viewModel = EditorViewModel(
        initialState: _readyState(),
        runtime: _runtime(
          analysis: analysis,
          store: store,
          onTimelineChanged: (_) async {
            throw StateError('playback reconciliation failed');
          },
        ),
      );
      addTearDown(viewModel.dispose);

      await expectLater(
        viewModel.handleTimelineIntent(ToggleSegmentIntent(_segments[1].range)),
        throwsStateError,
      );

      expect(store.savedDocuments, hasLength(1));
      expect(store.savedDocuments.single.manualOverrides, hasLength(1));
      expect(viewModel.state.saveStatus, EditorSaveStatus.saved);
    },
  );

  test(
    'detection settings clear manual choices and request analysis',
    () async {
      final analysis = _FakeAnalysis();
      final store = _MemoryProjectStore();
      final viewModel = EditorViewModel(
        initialState: _readyStateWithManualOverride(),
        runtime: _runtime(analysis: analysis, store: store),
      );
      addTearDown(viewModel.dispose);

      await viewModel.setThresholdDb(-18);

      expect(viewModel.state.project!.settings.thresholdDb, -18);
      expect(viewModel.state.project!.manualOverrides, isEmpty);
      expect(viewModel.state.manualOverridesCleared, isTrue);
      expect(analysis.requests, hasLength(1));
      expect(analysis.requests.single.settings.thresholdDb, -18);
    },
  );

  test('records an engine failure then clears it when analysis re-runs', () async {
    final analysis = _FakeAnalysis();
    final store = _MemoryProjectStore();
    final viewModel = EditorViewModel(
      initialState: _readyState(),
      runtime: _runtime(analysis: analysis, store: store),
    );
    addTearDown(viewModel.dispose);

    await viewModel.setThresholdDb(-18);
    analysis.emitFor(
      analysis.requests.last,
      AnalysisFailed(
        EngineContractFailure(
          operation: 'detect',
          reason: EngineContractReason.invalidTimeline,
          diagnostics: const <String>['boundary drift'],
        ),
        null,
      ),
    );

    expect(viewModel.state.failure, isA<EngineContractFailure>());

    // A fresh run must drop the stale failure so "Copy diagnostics" cannot
    // linger beside a live progress spinner.
    await viewModel.setThresholdDb(-17);
    analysis.emitFor(
      analysis.requests.last,
      AnalysisRunning(null, EngineProgress(stage: EngineStage.analyzing)),
    );

    expect(viewModel.state.failure, isNull);
    expect(viewModel.state.phase, EditorPhase.analyzing);
  });

  testWidgets(
    'threshold drag previews locally and requests analysis only on release',
    (tester) async {
      final analysis = _FakeAnalysis();
      final store = _MemoryProjectStore();
      final viewModel = EditorViewModel(
        initialState: _readyState(),
        runtime: _runtime(analysis: analysis, store: store),
      );
      addTearDown(viewModel.dispose);
      await _pumpViewModel(tester, viewModel);
      final threshold = find.byKey(
        const ValueKey<String>('settings.threshold'),
      );
      final initialValue = viewModel.state.project!.settings.thresholdDb;

      final gesture = await tester.startGesture(tester.getCenter(threshold));
      await gesture.moveBy(const Offset(48, 0));
      await tester.pump();
      final previewValue = tester.widget<Slider>(threshold).value;

      expect(previewValue, isNot(initialValue));
      expect(find.text('${previewValue.round()} dB'), findsOneWidget);
      expect(viewModel.state.project!.settings.thresholdDb, initialValue);
      expect(analysis.requests, isEmpty);
      expect(store.savedDocuments, isEmpty);

      await gesture.up();
      await tester.pump();

      expect(viewModel.state.project!.settings.thresholdDb, previewValue);
      expect(analysis.requests, hasLength(1));
      expect(analysis.requests.single.settings.thresholdDb, previewValue);
      expect(store.savedDocuments, hasLength(1));
    },
  );

  test(
    'cancelling settings analysis restores and persists the ready edit',
    () async {
      final initial = _readyStateWithManualOverride();
      final analysis = _FakeAnalysis();
      final store = _MemoryProjectStore();
      final viewModel = EditorViewModel(
        initialState: initial,
        runtime: _runtime(analysis: analysis, store: store),
      );
      addTearDown(viewModel.dispose);

      await viewModel.setThresholdDb(-18);
      await viewModel.cancelAnalysis();

      expect(analysis.cancelCount, 1);
      expect(viewModel.state.phase, EditorPhase.ready);
      expect(viewModel.state.project, initial.project);
      expect(viewModel.state.timeline, initial.timeline);
      expect(viewModel.state.message, 'Analysis cancelled.');
      expect(store.savedDocuments.last, initial.project);
    },
  );

  testWidgets('offers cancellation while re-analyzing an existing edit', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 832));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final analysis = _FakeAnalysis();
    final viewModel = EditorViewModel(
      initialState: _readyStateWithManualOverride(),
      runtime: _runtime(analysis: analysis, store: _MemoryProjectStore()),
    );
    addTearDown(viewModel.dispose);
    await viewModel.setThresholdDb(-18);

    await tester.pumpWidget(
      MaterialApp(home: EditorScreen(viewModel: viewModel)),
    );
    expect(find.text('Cancel analysis'), findsOneWidget);
    await tester.tap(find.text('Cancel analysis'));
    await tester.pump();

    expect(viewModel.state.phase, EditorPhase.ready);
    expect(analysis.cancelCount, 1);
  });

  testWidgets('explains when detection settings clear manual choices', (
    tester,
  ) async {
    await _pumpEditor(
      tester,
      _readyState().copyWith(manualOverridesCleared: true),
    );

    expect(find.text('Manual timeline choices cleared.'), findsOneWidget);
  });

  test('undo and redo manual choices without rerunning detection', () async {
    final analysis = _FakeAnalysis();
    final store = _MemoryProjectStore();
    final viewModel = EditorViewModel(
      initialState: _readyState(),
      runtime: _runtime(analysis: analysis, store: store),
    );
    addTearDown(viewModel.dispose);

    await viewModel.handleTimelineIntent(
      ToggleSegmentIntent(_segments[1].range),
    );
    expect(viewModel.canUndo, isTrue);

    await viewModel.undo();
    expect(viewModel.state.project!.manualOverrides, isEmpty);
    expect(viewModel.canRedo, isTrue);

    await viewModel.redo();
    expect(viewModel.state.project!.manualOverrides, hasLength(1));
    expect(analysis.requests, isEmpty);
  });

  test(
    'import coordinates fingerprint draft probe playback analysis autosave',
    () async {
      final source = Uri.file('/videos/new-interview.mp4');
      final analysis = _FakeAnalysis();
      final store = _MemoryProjectStore();
      final picker = _FakePicker(video: source);
      final fingerprinter = _FakeFingerprinter();
      final engine = _FakeEngine(metadata: _readyState().metadata!);
      final playback = _FakePlayback();
      final viewModel = EditorViewModel(
        initialState: const EditorState.empty(),
        runtime: _runtime(
          analysis: analysis,
          store: store,
          picker: picker,
          fingerprinter: fingerprinter,
          engine: engine,
          playback: playback,
        ),
      );
      addTearDown(viewModel.dispose);

      await viewModel.openVideo();

      expect(fingerprinter.sources, <Uri>[source]);
      expect(engine.probed, <Uri>[source]);
      expect(playback.opened, <Uri>[source]);
      expect(analysis.requests, hasLength(1));
      expect(store.savedDocuments, isNotEmpty);
      expect(viewModel.state.phase, EditorPhase.analyzing);
      expect(
        viewModel.state.projectUri,
        Uri.file('/videos/new-interview.gapless'),
      );
    },
  );

  test(
    'import probe failures restore the workspace with a proper message',
    () async {
      final store = _MemoryProjectStore();
      final viewModel = EditorViewModel(
        initialState: const EditorState.empty(),
        runtime: _runtime(
          analysis: _FakeAnalysis(),
          store: store,
          picker: _FakePicker(video: Uri.file('/videos/voice-over.m4a')),
          engine: _FailingProbeEngine(
            EngineContractFailure(
              operation: 'probe',
              reason: EngineContractReason.unsupportedSources,
            ),
          ),
        ),
      );
      addTearDown(viewModel.dispose);

      await viewModel.openVideo();

      expect(viewModel.state.phase, EditorPhase.empty);
      expect(viewModel.state.project, isNull);
      expect(store.savedDocuments, isEmpty);
      expect(
        viewModel.state.message,
        'A video file is required. Audio-only files are not supported yet. '
        'Choose a video file and try again.',
      );
      expect(viewModel.state.message, isNot(contains('EngineContractFailure')));
    },
  );

  test(
    'project load failures restore the workspace with a proper message',
    () async {
      final store = _MemoryProjectStore()
        ..loadFailure = const ProjectFormatFailure('invalid schema');
      final viewModel = EditorViewModel(
        initialState: const EditorState.empty(),
        runtime: _runtime(
          analysis: _FakeAnalysis(),
          store: store,
          picker: _FakePicker(project: Uri.file('/projects/broken.gapless')),
        ),
      );
      addTearDown(viewModel.dispose);

      await viewModel.openProject();

      expect(viewModel.state.phase, EditorPhase.empty);
      expect(viewModel.state.project, isNull);
      expect(
        viewModel.state.message,
        'Project could not be opened. This project file is invalid or '
        'unsupported. Try opening it again.',
      );
      expect(viewModel.state.message, isNot(contains('ProjectFormatFailure')));
    },
  );

  test('save as enforces gapless and retry recovers a failed save', () async {
    final analysis = _FakeAnalysis();
    final store = _MemoryProjectStore();
    final picker = _FakePicker(save: Uri.file('/projects/interview-copy'));
    final viewModel = EditorViewModel(
      initialState: _readyState(),
      runtime: _runtime(analysis: analysis, store: store, picker: picker),
    );
    addTearDown(viewModel.dispose);

    await viewModel.saveAs();
    expect(
      viewModel.state.projectUri,
      Uri.file('/projects/interview-copy.gapless'),
    );
    expect(store.savedUris.last, Uri.file('/projects/interview-copy.gapless'));

    store.fail = true;
    await viewModel.save();
    expect(viewModel.state.saveStatus, EditorSaveStatus.failed);

    store.fail = false;
    await viewModel.retrySave();
    expect(viewModel.state.saveStatus, EditorSaveStatus.saved);
  });

  test('save as migrates an active analysis to the new project URI', () async {
    final analysis = _FakeAnalysis();
    final store = _MemoryProjectStore();
    final target = Uri.file('/projects/analyzing-copy.gapless');
    final viewModel = EditorViewModel(
      initialState: _readyState(),
      runtime: _runtime(
        analysis: analysis,
        store: store,
        picker: _FakePicker(save: target),
      ),
    );
    addTearDown(viewModel.dispose);

    await viewModel.setThresholdDb(-18);
    final activeRequest = analysis.requests.single;
    await viewModel.saveAs();
    analysis.emitFor(
      activeRequest,
      AnalysisReady(_readyState().timeline!, _readyState().levels!),
    );
    await Future<void>.delayed(Duration.zero);

    expect(viewModel.state.projectUri, target);
    expect(viewModel.state.phase, EditorPhase.ready);
    expect(store.savedUris.last, target);
    expect(store.savedDocuments.last.detectedSegments, isNotEmpty);
  });

  test(
    'export emits one frozen MP4 workflow request and is not undoable',
    () async {
      final analysis = _FakeAnalysis();
      final store = _MemoryProjectStore();
      final exporter = _FakeExporter();
      final viewModel = EditorViewModel(
        initialState: _readyState(),
        runtime: _runtime(analysis: analysis, store: store, exporter: exporter),
      );
      addTearDown(viewModel.dispose);

      await viewModel.export();

      expect(exporter.requests, hasLength(1));
      expect(
        exporter.requests.single.source.path,
        '/videos/interview_take3.mp4',
      );
      expect(exporter.requests.single.timeline, same(viewModel.state.timeline));
      expect(viewModel.canUndo, isFalse);
    },
  );

  test('export boundary failures are reported without escaping', () async {
    final exporter = _FakeExporter(
      failure: UnsupportedError('The MP4 renderer is not composed yet.'),
    );
    final viewModel = EditorViewModel(
      initialState: _readyState(),
      runtime: _runtime(
        analysis: _FakeAnalysis(),
        store: _MemoryProjectStore(),
        exporter: exporter,
      ),
    );
    addTearDown(viewModel.dispose);

    await viewModel.export();

    expect(exporter.requests, hasLength(1));
    expect(viewModel.state.message, 'Something went wrong. Please try again.');
    expect(viewModel.state.message, isNot(contains('MP4 renderer')));
  });

  test('recent projects lazily prune inaccessible entries only', () async {
    final analysis = _FakeAnalysis();
    final store = _MemoryProjectStore();
    final present = Uri.file('/projects/present.gapless');
    final missing = Uri.file('/projects/missing.gapless');
    final recents = _FakeRecents(
      values: <Uri>[present, missing],
      accessible: <Uri>{present},
    );
    final viewModel = EditorViewModel(
      initialState: const EditorState.empty(),
      runtime: _runtime(analysis: analysis, store: store, recents: recents),
    );
    addTearDown(viewModel.dispose);

    await viewModel.loadRecentProjects();

    expect(viewModel.state.recentProjects, <Uri>[present]);
    expect(recents.values, <Uri>[present]);
  });

  test('no-audio import waits for explicit Use Motion recovery', () async {
    final analysis = _FakeAnalysis();
    final store = _MemoryProjectStore();
    final viewModel = EditorViewModel(
      initialState: const EditorState.empty(),
      runtime: _runtime(
        analysis: analysis,
        store: store,
        picker: _FakePicker(video: Uri.file('/videos/silent.mp4')),
        engine: _FakeEngine(metadata: _metadataWithoutAudio()),
      ),
    );
    addTearDown(viewModel.dispose);

    await viewModel.openVideo();
    expect(viewModel.state.audioUnavailable, isTrue);
    expect(analysis.requests, isEmpty);

    await viewModel.useMotion();
    expect(viewModel.state.project!.settings.method, AnalysisMethod.motion);
    expect(viewModel.state.audioUnavailable, isFalse);
    expect(analysis.requests, hasLength(1));
  });

  testWidgets('desktop shortcuts invoke save save-as undo redo and export', (
    tester,
  ) async {
    final analysis = _FakeAnalysis();
    final store = _MemoryProjectStore();
    final exporter = _FakeExporter();
    final viewModel = EditorViewModel(
      initialState: _readyState(),
      runtime: _runtime(
        analysis: analysis,
        store: store,
        picker: _FakePicker(save: Uri.file('/projects/shortcut-copy.gapless')),
        exporter: exporter,
      ),
    );
    addTearDown(viewModel.dispose);
    await viewModel.handleTimelineIntent(
      ToggleSegmentIntent(_segments[1].range),
    );
    await _pumpViewModel(tester, viewModel);

    await _sendControlShortcut(tester, LogicalKeyboardKey.keyZ);
    expect(viewModel.state.project!.manualOverrides, isEmpty);
    await _sendControlShortcut(tester, LogicalKeyboardKey.keyZ, shift: true);
    expect(viewModel.state.project!.manualOverrides, hasLength(1));

    final savesBefore = store.savedDocuments.length;
    await _sendControlShortcut(tester, LogicalKeyboardKey.keyS);
    expect(store.savedDocuments.length, savesBefore + 1);
    await _sendControlShortcut(tester, LogicalKeyboardKey.keyS, shift: true);
    expect(
      viewModel.state.projectUri,
      Uri.file('/projects/shortcut-copy.gapless'),
    );
    await _sendControlShortcut(tester, LogicalKeyboardKey.keyE);
    expect(exporter.requests, hasLength(1));
  });

  testWidgets('Space is suppressed while typing and plays otherwise', (
    tester,
  ) async {
    final analysis = _FakeAnalysis();
    final store = _MemoryProjectStore();
    final playback = _FakePlayback();
    final viewModel = EditorViewModel(
      initialState: _readyFastForwardState(),
      runtime: _runtime(analysis: analysis, store: store, playback: playback),
    );
    addTearDown(viewModel.dispose);
    await _pumpViewModel(tester, viewModel);

    await tester.tap(find.byKey(const ValueKey<String>('fastForward.speed')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(playback.playCalls, 0);

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.tap(find.text('Gapless'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(playback.playCalls, 1);
  });

  testWidgets('fast-forward speed field follows undo and redo state', (
    tester,
  ) async {
    final analysis = _FakeAnalysis();
    final viewModel = EditorViewModel(
      initialState: _readyFastForwardState(),
      runtime: _runtime(analysis: analysis, store: _MemoryProjectStore()),
    );
    addTearDown(viewModel.dispose);
    await _pumpViewModel(tester, viewModel);

    String speedText() => tester
        .widget<EditableText>(
          find.descendant(
            of: find.byKey(const ValueKey<String>('fastForward.speed')),
            matching: find.byType(EditableText),
          ),
        )
        .controller
        .text;

    expect(speedText(), '4');
    await viewModel.setFastForwardRate(8);
    await tester.pump();
    expect(speedText(), '8');

    await viewModel.undo();
    await tester.pump();
    expect(speedText(), '4');

    await viewModel.redo();
    await tester.pump();
    expect(speedText(), '8');
  });

  test(
    'open project resolves source then probes plays analyzes and remembers',
    () async {
      final analysis = _FakeAnalysis();
      final store = _MemoryProjectStore();
      final projectUri = Uri.file('/projects/recent.gapless');
      store.loaded[projectUri] = _readyState().project!;
      final playback = _FakePlayback();
      final recents = _FakeRecents();
      final resolver = _FakeSourceResolver();
      final viewModel = EditorViewModel(
        initialState: const EditorState.empty(),
        runtime: _runtime(
          analysis: analysis,
          store: store,
          picker: _FakePicker(project: projectUri),
          playback: playback,
          recents: recents,
          sourceResolver: resolver,
        ),
      );
      addTearDown(viewModel.dispose);

      await viewModel.openProject();

      expect(resolver.projects, <Uri>[projectUri]);
      expect(playback.opened.single.path, '/videos/interview_take3.mp4');
      expect(analysis.requests, hasLength(1));
      expect(recents.values, <Uri>[projectUri]);
      expect(viewModel.state.phase, EditorPhase.analyzing);
    },
  );

  test(
    'open project prepares its persisted preview mode before playback',
    () async {
      final source = Uri.file('/videos/original-preview.mp4');
      final projectUri = Uri.file('/projects/original-preview.gapless');
      final base = _projectWithSource(source, 'a');
      final project = ProjectDocument(
        schemaVersion: base.schemaVersion,
        appVersion: base.appVersion,
        source: base.source,
        settings: base.settings,
        detectedSegments: base.detectedSegments,
        manualOverrides: base.manualOverrides,
        ui: ProjectUiState(
          previewMode: PreviewMode.original,
          timelineZoom: base.ui.timelineZoom,
          sidebarWidth: base.ui.sidebarWidth,
          waveformHeight: base.ui.waveformHeight,
        ),
      );
      final store = _MemoryProjectStore()..loaded[projectUri] = project;
      final playback = _FakePlayback();
      final preparedModes = <PreviewMode>[];
      final viewModel = EditorViewModel(
        initialState: const EditorState.empty(),
        runtime: _runtime(
          analysis: _FakeAnalysis(),
          store: store,
          playback: playback,
          onSourceWillOpen: (mode) async {
            preparedModes.add(mode);
            playback.events.add('prepare-${mode.name}');
          },
        ),
      );
      addTearDown(viewModel.dispose);

      await viewModel.openProject(projectUri);

      expect(preparedModes, <PreviewMode>[PreviewMode.original]);
      expect(playback.events, <String>[
        'prepare-original',
        'open-${source.toString()}',
      ]);
    },
  );

  test(
    'relocated project persists and consistently uses the resolved source',
    () async {
      final analysis = _FakeAnalysis();
      final store = _MemoryProjectStore();
      final projectUri = Uri.file('/projects/archive/interview.gapless');
      final resolved = Uri.file('/projects/media/interview.mp4');
      final original = _readyState().project!;
      store.loaded[projectUri] = ProjectDocument(
        schemaVersion: original.schemaVersion,
        appVersion: original.appVersion,
        source: SourceReference(
          relativePath: 'missing/interview.mp4',
          absolutePath: '/missing/interview.mp4',
          fingerprint: original.source.fingerprint,
        ),
        settings: original.settings,
        detectedSegments: original.detectedSegments,
        manualOverrides: original.manualOverrides,
        ui: original.ui,
      );
      final playback = _FakePlayback();
      final exporter = _FakeExporter();
      final viewModel = EditorViewModel(
        initialState: const EditorState.empty(),
        runtime: _runtime(
          analysis: analysis,
          store: store,
          playback: playback,
          exporter: exporter,
          sourceResolver: _FakeSourceResolver(resolved: resolved),
        ),
      );
      addTearDown(viewModel.dispose);

      await viewModel.openProject(projectUri);
      await viewModel.export();

      final persistedSource = store.savedDocuments.last.source;
      expect(persistedSource.absolutePath, resolved.toFilePath());
      expect(
        persistedSource.relativePath,
        p.join('..', 'media', 'interview.mp4'),
      );
      expect(playback.opened, <Uri>[resolved]);
      expect(analysis.requests.single.source, persistedSource);
      expect(exporter.requests.single.source, resolved);
    },
  );

  test('a slow first project cannot replace a newer opened project', () async {
    final firstProject = Uri.file('/projects/first.gapless');
    final secondProject = Uri.file('/projects/second.gapless');
    final firstSource = Uri.file('/videos/first.mp4');
    final secondSource = Uri.file('/videos/second.mp4');
    final store = _MemoryProjectStore()
      ..loaded[firstProject] = _projectWithSource(firstSource, 'b')
      ..loaded[secondProject] = _projectWithSource(secondSource, 'c');
    final engine = _ControlledProbeEngine()
      ..complete(secondSource, _readyState().metadata!);
    final analysis = _FakeAnalysis();
    final playback = _FakePlayback();
    final recents = _FakeRecents();
    final viewModel = EditorViewModel(
      initialState: const EditorState.empty(),
      runtime: _runtime(
        analysis: analysis,
        store: store,
        engine: engine,
        playback: playback,
        recents: recents,
      ),
    );
    addTearDown(viewModel.dispose);

    final firstOpen = viewModel.openProject(firstProject);
    await engine.waitUntilProbed(firstSource);
    await viewModel.openProject(secondProject);
    engine.complete(firstSource, _readyState().metadata!);
    await firstOpen;

    expect(viewModel.state.projectUri, secondProject);
    expect(
      viewModel.state.project!.source.absolutePath,
      secondSource.toFilePath(),
    );
    expect(playback.opened, <Uri>[secondSource]);
    expect(
      analysis.requests.map((request) => request.source.absolutePath),
      <String>[secondSource.toFilePath()],
    );
    expect(recents.values, <Uri>[secondProject]);
  });

  test(
    'analysis updates are correlated with their requested project',
    () async {
      final firstProject = Uri.file('/projects/analysis-first.gapless');
      final secondProject = Uri.file('/projects/analysis-second.gapless');
      final firstSource = Uri.file('/videos/analysis-first.mp4');
      final secondSource = Uri.file('/videos/analysis-second.mp4');
      final store = _MemoryProjectStore()
        ..loaded[firstProject] = _projectWithSource(firstSource, 'd')
        ..loaded[secondProject] = _projectWithSource(secondSource, 'e');
      final analysis = _FakeAnalysis();
      final viewModel = EditorViewModel(
        initialState: const EditorState.empty(),
        runtime: _runtime(analysis: analysis, store: store),
      );
      addTearDown(viewModel.dispose);

      await viewModel.openProject(firstProject);
      final firstRequest = analysis.requests.single;
      await viewModel.openProject(secondProject);
      final secondRequest = analysis.requests.last;

      analysis.emitFor(
        firstRequest,
        AnalysisReady(_readyState().timeline!, _readyState().levels!),
      );
      await Future<void>.delayed(Duration.zero);
      expect(viewModel.state.projectUri, secondProject);
      expect(viewModel.state.phase, EditorPhase.analyzing);

      analysis.emitFor(
        secondRequest,
        AnalysisReady(_readyState().timeline!, _readyState().levels!),
      );
      await Future<void>.delayed(Duration.zero);
      expect(viewModel.state.projectUri, secondProject);
      expect(viewModel.state.phase, EditorPhase.ready);
    },
  );

  test(
    'cancelling Open preserves current analysis and autosave ownership',
    () async {
      final initial = _readyState();
      final analysis = _FakeAnalysis();
      final store = _MemoryProjectStore();
      final controllers = <AutosaveController>[];
      final viewModel = EditorViewModel(
        initialState: initial,
        runtime: _runtime(
          analysis: analysis,
          store: store,
          picker: _FakePicker(),
          autosaveFactory: (project) {
            final controller = AutosaveController(
              project: project,
              store: store,
              delay: Duration.zero,
            );
            controllers.add(controller);
            return controller;
          },
        ),
      );
      addTearDown(viewModel.dispose);

      await viewModel.setThresholdDb(-18);
      final activeRequest = analysis.requests.single;
      final activeAutosave = controllers.single;

      await viewModel.openVideo();
      await Future<void>.delayed(Duration.zero);
      analysis.emitFor(
        activeRequest,
        AnalysisReady(_readyState().timeline!, _readyState().levels!),
      );
      await Future<void>.delayed(Duration.zero);
      await viewModel.save();

      expect(viewModel.state.projectUri, initial.projectUri);
      expect(viewModel.state.phase, EditorPhase.ready);
      expect(activeAutosave.status, isNot(isA<AutosaveDisposed>()));
      expect(controllers, hasLength(1));
      expect(store.savedUris.last, initial.projectUri);
    },
  );

  test('a stale picker result cannot replace a newer selection', () async {
    final firstSource = Uri.file('/videos/first-picked.mp4');
    final secondSource = Uri.file('/videos/second-picked.mp4');
    final picker = _ControlledPicker();
    final fingerprinter = _FakeFingerprinter();
    final engine = _FakeEngine();
    final playback = _FakePlayback();
    final analysis = _FakeAnalysis();
    final viewModel = EditorViewModel(
      initialState: const EditorState.empty(),
      runtime: _runtime(
        analysis: analysis,
        store: _MemoryProjectStore(),
        picker: picker,
        fingerprinter: fingerprinter,
        engine: engine,
        playback: playback,
      ),
    );
    addTearDown(viewModel.dispose);

    final firstOpen = viewModel.openVideo();
    final secondOpen = viewModel.openVideo();
    picker.videoSelections[1].complete(secondSource);
    await secondOpen;
    picker.videoSelections[0].complete(firstSource);
    await firstOpen;

    expect(fingerprinter.sources, <Uri>[secondSource]);
    expect(engine.probed, <Uri>[secondSource]);
    expect(playback.opened, <Uri>[secondSource]);
    expect(
      analysis.requests.single.source.absolutePath,
      secondSource.toFilePath(),
    );
  });

  test('project switches flush and dispose the previous autosave', () async {
    final initial = _readyState();
    final nextProject = Uri.file('/projects/autosave-next.gapless');
    final nextSource = Uri.file('/videos/autosave-next.mp4');
    final store = _MemoryProjectStore()
      ..loaded[nextProject] = _projectWithSource(nextSource, 'f');
    final controllers = <AutosaveController>[];
    final viewModel = EditorViewModel(
      initialState: initial,
      runtime: _runtime(
        analysis: _FakeAnalysis(),
        store: store,
        autosaveFactory: (project) {
          final controller = AutosaveController(
            project: project,
            store: store,
            delay: const Duration(days: 1),
          );
          controllers.add(controller);
          return controller;
        },
      ),
    );
    addTearDown(viewModel.dispose);
    controllers.single.markChanged(initial.project!);

    await viewModel.openProject(nextProject);

    expect(controllers.first.status, isA<AutosaveDisposed>());
    expect(store.savedUris, contains(initial.projectUri));
    expect(viewModel.state.projectUri, nextProject);
    expect(controllers.last.project, nextProject);
  });

  test('recent project preferences use versioned JSON', () async {
    final directory = await Directory.systemTemp.createTemp('gapless-recents-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/recent-projects.json');
    final store = JsonRecentProjectsStore(file);
    final projects = <Uri>[
      Uri.file('/projects/one.gapless'),
      Uri.file('/projects/two.gapless'),
    ];

    await store.save(projects);

    expect(await store.load(), projects);
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect(json['schemaVersion'], 1);
    expect(json['projects'], projects.map((uri) => uri.toString()).toList());
  });

  test(
    'import with the real recent store reaches analysis and remembers the draft',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'gapless-real-recents-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final recents = JsonRecentProjectsStore(
        File('${directory.path}/recent-projects.json'),
      );
      final existing = Uri.file('${directory.path}/existing.gapless');
      await File.fromUri(existing).create();
      await recents.save(<Uri>[existing]);
      final analysis = _FakeAnalysis();
      final source = Uri.file('/videos/real-recents.mp4');
      final viewModel = EditorViewModel(
        initialState: const EditorState.empty(),
        runtime: _runtime(
          analysis: analysis,
          store: _MemoryProjectStore(),
          picker: _FakePicker(video: source),
          recents: recents,
        ),
      );
      addTearDown(viewModel.dispose);

      await viewModel.openVideo();

      expect(analysis.requests, hasLength(1));
      expect(await recents.load(), <Uri>[
        Uri.file('/videos/real-recents.gapless'),
        existing,
      ]);
    },
  );

  testWidgets('matches approved dark studio at 1280x832', (tester) async {
    await _pumpGolden(tester, Brightness.dark);

    await expectLater(
      find.byType(EditorScreen),
      matchesGoldenFile('../../../goldens/editor_dark_1280x832.png'),
    );
  }, skip: !Platform.isMacOS);

  testWidgets('matches approved light studio at 1280x832', (tester) async {
    await _pumpGolden(tester, Brightness.light);

    await expectLater(
      find.byType(EditorScreen),
      matchesGoldenFile('../../../goldens/editor_light_1280x832.png'),
    );
  }, skip: !Platform.isMacOS);
}

Future<void> _pumpEditor(WidgetTester tester, EditorState state) async {
  tester.view.physicalSize = const Size(1280, 832);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final viewModel = EditorViewModel.preview(initialState: state);
  addTearDown(viewModel.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: EditorScreen(viewModel: viewModel),
    ),
  );
}

Future<void> _pumpViewModel(
  WidgetTester tester,
  EditorViewModel viewModel,
) async {
  tester.view.physicalSize = const Size(1280, 832);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: EditorScreen(viewModel: viewModel),
    ),
  );
}

Future<void> _pumpGolden(WidgetTester tester, Brightness brightness) async {
  tester.view.physicalSize = const Size(1280, 832);
  tester.view.devicePixelRatio = 1;
  tester.binding.platformDispatcher.platformBrightnessTestValue = brightness;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(
    tester.binding.platformDispatcher.clearPlatformBrightnessTestValue,
  );
  await tester.pumpWidget(
    GaplessApp(
      dependencies: AppDependencies(
        editorViewModelFactory: () =>
            EditorViewModel.preview(initialState: _readyState()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _sendControlShortcut(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool shift = false,
}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

EditorState _readyState() {
  final document = ProjectDocument(
    schemaVersion: ProjectDocument.currentSchemaVersion,
    appVersion: '1.0.0',
    source: SourceReference(
      relativePath: 'interview_take3.mp4',
      absolutePath: '/videos/interview_take3.mp4',
      fingerprint: SourceFingerprint(
        size: 1024,
        modifiedAtUtc: DateTime.utc(2026, 7, 11),
        sampledSha256: 'a' * 64,
      ),
    ),
    settings: const AnalysisSettings(
      method: AnalysisMethod.audio,
      thresholdDb: -19,
      marginBeforeUs: 200000,
      marginAfterUs: 200000,
      inactiveBehavior: InactiveBehavior.cut,
    ),
    detectedSegments: _segments,
    manualOverrides: const [],
    ui: const ProjectUiState(
      previewMode: PreviewMode.edited,
      timelineZoom: 1,
      sidebarWidth: 264,
      waveformHeight: 52,
    ),
  );
  final timeline = EffectiveTimeline.compose(
    durationUs: _durationUs,
    detected: _segments,
    overrides: const [],
  );
  return EditorState.ready(
    project: document,
    projectUri: Uri.file('/projects/interview_take3.gapless'),
    metadata: MediaMetadata(
      durationUs: _durationUs,
      timebaseNumerator: 1001,
      timebaseDenominator: 30000,
      resolution: SizeInt(1920, 1080),
      videoCodec: 'h264',
      hasAudio: true,
      sampleRate: 48000,
      audioLayout: 'stereo',
    ),
    levels: AnalysisLevels(
      samples: List<int>.generate(494, (index) => 9000 + index % 13 * 3500),
      samplePeriodUs: 1000000,
    ),
    timeline: timeline,
    sourcePositionUs: 74000000,
    isPlaying: false,
    saveStatus: EditorSaveStatus.saved,
  );
}

ProjectDocument _projectWithSource(Uri source, String fingerprintCharacter) {
  final project = _readyState().project!;
  return ProjectDocument(
    schemaVersion: project.schemaVersion,
    appVersion: project.appVersion,
    source: SourceReference(
      relativePath: source.pathSegments.last,
      absolutePath: source.toFilePath(),
      fingerprint: SourceFingerprint(
        size: project.source.fingerprint.size,
        modifiedAtUtc: project.source.fingerprint.modifiedAtUtc,
        sampledSha256: fingerprintCharacter * 64,
      ),
    ),
    settings: project.settings,
    detectedSegments: project.detectedSegments,
    manualOverrides: project.manualOverrides,
    ui: project.ui,
  );
}

EditorState _readyStateWithManualOverride() {
  final state = _readyState();
  final manual = TimelineSegment(
    range: _segments[1].range,
    action: SegmentAction.keep,
    origin: SegmentOrigin.manual,
  );
  final project = ProjectDocument(
    schemaVersion: state.project!.schemaVersion,
    appVersion: state.project!.appVersion,
    source: state.project!.source,
    settings: state.project!.settings,
    detectedSegments: state.project!.detectedSegments,
    manualOverrides: <TimelineSegment>[manual],
    ui: state.project!.ui,
  );
  return state.copyWith(
    project: project,
    timeline: EffectiveTimeline.compose(
      durationUs: _durationUs,
      detected: _segments,
      overrides: <TimelineSegment>[manual],
    ),
  );
}

EditorState _readyFastForwardState() {
  final state = _readyState();
  final settings = AnalysisSettings(
    method: state.project!.settings.method,
    thresholdDb: state.project!.settings.thresholdDb,
    marginBeforeUs: state.project!.settings.marginBeforeUs,
    marginAfterUs: state.project!.settings.marginAfterUs,
    inactiveBehavior: InactiveBehavior.fastForward,
  );
  final project = ProjectDocument(
    schemaVersion: state.project!.schemaVersion,
    appVersion: state.project!.appVersion,
    source: state.project!.source,
    settings: settings,
    detectedSegments: state.project!.detectedSegments,
    manualOverrides: const <TimelineSegment>[],
    ui: state.project!.ui,
  );
  return state.copyWith(project: project);
}

MediaMetadata _metadataWithoutAudio() => MediaMetadata(
  durationUs: _durationUs,
  timebaseNumerator: 1001,
  timebaseDenominator: 30000,
  resolution: SizeInt(1920, 1080),
  videoCodec: 'h264',
  hasAudio: false,
  sampleRate: 0,
  audioLayout: '',
);

const _durationUs = 494000000;

final _segments = <TimelineSegment>[
  TimelineSegment(
    range: SourceTimeRange(0, 86000000),
    action: SegmentAction.keep,
    origin: SegmentOrigin.detected,
  ),
  TimelineSegment(
    range: SourceTimeRange(86000000, 119000000),
    action: SegmentAction.cut,
    origin: SegmentOrigin.detected,
  ),
  TimelineSegment(
    range: SourceTimeRange(119000000, 273000000),
    action: SegmentAction.keep,
    origin: SegmentOrigin.detected,
  ),
  TimelineSegment(
    range: SourceTimeRange(273000000, 328000000),
    action: SegmentAction.cut,
    origin: SegmentOrigin.detected,
  ),
  TimelineSegment(
    range: SourceTimeRange(328000000, 494000000),
    action: SegmentAction.keep,
    origin: SegmentOrigin.detected,
  ),
];

EditorRuntime _runtime({
  required _FakeAnalysis analysis,
  required _MemoryProjectStore store,
  EditorFilePicker? picker,
  _FakeFingerprinter? fingerprinter,
  EnginePort? engine,
  _FakePlayback? playback,
  _FakeExporter? exporter,
  RecentProjectsPort? recents,
  _FakeSourceResolver? sourceResolver,
  TimelineChanged? onTimelineChanged,
  SourceWillOpen? onSourceWillOpen,
  AutosaveFactory? autosaveFactory,
}) => EditorRuntime(
  picker: picker ?? _FakePicker(),
  fingerprinter: fingerprinter ?? _FakeFingerprinter(),
  engine: engine ?? _FakeEngine(),
  analysis: analysis,
  playback: playback ?? _FakePlayback(),
  projects: store,
  recents: recents ?? _FakeRecents(),
  sourceResolver: sourceResolver ?? _FakeSourceResolver(),
  exporter: exporter ?? _FakeExporter(),
  draftProjectFor: (source) => Uri.file(
    '${source.toFilePath().replaceFirst(RegExp(r'\.[^.]+$'), '')}.gapless',
  ),
  autosaveFactory:
      autosaveFactory ??
      (project) => AutosaveController(
        project: project,
        store: store,
        delay: Duration.zero,
      ),
  onTimelineChanged: onTimelineChanged,
  onSourceWillOpen: onSourceWillOpen,
);

final class _FakeAnalysis implements EditorAnalysisPort {
  final requests = <ProjectDocument>[];
  final _requestIds = <ProjectDocument, int>{};
  final _updates = StreamController<EditorAnalysisUpdate>.broadcast(sync: true);
  var cancelCount = 0;

  @override
  AnalysisState get state => const AnalysisIdle();

  @override
  Stream<EditorAnalysisUpdate> get updates => _updates.stream;

  @override
  void request(ProjectDocument document, {required int requestId}) {
    requests.add(document);
    _requestIds[document] = requestId;
  }

  @override
  void invalidate() {}

  @override
  Future<void> cancel() async {
    cancelCount += 1;
  }

  void emitFor(ProjectDocument document, AnalysisState state) {
    _updates.add(
      EditorAnalysisUpdate(requestId: _requestIds[document]!, state: state),
    );
  }

  @override
  Future<void> dispose() => _updates.close();
}

final class _MemoryProjectStore implements ProjectStore {
  final savedDocuments = <ProjectDocument>[];
  final savedUris = <Uri>[];
  final loaded = <Uri, ProjectDocument>{};
  var fail = false;
  Object? loadFailure;

  @override
  Future<ProjectDocument> load(Uri project) async {
    if (loadFailure case final failure?) throw failure;
    return loaded[project]!;
  }

  @override
  Future<RecoveryCandidate?> recoveryFor(Uri project) async => null;

  @override
  Future<void> saveAtomic(Uri project, ProjectDocument document) async {
    if (fail) throw StateError('disk full');
    savedUris.add(project);
    savedDocuments.add(document);
  }
}

final class _FakePicker implements EditorFilePicker {
  _FakePicker({this.video, this.project, this.save});

  final Uri? video;
  final Uri? project;
  final Uri? save;

  @override
  Future<Uri?> pickProject() async => project;

  @override
  Future<Uri?> pickVideo() async => video;

  @override
  Future<Uri?> saveProject({required String suggestedName}) async => save;
}

final class _ControlledPicker implements EditorFilePicker {
  final videoSelections = <Completer<Uri?>>[];

  @override
  Future<Uri?> pickProject() async => null;

  @override
  Future<Uri?> pickVideo() {
    final selection = Completer<Uri?>();
    videoSelections.add(selection);
    return selection.future;
  }

  @override
  Future<Uri?> saveProject({required String suggestedName}) async => null;
}

final class _FakeFingerprinter implements SourceFingerprinter {
  final sources = <Uri>[];

  @override
  Future<SourceFingerprint> fingerprint(Uri source) async {
    sources.add(source);
    return _readyState().project!.source.fingerprint;
  }
}

final class _FakeEngine implements EnginePort {
  _FakeEngine({this.metadata});

  final MediaMetadata? metadata;
  final probed = <Uri>[];

  @override
  EngineTask<DetectedTimeline> detect(Uri source, AnalysisSettings settings) =>
      throw UnimplementedError();

  @override
  EngineTask<AnalysisLevels> levels(Uri source, AnalysisMethod method) =>
      throw UnimplementedError();

  @override
  EngineTask<MediaMetadata> probe(Uri source) {
    probed.add(source);
    return _ImmediateEngineTask<MediaMetadata>(
      metadata ?? _readyState().metadata!,
    );
  }

  @override
  EngineTask<Uri> render(RenderRequest request) => throw UnimplementedError();
}

final class _ControlledProbeEngine implements EnginePort {
  final _probes = <Uri, Completer<MediaMetadata>>{};
  final _started = <Uri, Completer<void>>{};

  Future<void> waitUntilProbed(Uri source) =>
      (_started[source] ??= Completer<void>()).future;

  void complete(Uri source, MediaMetadata metadata) =>
      (_probes[source] ??= Completer<MediaMetadata>()).complete(metadata);

  @override
  EngineTask<MediaMetadata> probe(Uri source) {
    final started = _started[source] ??= Completer<void>();
    if (!started.isCompleted) started.complete();
    return _FutureEngineTask<MediaMetadata>(
      (_probes[source] ??= Completer<MediaMetadata>()).future,
    );
  }

  @override
  EngineTask<DetectedTimeline> detect(Uri source, AnalysisSettings settings) =>
      throw UnimplementedError();

  @override
  EngineTask<AnalysisLevels> levels(Uri source, AnalysisMethod method) =>
      throw UnimplementedError();

  @override
  EngineTask<Uri> render(RenderRequest request) => throw UnimplementedError();
}

final class _FailingProbeEngine implements EnginePort {
  _FailingProbeEngine([Object? failure])
    : failure = failure ?? StateError('probe failed');

  final Object failure;

  @override
  EngineTask<MediaMetadata> probe(Uri source) =>
      _FutureEngineTask<MediaMetadata>(Future<MediaMetadata>.error(failure));

  @override
  EngineTask<DetectedTimeline> detect(Uri source, AnalysisSettings settings) =>
      throw UnimplementedError();

  @override
  EngineTask<AnalysisLevels> levels(Uri source, AnalysisMethod method) =>
      throw UnimplementedError();

  @override
  EngineTask<Uri> render(RenderRequest request) => throw UnimplementedError();
}

final class _FakePlayback implements PlaybackPort {
  final opened = <Uri>[];
  final events = <String>[];
  var playCalls = 0;

  @override
  Stream<bool> get playing => const Stream<bool>.empty();

  @override
  Stream<int> get positionUs => const Stream<int>.empty();

  @override
  Future<void> dispose() async {}

  @override
  Future<void> open(Uri source) async {
    opened.add(source);
    events.add('open-${source.toString()}');
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> play() async => playCalls += 1;

  @override
  Future<void> seek(int sourceUs) async {}

  @override
  Future<void> setRate(double rate) async {}
}

final class _ImmediateEngineTask<T> implements EngineTask<T> {
  _ImmediateEngineTask(this.value);

  final T value;

  @override
  Future<void> cancel() async {}

  @override
  Stream<EngineProgress> get progress => const Stream<EngineProgress>.empty();

  @override
  Future<T> get result async => value;
}

final class _FutureEngineTask<T> implements EngineTask<T> {
  _FutureEngineTask(this.result);

  @override
  final Future<T> result;

  @override
  Future<void> cancel() async {}

  @override
  Stream<EngineProgress> get progress => const Stream<EngineProgress>.empty();
}

final class _FakeRecents implements RecentProjectsPort {
  _FakeRecents({List<Uri>? values, Set<Uri>? accessible})
    : values = values ?? <Uri>[],
      accessible = accessible ?? <Uri>{};

  List<Uri> values;
  final Set<Uri> accessible;

  @override
  Future<List<Uri>> load() async => List<Uri>.of(values);

  @override
  Future<void> save(List<Uri> projects) async =>
      values = List<Uri>.of(projects);

  @override
  Future<bool> exists(Uri project) async =>
      accessible.isEmpty || accessible.contains(project);
}

final class _FakeSourceResolver implements EditorSourceResolver {
  _FakeSourceResolver({this.resolved});

  final Uri? resolved;
  final projects = <Uri>[];

  @override
  Future<Uri?> resolve(Uri project, SourceReference source) async {
    projects.add(project);
    return resolved ?? Uri.file(source.absolutePath);
  }
}

final class _FakeExporter implements EditorExportPort {
  _FakeExporter({this.failure});

  final Object? failure;
  final requests = <EditorExportRequest>[];

  @override
  Future<void> request(EditorExportRequest request) async {
    requests.add(request);
    if (failure case final failure?) throw failure;
  }
}
