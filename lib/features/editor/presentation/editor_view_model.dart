import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:gapless/core/errors/app_failure.dart';
import 'package:gapless/core/errors/failure_presenter.dart';
import 'package:gapless/core/time/source_time_range.dart';
import 'package:gapless/features/analysis/application/analysis_coordinator.dart';
import 'package:gapless/features/editor/domain/analysis_settings.dart';
import 'package:gapless/features/editor/domain/effective_timeline.dart';
import 'package:gapless/features/editor/domain/timeline_segment.dart';
import 'package:gapless/features/editor/presentation/timeline_view_model.dart';
import 'package:gapless/features/engine/data/auto_editor/auto_editor_locator.dart';
import 'package:gapless/features/engine/domain/engine_models.dart';
import 'package:gapless/features/engine/domain/engine_port.dart';
import 'package:gapless/features/playback/domain/playback_port.dart';
import 'package:gapless/features/project/application/autosave_controller.dart';
import 'package:gapless/features/project/data/project_repository.dart';
import 'package:gapless/features/project/domain/project_document.dart';
import 'package:gapless/features/project/domain/source_reference.dart';
import 'package:path/path.dart' as p;

enum EditorPhase { empty, importing, analyzing, ready }

enum EditorSaveStatus { idle, saving, saved, failed }

abstract interface class EditorFilePicker {
  Future<Uri?> pickVideo();
  Future<Uri?> pickProject();
  Future<Uri?> saveProject({required String suggestedName});
}

abstract interface class EditorAnalysisPort {
  Stream<EditorAnalysisUpdate> get updates;
  AnalysisState get state;
  void request(ProjectDocument document, {required int requestId});
  Future<void> cancel();
  void invalidate();
  Future<void> dispose();
}

final class EditorAnalysisUpdate {
  const EditorAnalysisUpdate({required this.requestId, required this.state});

  final int requestId;
  final AnalysisState state;
}

abstract interface class RecentProjectsPort {
  Future<List<Uri>> load();
  Future<void> save(List<Uri> projects);
  Future<bool> exists(Uri project);
}

abstract interface class EditorSourceResolver {
  Future<Uri?> resolve(Uri project, SourceReference source);
}

final class EditorExportRequest {
  const EditorExportRequest({
    required this.source,
    required this.metadata,
    required this.timeline,
  });

  final Uri source;
  final MediaMetadata metadata;
  final EffectiveTimeline timeline;
}

abstract interface class EditorExportPort {
  Future<void> request(EditorExportRequest request);
}

typedef AutosaveFactory = AutosaveController Function(Uri project);
typedef DraftProjectUriFactory = Uri Function(Uri source);
typedef TimelineChanged = Future<void> Function(EffectiveTimeline timeline);
typedef PreviewModeChanged = Future<void> Function(PreviewMode mode);
typedef SourceWillOpen = Future<void> Function(PreviewMode mode);
typedef RuntimeDisposer = Future<void> Function();

final class EditorRuntime {
  const EditorRuntime({
    required this.picker,
    required this.fingerprinter,
    required this.engine,
    required this.analysis,
    required this.playback,
    required this.projects,
    required this.recents,
    required this.sourceResolver,
    required this.exporter,
    required this.draftProjectFor,
    required this.autosaveFactory,
    this.onTimelineChanged,
    this.onPreviewModeChanged,
    this.onSourceWillOpen,
    this.disposeRuntime,
  });

  final EditorFilePicker picker;
  final SourceFingerprinter fingerprinter;
  final EnginePort engine;
  final EditorAnalysisPort analysis;
  final PlaybackPort playback;
  final ProjectStore projects;
  final RecentProjectsPort recents;
  final EditorSourceResolver sourceResolver;
  final EditorExportPort exporter;
  final DraftProjectUriFactory draftProjectFor;
  final AutosaveFactory autosaveFactory;
  final TimelineChanged? onTimelineChanged;
  final PreviewModeChanged? onPreviewModeChanged;
  final SourceWillOpen? onSourceWillOpen;
  final RuntimeDisposer? disposeRuntime;
}

@immutable
final class EditorState {
  const EditorState({
    required this.phase,
    this.project,
    this.projectUri,
    this.metadata,
    this.levels,
    this.timeline,
    this.sourcePositionUs = 0,
    this.isPlaying = false,
    this.saveStatus = EditorSaveStatus.idle,
    this.message,
    this.failure,
    this.audioUnavailable = false,
    this.manualOverridesCleared = false,
    this.recentProjects = const <Uri>[],
  });

  const EditorState.empty()
    : this(phase: EditorPhase.empty, saveStatus: EditorSaveStatus.idle);

  const EditorState.analyzing({
    required ProjectDocument project,
    required Uri projectUri,
    required MediaMetadata metadata,
    EditorSaveStatus saveStatus = EditorSaveStatus.saved,
    String? message,
  }) : this(
         phase: EditorPhase.analyzing,
         project: project,
         projectUri: projectUri,
         metadata: metadata,
         saveStatus: saveStatus,
         message: message,
       );

  const EditorState.ready({
    required ProjectDocument project,
    required Uri projectUri,
    required MediaMetadata metadata,
    required AnalysisLevels levels,
    required EffectiveTimeline timeline,
    required int sourcePositionUs,
    required bool isPlaying,
    required EditorSaveStatus saveStatus,
    bool audioUnavailable = false,
    String? message,
  }) : this(
         phase: EditorPhase.ready,
         project: project,
         projectUri: projectUri,
         metadata: metadata,
         levels: levels,
         timeline: timeline,
         sourcePositionUs: sourcePositionUs,
         isPlaying: isPlaying,
         saveStatus: saveStatus,
         audioUnavailable: audioUnavailable,
         message: message,
       );

  final EditorPhase phase;
  final ProjectDocument? project;
  final Uri? projectUri;
  final MediaMetadata? metadata;
  final AnalysisLevels? levels;
  final EffectiveTimeline? timeline;
  final int sourcePositionUs;
  final bool isPlaying;
  final EditorSaveStatus saveStatus;
  final String? message;

  /// The failure backing [message], when the message came from an [AppFailure].
  /// Carries the detail the UI needs to offer "Copy diagnostics".
  final AppFailure? failure;
  final bool audioUnavailable;
  final bool manualOverridesCleared;
  final List<Uri> recentProjects;

  EditorState copyWith({
    EditorPhase? phase,
    ProjectDocument? project,
    Uri? projectUri,
    MediaMetadata? metadata,
    AnalysisLevels? levels,
    EffectiveTimeline? timeline,
    int? sourcePositionUs,
    bool? isPlaying,
    EditorSaveStatus? saveStatus,
    String? message,
    AppFailure? failure,
    bool clearFailure = false,
    bool? audioUnavailable,
    bool? manualOverridesCleared,
    List<Uri>? recentProjects,
  }) => EditorState(
    phase: phase ?? this.phase,
    project: project ?? this.project,
    projectUri: projectUri ?? this.projectUri,
    metadata: metadata ?? this.metadata,
    levels: levels ?? this.levels,
    timeline: timeline ?? this.timeline,
    sourcePositionUs: sourcePositionUs ?? this.sourcePositionUs,
    isPlaying: isPlaying ?? this.isPlaying,
    saveStatus: saveStatus ?? this.saveStatus,
    message: message ?? this.message,
    failure: clearFailure ? null : (failure ?? this.failure),
    audioUnavailable: audioUnavailable ?? this.audioUnavailable,
    manualOverridesCleared:
        manualOverridesCleared ?? this.manualOverridesCleared,
    recentProjects: recentProjects ?? this.recentProjects,
  );
}

final class EditorViewModel extends ChangeNotifier {
  EditorViewModel({
    required EditorState initialState,
    required this.runtime,
    Future<void> Function(String text)? copyToClipboard,
  }) : _state = initialState {
    if (copyToClipboard != null) _copyToClipboard = copyToClipboard;
    _attachRuntime();
    unawaited(loadRecentProjects());
  }

  EditorViewModel.preview({required EditorState initialState})
    : _state = initialState,
      runtime = null;

  EditorViewModel.empty() : _state = const EditorState.empty(), runtime = null;

  EditorState _state;
  EditorState get state => _state;

  final EditorRuntime? runtime;
  Future<void> Function(String text) _copyToClipboard = _writeClipboard;
  AutosaveController? _autosave;
  StreamSubscription<EditorAnalysisUpdate>? _analysisSubscription;
  StreamSubscription<int>? _positionSubscription;
  StreamSubscription<bool>? _playingSubscription;
  Future<void> _recentsTail = Future<void>.value();
  Future<void> _autosaveBarrier = Future<void>.value();
  Future<void> _playbackTail = Future<void>.value();
  EngineTask<MediaMetadata>? _probeTask;
  _AnalysisRequestIdentity? _analysisRequest;
  EditorState? _analysisRecoveryState;
  var _analysisRequestSequence = 0;
  var _operationGeneration = 0;
  var _pickerAttempt = 0;
  final List<_EditorCommand> _undo = <_EditorCommand>[];
  final List<_EditorCommand> _redo = <_EditorCommand>[];
  var _disposed = false;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  Future<void> openVideo() async {
    final runtime = this.runtime;
    if (runtime == null) return;
    final recoveryState = _state;
    final pickerAttempt = ++_pickerAttempt;
    int? generation;
    try {
      final source = await runtime.picker.pickVideo();
      if (source == null || !_isPickerAttemptCurrent(pickerAttempt)) return;
      generation = _beginOpenOperation();
      await _openVideo(runtime, generation, source);
    } on Object catch (error) {
      if (generation case final activeGeneration?) {
        _reportOperationFailure(
          activeGeneration,
          error,
          recoveryState: recoveryState,
        );
      } else {
        _reportPickerFailure(pickerAttempt, error);
      }
    }
  }

  Future<void> _openVideo(
    EditorRuntime runtime,
    int generation,
    Uri source,
  ) async {
    if (!_isOperationCurrent(generation)) return;
    _setState(
      const EditorState(
        phase: EditorPhase.importing,
        message: 'Opening video…',
      ),
    );

    final fingerprint = await runtime.fingerprinter.fingerprint(source);
    if (!_isOperationCurrent(generation)) return;
    final projectUri = runtime.draftProjectFor(source);
    final project = ProjectDocument(
      schemaVersion: ProjectDocument.currentSchemaVersion,
      appVersion: '1.0.0',
      source: SourceReference(
        relativePath: p.relative(
          source.toFilePath(),
          from: p.dirname(projectUri.toFilePath()),
        ),
        absolutePath: source.toFilePath(),
        fingerprint: fingerprint,
      ),
      settings: const AnalysisSettings(
        method: AnalysisMethod.audio,
        thresholdDb: -19,
        marginBeforeUs: 200000,
        marginAfterUs: 200000,
        inactiveBehavior: InactiveBehavior.cut,
      ),
      detectedSegments: const <TimelineSegment>[],
      manualOverrides: const <TimelineSegment>[],
      ui: const ProjectUiState(
        previewMode: PreviewMode.edited,
        timelineZoom: 1,
        sidebarWidth: 264,
        waveformHeight: 52,
      ),
    );
    _setState(
      EditorState(
        phase: EditorPhase.importing,
        project: project,
        projectUri: projectUri,
        saveStatus: EditorSaveStatus.idle,
        message: 'Reading video metadata…',
      ),
    );
    final metadata = await _probeSource(source, generation);
    if (metadata == null) return;
    await _save(project, generation: generation);
    if (!_isOperationCurrent(generation)) return;
    if (!await _openPlayback(source, generation, project.ui.previewMode)) {
      return;
    }
    await _rememberRecent(projectUri, generation: generation);
    if (!_isOperationCurrent(generation)) return;
    _undo.clear();
    _redo.clear();

    if (!metadata.hasAudio && project.settings.method == AnalysisMethod.audio) {
      _setState(
        _state.copyWith(
          phase: EditorPhase.ready,
          metadata: metadata,
          audioUnavailable: true,
          message: 'This video has no audio track.',
        ),
      );
      return;
    }

    _setState(
      _state.copyWith(
        phase: EditorPhase.analyzing,
        metadata: metadata,
        message: 'Reading audio loudness…',
      ),
    );
    _requestAnalysis(project, projectUri, generation);
  }

  Future<void> openProject([Uri? project]) async {
    final runtime = this.runtime;
    if (runtime == null) return;
    final recoveryState = _state;
    final pickerAttempt = ++_pickerAttempt;
    int? generation;
    try {
      final selected = project ?? await runtime.picker.pickProject();
      if (selected == null || !_isPickerAttemptCurrent(pickerAttempt)) return;
      generation = _beginOpenOperation();
      await _openProject(runtime, generation, selected);
    } on Object catch (error) {
      if (generation case final activeGeneration?) {
        _reportOperationFailure(
          activeGeneration,
          error,
          recoveryState: recoveryState,
        );
      } else {
        _reportPickerFailure(pickerAttempt, error);
      }
    }
  }

  Future<void> _openProject(
    EditorRuntime runtime,
    int generation,
    Uri selected,
  ) async {
    if (!_isOperationCurrent(generation)) return;
    _setState(
      const EditorState(
        phase: EditorPhase.importing,
        message: 'Opening project…',
      ),
    );
    final document = await runtime.projects.load(selected);
    if (!_isOperationCurrent(generation)) return;
    final source = await runtime.sourceResolver.resolve(
      selected,
      document.source,
    );
    if (!_isOperationCurrent(generation)) return;
    if (source == null) {
      _setState(
        EditorState(
          phase: EditorPhase.ready,
          project: document,
          projectUri: selected,
          saveStatus: EditorSaveStatus.saved,
          message: 'Source video not found.',
        ),
      );
      return;
    }
    final resolvedPath = source.toFilePath();
    final resolvedDocument = _copyProject(
      document,
      sourceReference: SourceReference(
        relativePath: p.relative(
          resolvedPath,
          from: p.dirname(selected.toFilePath()),
        ),
        absolutePath: resolvedPath,
        fingerprint: document.source.fingerprint,
      ),
    );
    _autosave = runtime.autosaveFactory(selected);
    _setState(
      EditorState(
        phase: EditorPhase.importing,
        project: resolvedDocument,
        projectUri: selected,
        saveStatus: EditorSaveStatus.idle,
        message: 'Saving relocated source…',
        recentProjects: _state.recentProjects,
      ),
    );
    await _save(resolvedDocument, generation: generation);
    if (!_isOperationCurrent(generation)) return;
    final metadata = await _probeSource(source, generation);
    if (metadata == null) return;
    if (!await _openPlayback(
      source,
      generation,
      resolvedDocument.ui.previewMode,
    )) {
      return;
    }
    _undo.clear();
    _redo.clear();
    await _rememberRecent(selected, generation: generation);
    if (!_isOperationCurrent(generation)) return;

    final timeline = EffectiveTimeline.compose(
      durationUs: metadata.durationUs,
      detected: resolvedDocument.detectedSegments,
      overrides: resolvedDocument.manualOverrides,
    );
    if (!metadata.hasAudio &&
        resolvedDocument.settings.method == AnalysisMethod.audio) {
      _setState(
        EditorState(
          phase: EditorPhase.ready,
          project: resolvedDocument,
          projectUri: selected,
          metadata: metadata,
          timeline: timeline,
          saveStatus: EditorSaveStatus.saved,
          audioUnavailable: true,
          message: 'This video has no audio track.',
          recentProjects: _state.recentProjects,
        ),
      );
      return;
    }
    _setState(
      EditorState(
        phase: EditorPhase.analyzing,
        project: resolvedDocument,
        projectUri: selected,
        metadata: metadata,
        timeline: timeline,
        saveStatus: EditorSaveStatus.saved,
        message: 'Reading audio loudness…',
        recentProjects: _state.recentProjects,
      ),
    );
    _requestAnalysis(
      _copyProject(
        resolvedDocument,
        manualOverrides: const <TimelineSegment>[],
      ),
      selected,
      generation,
    );
  }

  Future<void> save() async {
    final project = _state.project;
    if (project != null) await _save(project);
  }

  Future<void> retrySave() => save();

  Future<void> relocateSource() async {
    final runtime = this.runtime;
    final project = _state.project;
    final projectUri = _state.projectUri;
    if (runtime == null || project == null || projectUri == null) return;
    final generation = _operationGeneration;
    final selected = await runtime.picker.pickVideo();
    if (selected == null || !_isOperationCurrent(generation)) return;
    try {
      final fingerprint = await runtime.fingerprinter.fingerprint(selected);
      if (!project.source.fingerprint.matches(fingerprint)) {
        _setState(
          _state.copyWith(
            message: 'That video has changed and does not match this project.',
          ),
        );
        return;
      }
      final selectedPath = selected.toFilePath();
      final relocated = _copyProject(
        project,
        sourceReference: SourceReference(
          relativePath: p.relative(
            selectedPath,
            from: p.dirname(projectUri.toFilePath()),
          ),
          absolutePath: selectedPath,
          fingerprint: fingerprint,
        ),
      );
      _setState(
        _state.copyWith(
          project: relocated,
          message: 'Saving relocated source…',
        ),
      );
      await _save(relocated, generation: generation);
      if (_state.saveStatus == EditorSaveStatus.saved &&
          _isOperationCurrent(generation)) {
        await openProject(projectUri);
      }
    } on Object catch (error) {
      if (_isOperationCurrent(generation)) {
        _setState(_failureState(_state, error));
      }
    }
  }

  Future<void> saveAs() async {
    final runtime = this.runtime;
    final project = _state.project;
    if (runtime == null || project == null) return;
    final generation = _operationGeneration;
    final previousProjectUri = _state.projectUri;
    final sourceName = project.source.relativePath;
    final dot = sourceName.lastIndexOf('.');
    final stem = dot > 0 ? sourceName.substring(0, dot) : sourceName;
    final selected = await runtime.picker.saveProject(
      suggestedName: '$stem.gapless',
    );
    if (selected == null || !_isOperationCurrent(generation)) return;
    final selectedPath = selected.toFilePath();
    final target = selectedPath.toLowerCase().endsWith('.gapless')
        ? selected
        : Uri.file('$selectedPath.gapless');
    final previous = _autosave;
    _autosave = null;
    await _queueAutosaveDisposal(previous);
    if (!_isOperationCurrent(generation)) return;
    final currentProject = _state.project;
    if (currentProject == null) return;
    final analysisRequest = _analysisRequest;
    if (analysisRequest != null &&
        analysisRequest.generation == generation &&
        analysisRequest.projectUri == previousProjectUri &&
        analysisRequest.source == currentProject.source &&
        analysisRequest.settings == currentProject.settings) {
      _analysisRequest = analysisRequest.withProjectUri(target);
    }
    _setState(
      _state.copyWith(projectUri: target, saveStatus: EditorSaveStatus.idle),
    );
    await _save(currentProject, generation: generation);
    if (_state.saveStatus == EditorSaveStatus.saved) {
      await _rememberRecent(target, generation: generation);
    }
  }

  Future<void> export() async {
    final runtime = this.runtime;
    final project = _state.project;
    final projectUri = _state.projectUri;
    final metadata = _state.metadata;
    final timeline = _state.timeline;
    final generation = _operationGeneration;
    if (runtime == null ||
        project == null ||
        projectUri == null ||
        metadata == null ||
        timeline == null) {
      return;
    }
    try {
      await runtime.exporter.request(
        EditorExportRequest(
          source: Uri.file(project.source.absolutePath),
          metadata: metadata,
          timeline: timeline,
        ),
      );
    } on Object catch (error) {
      if (_isOperationCurrent(generation) && _state.projectUri == projectUri) {
        _setState(_failureState(_state, error));
      }
    }
  }

  Future<void> togglePlayback() async {
    final playback = runtime?.playback;
    if (playback == null || _state.project == null) return;
    if (_state.isPlaying) {
      await playback.pause();
    } else {
      await playback.play();
    }
  }

  Future<void> loadRecentProjects() async {
    await _serializeRecents(() async {
      final recents = runtime?.recents;
      if (recents == null) return;
      final stored = await recents.load();
      final accessible = <Uri>[];
      for (final project in stored) {
        if (await recents.exists(project)) accessible.add(project);
      }
      if (accessible.length != stored.length) {
        await recents.save(accessible);
      }
      _setState(
        _state.copyWith(recentProjects: List<Uri>.unmodifiable(accessible)),
      );
    });
  }

  Future<void> handleTimelineIntent(TimelineIntent intent) async {
    switch (intent) {
      case ToggleSegmentIntent(:final range):
        await _toggleSegment(range);
      case SeekTimelineIntent(:final sourceUs):
        await runtime?.playback.seek(sourceUs);
      case SetTimelineZoomIntent(:final zoom):
        await setTimelineZoom(zoom);
    }
  }

  Future<void> setTimelineZoom(double zoom) async {
    final project = _state.project;
    if (project == null) return;
    final updated = _copyProject(
      project,
      ui: ProjectUiState(
        previewMode: project.ui.previewMode,
        timelineZoom: zoom.clamp(1, 12).toDouble(),
        sidebarWidth: project.ui.sidebarWidth,
        waveformHeight: project.ui.waveformHeight,
      ),
    );
    await _applyProject(updated, save: true);
  }

  Future<void> setThresholdDb(double thresholdDb) async {
    if (!thresholdDb.isFinite || thresholdDb < -40 || thresholdDb > -6) {
      throw RangeError.range(thresholdDb, -40, -6, 'thresholdDb');
    }
    final project = _state.project;
    if (project == null) return;
    final settings = AnalysisSettings(
      method: project.settings.method,
      thresholdDb: thresholdDb,
      marginBeforeUs: project.settings.marginBeforeUs,
      marginAfterUs: project.settings.marginAfterUs,
      inactiveBehavior: project.settings.inactiveBehavior,
      fastForwardRate: project.settings.fastForwardRate,
    );
    await _changeDetectionSettings(settings);
  }

  Future<void> setAnalysisMethod(AnalysisMethod method) async {
    final project = _state.project;
    if (project == null || project.settings.method == method) return;
    final settings = AnalysisSettings(
      method: method,
      thresholdDb: project.settings.thresholdDb,
      marginBeforeUs: project.settings.marginBeforeUs,
      marginAfterUs: project.settings.marginAfterUs,
      inactiveBehavior: project.settings.inactiveBehavior,
      fastForwardRate: project.settings.fastForwardRate,
    );
    await _changeDetectionSettings(settings);
  }

  Future<void> setMargins({int? beforeUs, int? afterUs}) async {
    final project = _state.project;
    if (project == null) return;
    final settings = AnalysisSettings(
      method: project.settings.method,
      thresholdDb: project.settings.thresholdDb,
      marginBeforeUs: (beforeUs ?? project.settings.marginBeforeUs)
          .clamp(0, 2000000)
          .toInt(),
      marginAfterUs: (afterUs ?? project.settings.marginAfterUs)
          .clamp(0, 2000000)
          .toInt(),
      inactiveBehavior: project.settings.inactiveBehavior,
      fastForwardRate: project.settings.fastForwardRate,
    );
    if (settings == project.settings) return;
    await _changeDetectionSettings(settings);
  }

  Future<void> setInactiveBehavior(InactiveBehavior behavior) async {
    final project = _state.project;
    if (project == null || project.settings.inactiveBehavior == behavior) {
      return;
    }
    await _changeDetectionSettings(
      AnalysisSettings(
        method: project.settings.method,
        thresholdDb: project.settings.thresholdDb,
        marginBeforeUs: project.settings.marginBeforeUs,
        marginAfterUs: project.settings.marginAfterUs,
        inactiveBehavior: behavior,
        fastForwardRate: project.settings.fastForwardRate,
      ),
    );
  }

  Future<void> setFastForwardRate(double rate) async {
    final project = _state.project;
    if (project == null || !rate.isFinite) return;
    final clamped = rate.clamp(1.25, 64).toDouble();
    if (project.settings.fastForwardRate == clamped) return;
    await _changeDetectionSettings(
      AnalysisSettings(
        method: project.settings.method,
        thresholdDb: project.settings.thresholdDb,
        marginBeforeUs: project.settings.marginBeforeUs,
        marginAfterUs: project.settings.marginAfterUs,
        inactiveBehavior: project.settings.inactiveBehavior,
        fastForwardRate: clamped,
      ),
    );
  }

  Future<void> useMotion() => setAnalysisMethod(AnalysisMethod.motion);

  Future<void> cancelAnalysis() async {
    final runtime = this.runtime;
    final recovery = _analysisRecoveryState;
    if (runtime == null || recovery == null || _analysisRequest == null) return;
    _analysisRequest = null;
    _analysisRecoveryState = null;
    runtime.analysis.invalidate();
    await runtime.analysis.cancel();
    if (_disposed) return;
    _setState(recovery.copyWith(message: 'Analysis cancelled.'));
    final project = recovery.project;
    if (project != null) {
      await _save(project, generation: _operationGeneration);
    }
    final timeline = recovery.timeline;
    if (timeline != null) await runtime.onTimelineChanged?.call(timeline);
  }

  Future<void> _changeDetectionSettings(AnalysisSettings settings) async {
    final project = _state.project;
    final metadata = _state.metadata;
    if (project == null || metadata == null) return;
    if (_state.phase == EditorPhase.ready) {
      _analysisRecoveryState = _state;
    }
    final updated = _copyProject(
      project,
      settings: settings,
      manualOverrides: const <TimelineSegment>[],
    );
    final effective = EffectiveTimeline.compose(
      durationUs: metadata.durationUs,
      detected: updated.detectedSegments,
      overrides: const <TimelineSegment>[],
    );
    _recordCommand(project, updated, detectionChanged: true);
    final audioUnavailable =
        settings.method == AnalysisMethod.audio && !metadata.hasAudio;
    _setState(
      _state.copyWith(
        phase: audioUnavailable ? EditorPhase.ready : EditorPhase.analyzing,
        project: updated,
        timeline: effective,
        audioUnavailable: audioUnavailable,
        manualOverridesCleared: project.manualOverrides.isNotEmpty,
        message: audioUnavailable
            ? 'This video has no audio track.'
            : settings.method == AnalysisMethod.motion
            ? 'Reading motion levels…'
            : 'Reading audio loudness…',
      ),
    );
    if (!audioUnavailable) {
      final projectUri = _state.projectUri;
      if (projectUri != null) {
        _requestAnalysis(updated, projectUri, _operationGeneration);
      }
    }
    await _save(updated);
  }

  Future<void> setSidebarWidth(double width) =>
      _updateUi(sidebarWidth: width.clamp(208, 420).toDouble());

  Future<void> setWaveformHeight(double height) =>
      _updateUi(waveformHeight: height.clamp(28, 170).toDouble());

  Future<void> setPreviewMode(PreviewMode mode) async {
    await _updateUi(previewMode: mode);
    await runtime?.onPreviewModeChanged?.call(mode);
  }

  Future<void> _updateUi({
    PreviewMode? previewMode,
    double? sidebarWidth,
    double? waveformHeight,
  }) async {
    final project = _state.project;
    if (project == null) return;
    final updated = _copyProject(
      project,
      ui: ProjectUiState(
        previewMode: previewMode ?? project.ui.previewMode,
        timelineZoom: project.ui.timelineZoom,
        sidebarWidth: sidebarWidth ?? project.ui.sidebarWidth,
        waveformHeight: waveformHeight ?? project.ui.waveformHeight,
      ),
    );
    await _applyProject(updated, save: true);
  }

  Future<void> undo() async {
    if (_undo.isEmpty) return;
    final command = _undo.removeLast();
    _redo.add(command);
    await _restoreCommand(command.before, command.detectionChanged);
  }

  Future<void> redo() async {
    if (_redo.isEmpty) return;
    final command = _redo.removeLast();
    _undo.add(command);
    await _restoreCommand(command.after, command.detectionChanged);
  }

  Future<void> _toggleSegment(SourceTimeRange range) async {
    final project = _state.project;
    final timeline = _state.timeline;
    final metadata = _state.metadata;
    if (project == null || timeline == null || metadata == null) return;
    TimelineSegment? selected;
    for (final segment in timeline.segments) {
      if (segment.range == range) {
        selected = segment;
        break;
      }
    }
    if (selected == null) return;

    final overrides = List<TimelineSegment>.of(project.manualOverrides);
    final existingIndex = overrides.indexWhere((item) => item.range == range);
    if (existingIndex >= 0) {
      overrides.removeAt(existingIndex);
    } else {
      final inactiveAction = switch (project.settings.inactiveBehavior) {
        InactiveBehavior.cut => SegmentAction.cut,
        InactiveBehavior.fastForward => SegmentAction.fastForward,
      };
      final action = selected.action == SegmentAction.keep
          ? inactiveAction
          : SegmentAction.keep;
      overrides.add(
        TimelineSegment(
          range: range,
          action: action,
          rate: action == SegmentAction.fastForward
              ? project.settings.fastForwardRate
              : 1,
          origin: SegmentOrigin.manual,
        ),
      );
    }
    final updated = _copyProject(project, manualOverrides: overrides);
    final effective = EffectiveTimeline.compose(
      durationUs: metadata.durationUs,
      detected: updated.detectedSegments,
      overrides: updated.manualOverrides,
    );
    _setState(_state.copyWith(project: updated, timeline: effective));
    _recordCommand(project, updated, detectionChanged: false);
    await _save(updated);
    await runtime?.onTimelineChanged?.call(effective);
  }

  Future<void> _restoreCommand(
    ProjectDocument project,
    bool detectionChanged,
  ) async {
    final metadata = _state.metadata;
    if (metadata == null) return;
    final effective = EffectiveTimeline.compose(
      durationUs: metadata.durationUs,
      detected: project.detectedSegments,
      overrides: project.manualOverrides,
    );
    _setState(
      _state.copyWith(
        project: project,
        timeline: effective,
        manualOverridesCleared: false,
      ),
    );
    if (detectionChanged) {
      final projectUri = _state.projectUri;
      if (projectUri != null) {
        _requestAnalysis(
          _copyProject(project, manualOverrides: const <TimelineSegment>[]),
          projectUri,
          _operationGeneration,
        );
      }
      await _save(project);
    } else {
      await _save(project);
      await runtime?.onTimelineChanged?.call(effective);
    }
  }

  void _recordCommand(
    ProjectDocument before,
    ProjectDocument after, {
    required bool detectionChanged,
  }) {
    _undo.add(
      _EditorCommand(
        before: before,
        after: after,
        detectionChanged: detectionChanged,
      ),
    );
    _redo.clear();
  }

  Future<void> _applyProject(
    ProjectDocument project, {
    required bool save,
  }) async {
    _setState(_state.copyWith(project: project));
    if (save) await _save(project);
  }

  Future<void> _save(ProjectDocument document, {int? generation}) async {
    final runtime = this.runtime;
    final requestedGeneration = generation ?? _operationGeneration;
    final projectUri = _state.projectUri;
    if (runtime == null ||
        projectUri == null ||
        !_isOperationCurrent(requestedGeneration)) {
      return;
    }
    await _autosaveBarrier;
    if (!_isOperationCurrent(requestedGeneration) ||
        _state.projectUri != projectUri) {
      return;
    }
    var autosave = _autosave;
    if (autosave == null || autosave.project != projectUri) {
      if (autosave != null) await _queueAutosaveDisposal(autosave);
      if (!_isOperationCurrent(requestedGeneration) ||
          _state.projectUri != projectUri) {
        return;
      }
      autosave = runtime.autosaveFactory(projectUri);
      _autosave = autosave;
    }
    _setState(_state.copyWith(saveStatus: EditorSaveStatus.saving));
    autosave.markChanged(document);
    await autosave.flush();
    if (!_isOperationCurrent(requestedGeneration) ||
        !identical(_autosave, autosave) ||
        _state.projectUri != projectUri) {
      return;
    }
    final status = autosave.status;
    _setState(
      _state.copyWith(
        saveStatus: status is AutosaveFailed
            ? EditorSaveStatus.failed
            : EditorSaveStatus.saved,
      ),
    );
  }

  Future<void> _rememberRecent(Uri project, {int? generation}) async {
    await _serializeRecents(() async {
      final recents = runtime?.recents;
      if (recents == null) return;
      if (generation != null && !_isOperationCurrent(generation)) return;
      final values = List<Uri>.of(await recents.load());
      if (generation != null && !_isOperationCurrent(generation)) return;
      values.remove(project);
      values.insert(0, project);
      final bounded = values.take(10).toList(growable: false);
      await recents.save(bounded);
      if (generation != null && !_isOperationCurrent(generation)) return;
      _setState(
        _state.copyWith(recentProjects: List<Uri>.unmodifiable(bounded)),
      );
    });
  }

  Future<void> _serializeRecents(Future<void> Function() operation) {
    final result = _recentsTail.then((_) => operation());
    _recentsTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  int _beginOpenOperation() {
    final generation = ++_operationGeneration;
    _analysisRequest = null;
    _analysisRecoveryState = null;
    runtime?.analysis.invalidate();
    final previousAutosave = _autosave;
    _autosave = null;
    _queueAutosaveDisposal(previousAutosave);
    final probe = _probeTask;
    _probeTask = null;
    if (probe != null) {
      unawaited(
        probe.cancel().then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
    }
    return generation;
  }

  bool _isOperationCurrent(int generation) =>
      !_disposed && generation == _operationGeneration;

  bool _isPickerAttemptCurrent(int attempt) =>
      !_disposed && attempt == _pickerAttempt;

  void _reportPickerFailure(int attempt, Object error) {
    if (!_isPickerAttemptCurrent(attempt)) return;
    _setState(_failureState(_state, error));
  }

  void _reportOperationFailure(
    int generation,
    Object error, {
    EditorState? recoveryState,
  }) {
    if (!_isOperationCurrent(generation)) return;
    final current = recoveryState ?? _state;
    _setState(_failureState(current, error));
  }

  Future<void> _queueAutosaveDisposal(AutosaveController? autosave) {
    final previous = _autosaveBarrier;
    final result = previous.then((_) async {
      if (autosave == null) return;
      try {
        await autosave.flush();
      } on StateError {
        // A controller already disposed by a concurrent shutdown is finished.
      } finally {
        await autosave.dispose();
      }
    });
    _autosaveBarrier = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<MediaMetadata?> _probeSource(Uri source, int generation) async {
    if (!_isOperationCurrent(generation)) return null;
    final task = runtime!.engine.probe(source);
    _probeTask = task;
    try {
      final metadata = await task.result;
      return _isOperationCurrent(generation) ? metadata : null;
    } finally {
      if (identical(_probeTask, task)) _probeTask = null;
    }
  }

  Future<bool> _openPlayback(Uri source, int generation, PreviewMode mode) {
    final result = _playbackTail.then((_) async {
      if (!_isOperationCurrent(generation)) return false;
      await runtime!.onSourceWillOpen?.call(mode);
      if (!_isOperationCurrent(generation)) return false;
      await runtime!.playback.open(source);
      return _isOperationCurrent(generation);
    });
    _playbackTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  void _requestAnalysis(
    ProjectDocument document,
    Uri projectUri,
    int generation,
  ) {
    if (!_isOperationCurrent(generation)) return;
    final requestId = ++_analysisRequestSequence;
    _analysisRequest = _AnalysisRequestIdentity(
      requestId: requestId,
      generation: generation,
      projectUri: projectUri,
      source: document.source,
      settings: document.settings,
    );
    runtime?.analysis.request(document, requestId: requestId);
  }

  void _attachRuntime() {
    final runtime = this.runtime!;
    if (_state.projectUri case final project?) {
      _autosave = runtime.autosaveFactory(project);
    }
    _analysisSubscription = runtime.analysis.updates.listen(_onAnalysisUpdate);
    _positionSubscription = runtime.playback.positionUs.listen((positionUs) {
      if (!_disposed) _setState(_state.copyWith(sourcePositionUs: positionUs));
    });
    _playingSubscription = runtime.playback.playing.listen((playing) {
      if (!_disposed) _setState(_state.copyWith(isPlaying: playing));
    });
  }

  void _onAnalysisUpdate(EditorAnalysisUpdate update) {
    if (_disposed) return;
    final request = _analysisRequest;
    final currentProject = _state.project;
    if (request == null ||
        update.requestId != request.requestId ||
        !_isOperationCurrent(request.generation) ||
        _state.projectUri != request.projectUri ||
        currentProject == null ||
        currentProject.source != request.source ||
        currentProject.settings != request.settings) {
      return;
    }
    final analysis = update.state;
    switch (analysis) {
      case AnalysisIdle():
        break;
      case AnalysisRunning(:final progress):
        _setState(
          _state.copyWith(
            phase: EditorPhase.analyzing,
            message: _progressMessage(progress),
          ),
        );
      case AnalysisReady(:final timeline, :final levels):
        _analysisRecoveryState = null;
        final project = _state.project;
        if (project == null) return;
        final detected = timeline.segments
            .map(
              (segment) => TimelineSegment(
                range: segment.range,
                action: segment.action,
                rate: segment.rate,
                origin: SegmentOrigin.detected,
              ),
            )
            .toList(growable: false);
        final updated = _copyProject(project, detectedSegments: detected);
        final effective = EffectiveTimeline.compose(
          durationUs: timeline.durationUs,
          detected: detected,
          overrides: updated.manualOverrides,
        );
        _setState(
          _state.copyWith(
            phase: EditorPhase.ready,
            project: updated,
            levels: levels,
            timeline: effective,
          ),
        );
        final timelineChanged = runtime?.onTimelineChanged;
        if (timelineChanged != null) {
          unawaited(
            timelineChanged(effective).then<void>(
              (_) {},
              onError: (Object error, StackTrace _) {
                if (_isOperationCurrent(request.generation)) {
                  _setState(
                    _state.copyWith(
                      message:
                          'Preview could not be updated. Reopen the video and '
                          'try again.',
                    ),
                  );
                }
              },
            ),
          );
        }
        unawaited(_save(updated, generation: request.generation));
      case AnalysisFailed(:final failure):
        _setState(_failureState(_state, failure));
    }
  }

  /// Copies redacted diagnostics for the current [EditorState.failure] to the
  /// clipboard. No-op when there is no failure to report.
  Future<void> copyDiagnostics() async {
    final failure = _state.failure;
    if (failure == null) return;
    final text = FailurePresenter.formatDiagnostics(
      appVersion: _diagnosticsAppVersion,
      engineVersion: autoEditorPinnedVersion,
      platform: defaultTargetPlatform.name,
      stage: _state.phase.name,
      failure: failure,
    );
    await _copyToClipboard(text);
  }

  void _setState(EditorState state) {
    if (_disposed) return;
    _state = state;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _operationGeneration += 1;
    _pickerAttempt += 1;
    _analysisRequest = null;
    _analysisRecoveryState = null;
    runtime?.analysis.invalidate();
    final probe = _probeTask;
    _probeTask = null;
    if (probe != null) {
      unawaited(
        probe.cancel().then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
    }
    unawaited(_disposeOwned());
    super.dispose();
  }

  Future<void> _disposeOwned() async {
    await Future.wait<void>([
      if (_analysisSubscription != null) _analysisSubscription!.cancel(),
      if (_positionSubscription != null) _positionSubscription!.cancel(),
      if (_playingSubscription != null) _playingSubscription!.cancel(),
    ]);
    final autosave = _autosave;
    _autosave = null;
    await _queueAutosaveDisposal(autosave);
    await Future.wait<void>([_autosaveBarrier, _playbackTail, _recentsTail]);
    final runtime = this.runtime;
    if (runtime != null) {
      final disposeRuntime = runtime.disposeRuntime;
      if (disposeRuntime != null) {
        await disposeRuntime();
      } else {
        await runtime.analysis.dispose();
        await runtime.playback.dispose();
      }
    }
  }
}

const _diagnosticsAppVersion = '0.1.1';

Future<void> _writeClipboard(String text) =>
    Clipboard.setData(ClipboardData(text: text));

EditorState _failureState(EditorState base, Object error) => base.copyWith(
  message: _failureMessage(error),
  failure: error is AppFailure ? error : null,
  clearFailure: error is! AppFailure,
);

String _failureMessage(Object error) {
  if (error is OperationCancelled) return 'Operation cancelled.';
  if (error is AppFailure) {
    final presentation = FailurePresenter.present(error);
    return '${presentation.title}. ${presentation.body}';
  }
  return 'Something went wrong. Please try again.';
}

final class _EditorCommand {
  const _EditorCommand({
    required this.before,
    required this.after,
    required this.detectionChanged,
  });

  final ProjectDocument before;
  final ProjectDocument after;
  final bool detectionChanged;
}

final class _AnalysisRequestIdentity {
  const _AnalysisRequestIdentity({
    required this.requestId,
    required this.generation,
    required this.projectUri,
    required this.source,
    required this.settings,
  });

  final int requestId;
  final int generation;
  final Uri projectUri;
  final SourceReference source;
  final AnalysisSettings settings;

  _AnalysisRequestIdentity withProjectUri(Uri projectUri) =>
      _AnalysisRequestIdentity(
        requestId: requestId,
        generation: generation,
        projectUri: projectUri,
        source: source,
        settings: settings,
      );
}

String _progressMessage(EngineProgress progress) => switch (progress.stage) {
  EngineStage.probing => 'Reading video metadata…',
  EngineStage.analyzing => 'Reading audio loudness…',
  EngineStage.buildingTimeline => 'Detecting cuts…',
  EngineStage.rendering => 'Rendering…',
  EngineStage.writing => 'Writing…',
};

ProjectDocument _copyProject(
  ProjectDocument source, {
  SourceReference? sourceReference,
  AnalysisSettings? settings,
  List<TimelineSegment>? detectedSegments,
  List<TimelineSegment>? manualOverrides,
  ProjectUiState? ui,
}) => ProjectDocument(
  schemaVersion: source.schemaVersion,
  appVersion: source.appVersion,
  source: sourceReference ?? source.source,
  settings: settings ?? source.settings,
  detectedSegments: detectedSegments ?? source.detectedSegments,
  manualOverrides: manualOverrides ?? source.manualOverrides,
  ui: ui ?? source.ui,
);
