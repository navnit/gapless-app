import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:gapless/core/time/source_time_range.dart';
import 'package:gapless/features/analysis/application/analysis_coordinator.dart';
import 'package:gapless/features/editor/domain/analysis_settings.dart';
import 'package:gapless/features/editor/domain/effective_timeline.dart';
import 'package:gapless/features/editor/domain/timeline_segment.dart';
import 'package:gapless/features/editor/presentation/timeline_view_model.dart';
import 'package:gapless/features/engine/domain/engine_models.dart';
import 'package:gapless/features/engine/domain/engine_port.dart';
import 'package:gapless/features/playback/domain/playback_port.dart';
import 'package:gapless/features/project/application/autosave_controller.dart';
import 'package:gapless/features/project/data/project_repository.dart';
import 'package:gapless/features/project/domain/project_document.dart';
import 'package:gapless/features/project/domain/source_reference.dart';

enum EditorPhase { empty, importing, analyzing, ready }

enum EditorSaveStatus { idle, saving, saved, failed }

abstract interface class EditorFilePicker {
  Future<Uri?> pickVideo();
  Future<Uri?> pickProject();
  Future<Uri?> saveProject({required String suggestedName});
}

abstract interface class EditorAnalysisPort {
  Stream<AnalysisState> get states;
  AnalysisState get state;
  void request(ProjectDocument document);
  Future<void> dispose();
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
    audioUnavailable: audioUnavailable ?? this.audioUnavailable,
    manualOverridesCleared:
        manualOverridesCleared ?? this.manualOverridesCleared,
    recentProjects: recentProjects ?? this.recentProjects,
  );
}

final class EditorViewModel extends ChangeNotifier {
  EditorViewModel({required EditorState initialState, required this.runtime})
    : _state = initialState {
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
  AutosaveController? _autosave;
  StreamSubscription<AnalysisState>? _analysisSubscription;
  StreamSubscription<int>? _positionSubscription;
  StreamSubscription<bool>? _playingSubscription;
  final List<_EditorCommand> _undo = <_EditorCommand>[];
  final List<_EditorCommand> _redo = <_EditorCommand>[];
  var _disposed = false;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  Future<void> openVideo() async {
    final runtime = this.runtime;
    if (runtime == null) return;
    final source = await runtime.picker.pickVideo();
    if (source == null) return;
    _setState(
      const EditorState(
        phase: EditorPhase.importing,
        message: 'Opening video…',
      ),
    );

    final fingerprint = await runtime.fingerprinter.fingerprint(source);
    final projectUri = runtime.draftProjectFor(source);
    final project = ProjectDocument(
      schemaVersion: ProjectDocument.currentSchemaVersion,
      appVersion: '1.0.0',
      source: SourceReference(
        relativePath: source.pathSegments.isEmpty
            ? source.toFilePath()
            : source.pathSegments.last,
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
    _autosave = runtime.autosaveFactory(projectUri);
    _setState(
      EditorState(
        phase: EditorPhase.importing,
        project: project,
        projectUri: projectUri,
        saveStatus: EditorSaveStatus.idle,
        message: 'Reading video metadata…',
      ),
    );
    await _save(project);

    final metadata = await runtime.engine.probe(source).result;
    await runtime.playback.open(source);
    await _rememberRecent(projectUri);
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
    runtime.analysis.request(project);
  }

  Future<void> openProject([Uri? project]) async {
    final runtime = this.runtime;
    if (runtime == null) return;
    final selected = project ?? await runtime.picker.pickProject();
    if (selected == null) return;
    _setState(
      const EditorState(
        phase: EditorPhase.importing,
        message: 'Opening project…',
      ),
    );
    final document = await runtime.projects.load(selected);
    final source = await runtime.sourceResolver.resolve(
      selected,
      document.source,
    );
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
    final metadata = await runtime.engine.probe(source).result;
    await runtime.playback.open(source);
    _autosave = runtime.autosaveFactory(selected);
    _undo.clear();
    _redo.clear();
    await _rememberRecent(selected);

    final timeline = EffectiveTimeline.compose(
      durationUs: metadata.durationUs,
      detected: document.detectedSegments,
      overrides: document.manualOverrides,
    );
    if (!metadata.hasAudio &&
        document.settings.method == AnalysisMethod.audio) {
      _setState(
        EditorState(
          phase: EditorPhase.ready,
          project: document,
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
        project: document,
        projectUri: selected,
        metadata: metadata,
        timeline: timeline,
        saveStatus: EditorSaveStatus.saved,
        message: 'Reading audio loudness…',
        recentProjects: _state.recentProjects,
      ),
    );
    runtime.analysis.request(
      _copyProject(document, manualOverrides: const <TimelineSegment>[]),
    );
  }

  Future<void> save() async {
    final project = _state.project;
    if (project != null) await _save(project);
  }

  Future<void> retrySave() => save();

  Future<void> saveAs() async {
    final runtime = this.runtime;
    final project = _state.project;
    if (runtime == null || project == null) return;
    final sourceName = project.source.relativePath;
    final dot = sourceName.lastIndexOf('.');
    final stem = dot > 0 ? sourceName.substring(0, dot) : sourceName;
    final selected = await runtime.picker.saveProject(
      suggestedName: '$stem.gapless',
    );
    if (selected == null) return;
    final selectedPath = selected.toFilePath();
    final target = selectedPath.toLowerCase().endsWith('.gapless')
        ? selected
        : Uri.file('$selectedPath.gapless');
    await _autosave?.dispose();
    _autosave = runtime.autosaveFactory(target);
    _setState(
      _state.copyWith(projectUri: target, saveStatus: EditorSaveStatus.idle),
    );
    await _save(project);
    if (_state.saveStatus == EditorSaveStatus.saved) {
      await _rememberRecent(target);
    }
  }

  Future<void> export() async {
    final runtime = this.runtime;
    final project = _state.project;
    final metadata = _state.metadata;
    final timeline = _state.timeline;
    if (runtime == null ||
        project == null ||
        metadata == null ||
        timeline == null) {
      return;
    }
    await runtime.exporter.request(
      EditorExportRequest(
        source: Uri.file(project.source.absolutePath),
        metadata: metadata,
        timeline: timeline,
      ),
    );
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

  Future<void> _changeDetectionSettings(AnalysisSettings settings) async {
    final project = _state.project;
    final metadata = _state.metadata;
    if (project == null || metadata == null) return;
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
    if (!audioUnavailable) runtime?.analysis.request(updated);
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
    await runtime?.onTimelineChanged?.call(effective);
    await _save(updated);
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
      runtime?.analysis.request(
        _copyProject(project, manualOverrides: const <TimelineSegment>[]),
      );
    } else {
      await runtime?.onTimelineChanged?.call(effective);
    }
    await _save(project);
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

  Future<void> _save(ProjectDocument document) async {
    final runtime = this.runtime;
    final projectUri = _state.projectUri;
    if (runtime == null || projectUri == null) return;
    final autosave = _autosave ??= runtime.autosaveFactory(projectUri);
    _setState(_state.copyWith(saveStatus: EditorSaveStatus.saving));
    autosave.markChanged(document);
    await autosave.flush();
    if (_disposed) return;
    final status = autosave.status;
    _setState(
      _state.copyWith(
        saveStatus: status is AutosaveFailed
            ? EditorSaveStatus.failed
            : EditorSaveStatus.saved,
      ),
    );
  }

  Future<void> _rememberRecent(Uri project) async {
    final recents = runtime?.recents;
    if (recents == null) return;
    final values = await recents.load();
    values.remove(project);
    values.insert(0, project);
    final bounded = values.take(10).toList(growable: false);
    await recents.save(bounded);
    _setState(_state.copyWith(recentProjects: List<Uri>.unmodifiable(bounded)));
  }

  void _attachRuntime() {
    final runtime = this.runtime!;
    if (_state.projectUri case final project?) {
      _autosave = runtime.autosaveFactory(project);
    }
    _analysisSubscription = runtime.analysis.states.listen(_onAnalysisState);
    _positionSubscription = runtime.playback.positionUs.listen((positionUs) {
      if (!_disposed) _setState(_state.copyWith(sourcePositionUs: positionUs));
    });
    _playingSubscription = runtime.playback.playing.listen((playing) {
      if (!_disposed) _setState(_state.copyWith(isPlaying: playing));
    });
  }

  void _onAnalysisState(AnalysisState analysis) {
    if (_disposed) return;
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
        unawaited(runtime?.onTimelineChanged?.call(effective));
        unawaited(_save(updated));
      case AnalysisFailed(:final failure):
        _setState(_state.copyWith(message: failure.toString()));
    }
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
    unawaited(_disposeOwned());
    super.dispose();
  }

  Future<void> _disposeOwned() async {
    await Future.wait<void>([
      if (_analysisSubscription != null) _analysisSubscription!.cancel(),
      if (_positionSubscription != null) _positionSubscription!.cancel(),
      if (_playingSubscription != null) _playingSubscription!.cancel(),
    ]);
    await _autosave?.dispose();
    final runtime = this.runtime;
    if (runtime != null) {
      await runtime.analysis.dispose();
      await runtime.playback.dispose();
    }
  }
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

String _progressMessage(EngineProgress progress) => switch (progress.stage) {
  EngineStage.probing => 'Reading video metadata…',
  EngineStage.analyzing => 'Reading audio loudness…',
  EngineStage.buildingTimeline => 'Detecting cuts…',
  EngineStage.rendering => 'Rendering…',
  EngineStage.writing => 'Writing…',
};

ProjectDocument _copyProject(
  ProjectDocument source, {
  AnalysisSettings? settings,
  List<TimelineSegment>? detectedSegments,
  List<TimelineSegment>? manualOverrides,
  ProjectUiState? ui,
}) => ProjectDocument(
  schemaVersion: source.schemaVersion,
  appVersion: source.appVersion,
  source: source.source,
  settings: settings ?? source.settings,
  detectedSegments: detectedSegments ?? source.detectedSegments,
  manualOverrides: manualOverrides ?? source.manualOverrides,
  ui: ui ?? source.ui,
);
