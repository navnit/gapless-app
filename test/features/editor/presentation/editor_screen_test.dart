import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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

void main() {
  setUpAll(() async {
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
    expect(find.text('THRESHOLD'), findsNothing);
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

  testWidgets('matches approved dark studio at 1280x832', (tester) async {
    await _pumpGolden(tester, Brightness.dark);

    await expectLater(
      find.byType(EditorScreen),
      matchesGoldenFile('../../../goldens/editor_dark_1280x832.png'),
    );
  });

  testWidgets('matches approved light studio at 1280x832', (tester) async {
    await _pumpGolden(tester, Brightness.light);

    await expectLater(
      find.byType(EditorScreen),
      matchesGoldenFile('../../../goldens/editor_light_1280x832.png'),
    );
  });
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
  _FakePicker? picker,
  _FakeFingerprinter? fingerprinter,
  _FakeEngine? engine,
  _FakePlayback? playback,
  _FakeExporter? exporter,
  _FakeRecents? recents,
  _FakeSourceResolver? sourceResolver,
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
  autosaveFactory: (project) =>
      AutosaveController(project: project, store: store, delay: Duration.zero),
);

final class _FakeAnalysis implements EditorAnalysisPort {
  final requests = <ProjectDocument>[];

  @override
  AnalysisState get state => const AnalysisIdle();

  @override
  Stream<AnalysisState> get states => const Stream<AnalysisState>.empty();

  @override
  void request(ProjectDocument document) => requests.add(document);

  @override
  Future<void> dispose() async {}
}

final class _MemoryProjectStore implements ProjectStore {
  final savedDocuments = <ProjectDocument>[];
  final savedUris = <Uri>[];
  final loaded = <Uri, ProjectDocument>{};
  var fail = false;

  @override
  Future<ProjectDocument> load(Uri project) async => loaded[project]!;

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

final class _FakePlayback implements PlaybackPort {
  final opened = <Uri>[];
  var playCalls = 0;

  @override
  Stream<bool> get playing => const Stream<bool>.empty();

  @override
  Stream<int> get positionUs => const Stream<int>.empty();

  @override
  Future<void> dispose() async {}

  @override
  Future<void> open(Uri source) async => opened.add(source);

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
  final projects = <Uri>[];

  @override
  Future<Uri?> resolve(Uri project, SourceReference source) async {
    projects.add(project);
    return Uri.file(source.absolutePath);
  }
}

final class _FakeExporter implements EditorExportPort {
  final requests = <EditorExportRequest>[];

  @override
  Future<void> request(EditorExportRequest request) async =>
      requests.add(request);
}
