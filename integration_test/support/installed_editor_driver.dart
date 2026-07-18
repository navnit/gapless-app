import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/app/app_dependencies.dart';
import 'package:gapless/app/gapless_app.dart';
import 'package:gapless/core/errors/app_failure.dart';
import 'package:gapless/core/process/io_process_runner.dart';
import 'package:gapless/features/editor/domain/analysis_settings.dart';
import 'package:gapless/features/editor/domain/timeline_segment.dart';
import 'package:gapless/features/editor/presentation/editor_view_model.dart';
import 'package:gapless/features/editor/presentation/timeline_view_model.dart';
import 'package:gapless/features/engine/data/auto_editor/auto_editor_adapter.dart';
import 'package:gapless/features/engine/data/auto_editor/auto_editor_locator.dart';
import 'package:gapless/features/engine/domain/engine_models.dart';
import 'package:gapless/features/engine/domain/engine_port.dart';
import 'package:gapless/features/export/application/export_coordinator.dart';
import 'package:gapless/features/playback/domain/playback_port.dart';
import 'package:path/path.dart' as path;

import '../../tool/testing/generate_fixture_video.dart';

final class InstalledMediaProbe {
  const InstalledMediaProbe({
    required this.hasVideo,
    required this.hasAudio,
    required this.durationUs,
    required this.frameDurationUs,
  });

  final bool hasVideo;
  final bool hasAudio;
  final int durationUs;
  final int frameDurationUs;
}

/// Drives the real Flutter desktop composition with the pinned Auto-Editor.
///
/// Native file dialogs and media playback are replaced with deterministic
/// ports, while probe, levels, detection, project persistence, restart/reopen,
/// export, process ownership, and output probing remain production code.
final class InstalledEditorDriver {
  InstalledEditorDriver(this.tester);

  final WidgetTester tester;
  late final Directory _workspace;
  late final Uri _source;
  late final Uri _project;
  late final Uri _output;
  late final AutoEditorAdapter _engine;
  late final _ControllableRenderEngine _renderEngine;
  EditorViewModel? _editor;
  _FixedDestinationExporter? _exporter;
  _ScriptedPicker? _picker;
  var _launched = false;
  var _disposed = false;
  var _temporarySequence = 0;

  Future<void> launch() async {
    debugPrint('E2E: launch:start');
    _workspace = await Directory.systemTemp.createTemp('gapless-native-e2e-');
    _source = Uri.file(path.join(_workspace.path, 'source.avi'));
    _project = Uri.file(path.join(_workspace.path, 'saved.gapless'));
    _output = Uri.file(path.join(_workspace.path, 'edited.mp4'));
    await generateFixtureVideo(File.fromUri(_source));
    debugPrint('E2E: fixture:ready');

    final runner = IoProcessRunner();
    final engineRoot = _bundledEngineRoot();
    _engine = AutoEditorAdapter(
      processRunner: runner,
      executableLocator: AutoEditorLocator(
        manifestPath: path.join(engineRoot, 'manifest.json'),
        installRoot: engineRoot,
        processRunner: runner,
      ),
      temporaryPathFactory: _temporaryPath,
    );
    _renderEngine = _ControllableRenderEngine(_engine);
    try {
      await _engine.probe(_source).result;
      debugPrint('E2E: engine:probe-ready');
    } on EngineContractFailure catch (failure) {
      throw StateError(
        'Engine preflight failed: operation=${failure.operation} '
        'reason=${failure.reason} exit=${failure.exitCode} '
        'diagnostics=${failure.diagnostics}',
      );
    }
    await _mountEditor(video: _source);
    _launched = true;
    debugPrint('E2E: launch:ready');
  }

  Future<void> openVideo() async {
    _requireLaunched();
    debugPrint('E2E: open-video:tap');
    await tester.tap(find.text('Open Video'));
    await tester.pump();
    debugPrint('E2E: open-video:requested');
  }

  Future<void> waitForAnalysisReady() => _waitFor(() {
    final state = _requireEditor().state;
    return state.phase == EditorPhase.ready &&
        state.timeline != null &&
        state.levels != null;
  }, 'analysis to reach the ready state');

  Future<int> toggleFirstCut() async {
    final editor = _requireEditor();
    final cut = editor.state.timeline!.segments.firstWhere(
      (segment) => segment.action == SegmentAction.cut,
    );
    await editor.handleTimelineIntent(ToggleSegmentIntent(cut.range));
    await tester.pump();
    return editor.state.timeline!.editedDurationUs;
  }

  Future<void> waitForAutosave() => _waitFor(
    () => _requireEditor().state.saveStatus == EditorSaveStatus.saved,
    'autosave to finish',
  );

  Future<void> saveAs() async {
    debugPrint('E2E: save-as:start');
    await _requireEditor().saveAs();
    debugPrint('E2E: save-as:editor-complete');
    await tester.pump();
    expect(await File.fromUri(_project).exists(), isTrue);
    debugPrint('E2E: save-as:ready');
  }

  Future<void> restartAndReopen() async {
    debugPrint('E2E: restart:start');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    _editor = null;
    await _mountEditor(project: _project);
    debugPrint('E2E: restart:mounted');
    await _requireEditor().openProject(_project);
    debugPrint('E2E: restart:open-request-complete');
    await waitForAnalysisReady();
    debugPrint('E2E: restart:ready');
  }

  Future<int> createSavedProject() async {
    await openVideo();
    await waitForAnalysisReady();
    final duration = await toggleFirstCut();
    await waitForAutosave();
    await saveAs();
    return duration;
  }

  Uri get source => _source;
  Uri get relocatedSource =>
      Uri.file(path.join(_workspace.path, 'relocated-source.avi'));

  Future<void> makeSourceMissing() async {
    await File.fromUri(_source).copy(relocatedSource.toFilePath());
    await File.fromUri(_source).delete();
  }

  Future<InstalledSourceIssue> restartForSourceIssue() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    _editor = null;
    await _mountEditor(project: _project);
    await _requireEditor().openProject(_project);
    for (var attempt = 0; attempt < 100; attempt++) {
      final state = _requireEditor().state;
      if (state.phase == EditorPhase.ready && state.metadata == null) {
        final absolute = File(state.project!.source.absolutePath);
        return await absolute.exists()
            ? InstalledSourceIssue.changed
            : InstalledSourceIssue.missing;
      }
      await tester.pump(const Duration(milliseconds: 50));
    }
    throw TimeoutException('Timed out waiting for a source recovery issue.');
  }

  Future<void> relocateSource(Uri source) async {
    _picker!.video = source;
    await _requireEditor().relocateSource();
    await waitForAnalysisReady();
  }

  Future<void> changeRelocatedSourceAndRestoreOriginal() async {
    await File.fromUri(relocatedSource).writeAsBytes(<int>[1, 2, 3, 4]);
    await generateFixtureVideo(File.fromUri(_source));
  }

  int get effectiveDurationUs =>
      _requireEditor().state.timeline!.editedDurationUs;

  Future<void> cancelAnalysisPreservingTimeline() async {
    final editor = _requireEditor();
    final before = editor.state;
    final change = editor.setThresholdDb(-18);
    await tester.pump();
    await editor.cancelAnalysis();
    await change;
    await tester.pump();

    expect(editor.state.phase, EditorPhase.ready);
    expect(editor.state.project!.settings, before.project!.settings);
    expect(
      editor.state.project!.manualOverrides,
      before.project!.manualOverrides,
    );
    expect(editor.state.timeline, before.timeline);
    await waitForAutosave();
  }

  Future<void> cancelExportPreservingDestination() async {
    const original = <int>[71, 65, 80, 76, 69, 83, 83];
    await File.fromUri(_output).writeAsBytes(original, flush: true);
    _renderEngine.holdNextRender();

    final export = _requireEditor().export();
    await _renderEngine.waitUntilHeldRenderStarts();
    await _exporter!.cancelActive();
    await export;
    await tester.pump();

    expect(await File.fromUri(_output).readAsBytes(), original);
    final residue = await _workspace
        .list()
        .where(
          (entry) =>
              path.basename(entry.path).startsWith('.edited.gapless-') ||
              path.basename(entry.path).startsWith('edited.edited.backup-'),
        )
        .toList();
    expect(residue, isEmpty);
    await File.fromUri(_output).delete();
  }

  Future<AppFailure?> failExportToUnavailableDestination() async {
    final unavailable = Directory(
      path.join(_workspace.path, 'unavailable.mp4'),
    );
    await unavailable.create();
    _exporter!.destination = unavailable.uri;
    await _requireEditor().export();
    await tester.pump();
    return _exporter!.failure;
  }

  void restoreExportDestination() {
    _exporter!
      ..destination = _output
      ..failure = null;
  }

  Future<void> exportMp4() async {
    debugPrint('E2E: export:start');
    await _requireEditor().export();
    debugPrint('E2E: export:request-complete');
    await tester.pump();
    if (!await File.fromUri(_output).exists()) {
      final failure = _exporter?.failure;
      if (failure is EngineContractFailure) {
        throw StateError(
          'Export failed: operation=${failure.operation} '
          'reason=${failure.reason} exit=${failure.exitCode} '
          'diagnostics=${failure.diagnostics}',
        );
      }
      throw StateError(
        'Export did not create output: failure=$failure '
        'message=${_editor?.state.message}',
      );
    }
    debugPrint('E2E: export:ready');
  }

  Future<InstalledMediaProbe> probeOutput() async {
    final metadata = await _engine.probe(_output).result;
    return InstalledMediaProbe(
      hasVideo: metadata.resolution.width > 0 && metadata.resolution.height > 0,
      hasAudio: metadata.hasAudio,
      durationUs: metadata.durationUs,
      frameDurationUs:
          (metadata.timebaseNumerator *
                  Duration.microsecondsPerSecond /
                  metadata.timebaseDenominator)
              .round(),
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (_launched) {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      if (await _workspace.exists()) {
        try {
          await _workspace.delete(recursive: true);
        } on FileSystemException {
          // The macOS test runner can remove its container temp directory
          // concurrently while the integration binding tears the app down.
        }
      }
    }
  }

  Future<void> _mountEditor({Uri? video, Uri? project}) async {
    debugPrint('E2E: mount:start');
    final picker = _ScriptedPicker(
      video: video,
      project: project,
      save: _project,
    );
    _picker = picker;
    final directories = Directory(path.join(_workspace.path, 'runtime'));
    final exporter = _FixedDestinationExporter(
      engine: _renderEngine,
      destination: _output,
    );
    _exporter = exporter;
    final dependencies = await AppDependencies.production(
      loadDirectories: () async => AppDirectories(
        applicationSupport: Directory(
          path.join(directories.path, 'application-support'),
        ),
        cache: Directory(path.join(directories.path, 'cache')),
        temporary: Directory(path.join(directories.path, 'temporary')),
        flutterAssets: Directory(path.join(directories.path, 'flutter-assets')),
      ),
      engine: _engine,
      playbackFactory: () => AppPlayback(playback: _TestPlayback()),
      picker: picker,
      exporter: exporter,
    );
    debugPrint('E2E: mount:dependencies-ready');
    final editor = dependencies.createEditorViewModel();
    _editor = editor;
    await tester.pumpWidget(
      GaplessApp(
        dependencies: AppDependencies(editorViewModelFactory: () => editor),
      ),
    );
    await tester.pump();
    debugPrint('E2E: mount:ready');
  }

  String _bundledEngineRoot() {
    return nativeAutoEditorInstallRoot(
      resolvedExecutable: Platform.resolvedExecutable,
    );
  }

  Future<Uri> _temporaryPath(String extension) async {
    final directory = Directory(path.join(_workspace.path, 'engine-temporary'));
    await directory.create(recursive: true);
    return Uri.file(
      path.join(directory.path, 'operation-${_temporarySequence++}$extension'),
    );
  }

  Future<void> _waitFor(bool Function() condition, String description) async {
    debugPrint('E2E: wait:start:$description');
    for (var attempt = 0; attempt < 900; attempt++) {
      if (condition()) {
        debugPrint('E2E: wait:ready:$description');
        return;
      }
      await tester.pump(const Duration(milliseconds: 100));
      if (attempt % 50 == 0) {
        final state = _editor?.state;
        debugPrint(
          'E2E: wait:$description attempt=$attempt '
          'phase=${state?.phase} message=${state?.message}',
        );
      }
      final message = _editor?.state.message;
      final state = _editor?.state;
      if (state?.phase == EditorPhase.ready &&
          state?.levels == null &&
          message != null) {
        throw StateError('$description failed: $message');
      }
      if (message != null &&
          (message.contains('failed') || message.contains('could not'))) {
        throw StateError('$description failed: $message');
      }
    }
    throw TimeoutException('Timed out waiting for $description.');
  }

  EditorViewModel _requireEditor() =>
      _editor ?? (throw StateError('The editor is not mounted.'));

  void _requireLaunched() {
    if (!_launched) throw StateError('Call launch before driving the app.');
  }
}

enum InstalledSourceIssue { missing, changed }

final class _ScriptedPicker implements EditorFilePicker {
  _ScriptedPicker({this.video, this.project, required this.save});

  Uri? video;
  final Uri? project;
  final Uri save;

  @override
  Future<Uri?> pickProject() async => project;

  @override
  Future<Uri?> pickVideo() async => video;

  @override
  Future<Uri?> saveProject({required String suggestedName}) async => save;
}

final class _FixedDestinationExporter implements EditorExportPort {
  _FixedDestinationExporter({required this.engine, required this.destination});

  final EnginePort engine;
  Uri destination;
  AppFailure? failure;
  ExportCoordinator? _active;
  var _cancelRequested = false;

  Future<void> cancelActive() async {
    _cancelRequested = true;
    await _active?.cancel();
  }

  @override
  Future<void> request(EditorExportRequest request) async {
    final coordinator = ExportCoordinator(engine: engine);
    _active = coordinator;
    _cancelRequested = false;
    try {
      await coordinator.start(
        ExportRequest(
          source: request.source,
          metadata: request.metadata,
          timeline: request.timeline,
          destination: destination,
          preset: RenderPreset.balanced,
        ),
      );
      switch (coordinator.state) {
        case ExportComplete():
          return;
        case ExportFailed(:final failure):
          this.failure = failure;
          throw failure;
        case ExportChoosing() when _cancelRequested:
          return;
        case ExportChoosing() || ExportRunning():
          throw EngineContractFailure(
            operation: 'integration-export',
            reason: EngineContractReason.invalidOutput,
            diagnostics: <String>['Export did not reach a terminal state.'],
          );
      }
    } finally {
      if (identical(_active, coordinator)) _active = null;
      await coordinator.dispose();
    }
  }
}

final class _ControllableRenderEngine implements EnginePort {
  _ControllableRenderEngine(this.delegate);

  final EnginePort delegate;
  Completer<void>? _heldRenderStarted;
  Completer<void>? _releaseHeldRender;

  void holdNextRender() {
    if (_heldRenderStarted != null) {
      throw StateError('A held render is already pending.');
    }
    _heldRenderStarted = Completer<void>();
    _releaseHeldRender = Completer<void>();
  }

  Future<void> waitUntilHeldRenderStarts() async {
    final started = _heldRenderStarted;
    if (started == null) throw StateError('No held render was requested.');
    await started.future.timeout(const Duration(seconds: 30));
  }

  @override
  EngineTask<AnalysisLevels> levels(Uri source, AnalysisMethod method) =>
      delegate.levels(source, method);

  @override
  EngineTask<DetectedTimeline> detect(Uri source, AnalysisSettings settings) =>
      delegate.detect(source, settings);

  @override
  EngineTask<MediaMetadata> probe(Uri source) => delegate.probe(source);

  @override
  EngineTask<Uri> render(RenderRequest request) {
    final started = _heldRenderStarted;
    final release = _releaseHeldRender;
    if (started == null || release == null) return delegate.render(request);
    final task = delegate.render(request);
    started.complete();
    _heldRenderStarted = null;
    _releaseHeldRender = null;
    return _HeldEngineTask<Uri>(task, release);
  }
}

final class _HeldEngineTask<T> implements EngineTask<T> {
  _HeldEngineTask(this.delegate, this.release)
    : _result = _holdResult(delegate.result, release.future);

  final EngineTask<T> delegate;
  final Completer<void> release;
  final Future<T> _result;

  @override
  Stream<EngineProgress> get progress => delegate.progress;

  @override
  Future<T> get result => _result;

  @override
  Future<void> cancel() async {
    try {
      await delegate.cancel();
    } finally {
      if (!release.isCompleted) release.complete();
    }
  }
}

Future<T> _holdResult<T>(Future<T> source, Future<void> release) {
  final held = Completer<T>();
  source.then<void>(
    (value) async {
      await release;
      held.complete(value);
    },
    onError: (Object error, StackTrace stack) async {
      await release;
      held.completeError(error, stack);
    },
  );
  return held.future;
}

final class _TestPlayback implements PlaybackPort {
  final StreamController<int> _positions = StreamController<int>.broadcast();
  final StreamController<bool> _playing = StreamController<bool>.broadcast();

  @override
  Stream<bool> get playing => _playing.stream;

  @override
  Stream<int> get positionUs => _positions.stream;

  @override
  Future<void> dispose() async {
    await _positions.close();
    await _playing.close();
  }

  @override
  Future<void> open(Uri source) async {
    _positions.add(0);
    _playing.add(false);
  }

  @override
  Future<void> pause() async => _playing.add(false);

  @override
  Future<void> play() async => _playing.add(true);

  @override
  Future<void> seek(int sourceUs) async => _positions.add(sourceUs);

  @override
  Future<void> setRate(double rate) async {}
}
