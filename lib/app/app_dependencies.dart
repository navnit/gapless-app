import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:gapless/core/process/io_process_runner.dart';
import 'package:gapless/core/process/process_runner.dart';
import 'package:gapless/features/analysis/application/analysis_coordinator.dart';
import 'package:gapless/features/analysis/data/analysis_cache.dart';
import 'package:gapless/features/editor/domain/effective_timeline.dart';
import 'package:gapless/features/editor/presentation/editor_view_model.dart';
import 'package:gapless/features/engine/data/auto_editor/auto_editor_adapter.dart';
import 'package:gapless/features/engine/data/auto_editor/auto_editor_locator.dart';
import 'package:gapless/features/engine/domain/engine_port.dart';
import 'package:gapless/features/export/presentation/export_dialog.dart';
import 'package:gapless/features/playback/application/edited_playback_controller.dart';
import 'package:gapless/features/playback/data/media_kit_playback_adapter.dart';
import 'package:gapless/features/playback/domain/playback_port.dart';
import 'package:gapless/features/project/application/autosave_controller.dart';
import 'package:gapless/features/project/data/project_repository.dart';
import 'package:gapless/features/project/domain/project_document.dart';
import 'package:gapless/features/project/domain/source_reference.dart';
import 'package:gapless/features/update/application/app_update_services.dart';
import 'package:gapless/features/update/application/update_coordinator.dart';
import 'package:gapless/features/update/data/caskroom_channel_detector.dart';
import 'package:gapless/features/update/data/github_update_checker.dart';
import 'package:gapless/features/update/data/json_update_preferences.dart';
import 'package:gapless/features/update/domain/app_version.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit_video/media_kit_video.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

typedef EditorViewModelFactory = EditorViewModel Function();
typedef AppDirectoriesLoader = Future<AppDirectories> Function();
typedef AppPlaybackFactory = AppPlayback Function();

final class AppDirectories {
  AppDirectories({
    required this.applicationSupport,
    required this.cache,
    required this.temporary,
    required this.flutterAssets,
  }) {
    for (final directory in <Directory>[
      applicationSupport,
      cache,
      temporary,
      flutterAssets,
    ]) {
      if (!p.isAbsolute(directory.path)) {
        throw ArgumentError.value(
          directory.path,
          'directory',
          'Must be absolute',
        );
      }
    }
  }

  final Directory applicationSupport;
  final Directory cache;
  final Directory temporary;
  final Directory flutterAssets;
}

final class AppPlayback {
  const AppPlayback({required this.playback, this.videoController});

  final PlaybackPort playback;
  final VideoController? videoController;
}

final class AppDependencies {
  const AppDependencies({
    required this.editorViewModelFactory,
    this.videoController,
    this.exportDialogs,
    this.update,
  });

  const AppDependencies.empty()
    : editorViewModelFactory = null,
      videoController = null,
      exportDialogs = null,
      update = null;

  final EditorViewModelFactory? editorViewModelFactory;
  final VideoController? videoController;
  final AppExportDialogServices? exportDialogs;
  final AppUpdateServices? update;

  EditorViewModel createEditorViewModel() =>
      editorViewModelFactory?.call() ?? EditorViewModel.empty();

  static Future<AppDependencies> production({
    AppDirectoriesLoader? loadDirectories,
    ProcessRunner? processRunner,
    EnginePort? engine,
    AppPlaybackFactory? playbackFactory,
    EditorFilePicker? picker,
    SourceFingerprinter? fingerprinter,
    ProjectRepository? projectRepository,
    RecentProjectsPort? recents,
    EditorExportPort? exporter,
    AnalysisCacheStore? analysisCache,
    UpdateCoordinator? updateCoordinator,
    Future<String> Function()? loadAppVersion,
  }) async {
    final directories = await (loadDirectories ?? _loadAppDirectories)();
    final runner = processRunner ?? IoProcessRunner();
    final engineDirectory = nativeAutoEditorInstallRoot(
      resolvedExecutable: Platform.resolvedExecutable,
    );
    final resolvedEngine =
        engine ??
        AutoEditorAdapter(
          processRunner: runner,
          executableLocator: AutoEditorLocator(
            manifestPath: p.join(engineDirectory, 'manifest.json'),
            installRoot: engineDirectory,
            processRunner: runner,
          ),
          temporaryPathFactory: _TemporaryPathFactory(
            Directory(p.join(directories.temporary.path, 'gapless')),
          ).create,
        );
    final resolvedFingerprinter =
        fingerprinter ??
        const SampledSourceFingerprinter(reader: LocalSourceSampleReader());
    final repository =
        projectRepository ??
        ProjectRepository(fingerprinter: resolvedFingerprinter);
    final projectStore = _DirectoryCreatingProjectStore(repository);
    final coordinator = AnalysisCoordinator(
      engine: resolvedEngine,
      cache:
          analysisCache ??
          AnalysisCache(
            directory: Directory(p.join(directories.cache.path, 'analysis')),
          ),
      engineVersion: autoEditorPinnedVersion,
    );
    final analysis = CoordinatedEditorAnalysis(coordinator);
    final appPlayback = playbackFactory?.call() ?? _createProductionPlayback();
    final playbackOwner = _EditedPlaybackOwner(appPlayback.playback);
    final resolvedRecents =
        recents ??
        JsonRecentProjectsStore(
          File(
            p.join(directories.applicationSupport.path, 'recent-projects.json'),
          ),
        );
    final exportHost = exporter == null ? AppExportDialogHost() : null;
    final resolvedExporter = exporter ?? exportHost!;
    final projectsDirectory = Directory(
      p.join(directories.applicationSupport.path, 'projects'),
    );
    final resolveVersion = loadAppVersion ?? _defaultAppVersion;
    final resolvedUpdateCoordinator =
        updateCoordinator ??
        UpdateCoordinator(
          checker: GithubUpdateChecker(
            client: http.Client(),
            archToken: Abi.current() == Abi.macosX64 ? 'x64' : 'arm64',
          ),
          detector: CaskroomChannelDetector(
            resolvedExecutable: Platform.resolvedExecutable,
          ),
          preferences: JsonUpdatePreferences(
            File(
              p.join(
                directories.applicationSupport.path,
                'update-preferences.json',
              ),
            ),
          ),
          currentVersion:
              AppVersion.tryParse(await resolveVersion()) ??
              const AppVersion(0, 0, 0),
          now: DateTime.now,
        );
    final runtime = EditorRuntime(
      picker: picker ?? const FileSelectorEditorFilePicker(),
      fingerprinter: resolvedFingerprinter,
      engine: resolvedEngine,
      analysis: analysis,
      playback: appPlayback.playback,
      projects: projectStore,
      recents: resolvedRecents,
      sourceResolver: ProjectRepositorySourceResolver(repository),
      exporter: resolvedExporter,
      draftProjectFor: (source) => _draftProjectUri(projectsDirectory, source),
      autosaveFactory: (project) => AutosaveController(
        project: project,
        store: projectStore,
        delay: const Duration(milliseconds: 350),
      ),
      onTimelineChanged: playbackOwner.updateTimeline,
      onPreviewModeChanged: playbackOwner.updateMode,
      onSourceWillOpen: playbackOwner.prepareSource,
      disposeRuntime: () async {
        await analysis.dispose();
        await playbackOwner.dispose();
      },
    );
    return AppDependencies(
      editorViewModelFactory: () => EditorViewModel(
        initialState: const EditorState.empty(),
        runtime: runtime,
      ),
      videoController: appPlayback.videoController,
      exportDialogs: exportHost == null
          ? null
          : AppExportDialogServices(
              host: exportHost,
              engine: resolvedEngine,
              destinationPicker: const FileSelectorExportDestinationPicker(),
              revealInFolder: const NativeExportRevealInFolder(),
            ),
      update: AppUpdateServices(coordinator: resolvedUpdateCoordinator),
    );
  }
}

Future<String> _defaultAppVersion() async {
  try {
    return (await PackageInfo.fromPlatform()).version;
  } on Object {
    return '0.0.0';
  }
}

final class AppExportDialogRequest {
  AppExportDialogRequest(this.request) : _complete = Completer<void>();

  final EditorExportRequest request;
  final Completer<void> _complete;
  Future<void> get completed => _complete.future;

  void finish() {
    if (!_complete.isCompleted) _complete.complete();
  }
}

final class AppExportDialogHost implements EditorExportPort {
  final StreamController<AppExportDialogRequest> _requests =
      StreamController<AppExportDialogRequest>.broadcast(sync: true);

  Stream<AppExportDialogRequest> get requests => _requests.stream;

  @override
  Future<void> request(EditorExportRequest request) async {
    final dialog = AppExportDialogRequest(request);
    _requests.add(dialog);
    await dialog.completed;
  }
}

final class AppExportDialogServices {
  const AppExportDialogServices({
    required this.host,
    required this.engine,
    required this.destinationPicker,
    required this.revealInFolder,
  });

  final AppExportDialogHost host;
  final EnginePort engine;
  final ExportDestinationPicker destinationPicker;
  final ExportRevealInFolder revealInFolder;
}

Future<AppDirectories> _loadAppDirectories() async => AppDirectories(
  applicationSupport: await getApplicationSupportDirectory(),
  cache: await getApplicationCacheDirectory(),
  temporary: await getTemporaryDirectory(),
  flutterAssets: Directory(_flutterAssetsPath()),
);

String _flutterAssetsPath() {
  final executableDirectory = p.dirname(Platform.resolvedExecutable);
  return switch (Platform.operatingSystem) {
    'macos' => p.join(
      p.dirname(executableDirectory),
      'Frameworks',
      'App.framework',
      'Resources',
      'flutter_assets',
    ),
    'linux' ||
    'windows' => p.join(executableDirectory, 'data', 'flutter_assets'),
    final unsupported => throw UnsupportedError(
      'Gapless production composition is unavailable on $unsupported.',
    ),
  };
}

AppPlayback _createProductionPlayback() {
  final playback = MediaKitPlaybackAdapter();
  return AppPlayback(
    playback: playback,
    videoController: playback.videoController,
  );
}

Uri _draftProjectUri(Directory directory, Uri source) {
  final sourcePath = source.toFilePath();
  final basename = p.basenameWithoutExtension(sourcePath);
  final safeStem = basename.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  final identity = sha256
      .convert(utf8.encode(source.toString()))
      .toString()
      .substring(0, 12);
  return Uri.file(p.join(directory.path, '$safeStem-$identity.gapless'));
}

final class _TemporaryPathFactory {
  _TemporaryPathFactory(this.directory);

  final Directory directory;
  var _sequence = 0;

  Future<Uri> create(String extension) async {
    await directory.create(recursive: true);
    final name =
        'auto-editor-${DateTime.now().microsecondsSinceEpoch}-${_sequence++}$extension';
    return Uri.file(p.join(directory.path, name));
  }
}

final class _DirectoryCreatingProjectStore implements ProjectStore {
  const _DirectoryCreatingProjectStore(this.repository);

  final ProjectRepository repository;

  @override
  Future<ProjectDocument> load(Uri project) => repository.load(project);

  @override
  Future<RecoveryCandidate?> recoveryFor(Uri project) =>
      repository.recoveryFor(project);

  @override
  Future<void> saveAtomic(Uri project, ProjectDocument document) async {
    await Directory(p.dirname(project.toFilePath())).create(recursive: true);
    await repository.saveAtomic(project, document);
  }
}

final class _EditedPlaybackOwner {
  _EditedPlaybackOwner(this.playback);

  final PlaybackPort playback;
  EditedPlaybackController? _edited;
  PreviewMode _mode = PreviewMode.edited;
  Future<void> _tail = Future<void>.value();
  Future<void>? _disposeFuture;
  var _disposed = false;

  Future<void> prepareSource(PreviewMode mode) {
    if (_disposed) return Future<void>.value();
    return _enqueue(() async {
      if (_disposed) return;
      _mode = mode;
      final previous = _edited;
      _edited = null;
      await previous?.dispose();
    });
  }

  Future<void> updateTimeline(EffectiveTimeline timeline) {
    if (_disposed) return Future<void>.value();
    return _enqueue(() async {
      if (_disposed) return;
      final current = _edited;
      if (current == null) {
        final created = EditedPlaybackController(
          player: playback,
          timeline: timeline,
          seekToleranceUs: 50000,
        );
        _edited = created;
        await created.setMode(_playbackMode(_mode));
        return;
      }
      await current.updateTimeline(timeline);
    });
  }

  Future<void> updateMode(PreviewMode mode) {
    if (_disposed) return Future<void>.value();
    return _enqueue(() async {
      if (_disposed) return;
      _mode = mode;
      await _edited?.setMode(_playbackMode(mode));
    });
  }

  Future<void> dispose() {
    final existing = _disposeFuture;
    if (existing != null) return existing;
    _disposed = true;
    final result = _enqueue(() async {
      final previous = _edited;
      _edited = null;
      await previous?.dispose();
      await playback.dispose();
    });
    _disposeFuture = result;
    return result;
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}

PlaybackMode _playbackMode(PreviewMode mode) => switch (mode) {
  PreviewMode.original => PlaybackMode.original,
  PreviewMode.edited => PlaybackMode.edited,
};

final class FileSelectorEditorFilePicker implements EditorFilePicker {
  const FileSelectorEditorFilePicker();

  static const _mediaTypes = <XTypeGroup>[
    XTypeGroup(
      label: 'Media',
      extensions: <String>[
        'mp4',
        'mov',
        'mkv',
        'webm',
        'avi',
        'm4v',
        'wav',
        'mp3',
        'm4a',
        'flac',
        'ogg',
      ],
      uniformTypeIdentifiers: <String>['public.movie', 'public.audio'],
      mimeTypes: <String>['video/*', 'audio/*'],
    ),
  ];

  static const _projectTypes = <XTypeGroup>[
    XTypeGroup(
      label: 'Gapless project',
      extensions: <String>['gapless'],
      mimeTypes: <String>['application/json'],
    ),
  ];

  @override
  Future<Uri?> pickVideo() async {
    final file = await openFile(acceptedTypeGroups: _mediaTypes);
    return file == null ? null : Uri.file(file.path);
  }

  @override
  Future<Uri?> pickProject() async {
    final file = await openFile(acceptedTypeGroups: _projectTypes);
    return file == null ? null : Uri.file(file.path);
  }

  @override
  Future<Uri?> saveProject({required String suggestedName}) async {
    final location = await getSaveLocation(
      acceptedTypeGroups: _projectTypes,
      suggestedName: suggestedName,
    );
    return location == null ? null : Uri.file(location.path);
  }
}

final class FileSelectorExportDestinationPicker
    implements ExportDestinationPicker {
  const FileSelectorExportDestinationPicker();

  static const _mp4Types = <XTypeGroup>[
    XTypeGroup(
      label: 'MP4 video',
      extensions: <String>['mp4'],
      mimeTypes: <String>['video/mp4'],
      uniformTypeIdentifiers: <String>['public.mpeg-4'],
    ),
  ];

  @override
  Future<Uri?> chooseMp4Destination(Uri? suggested) async {
    final location = await getSaveLocation(
      acceptedTypeGroups: _mp4Types,
      suggestedName: suggested == null
          ? 'Gapless export.mp4'
          : p.basename(suggested.toFilePath()),
      initialDirectory: suggested == null
          ? null
          : p.dirname(suggested.toFilePath()),
    );
    return location == null ? null : Uri.file(location.path);
  }
}

final class NativeExportRevealInFolder implements ExportRevealInFolder {
  const NativeExportRevealInFolder();

  @override
  Future<void> reveal(Uri file) async {
    final filePath = file.toFilePath();
    final result = switch (Platform.operatingSystem) {
      'macos' => await Process.run('open', <String>['-R', filePath]),
      'windows' => await Process.run('explorer.exe', <String>[
        '/select,$filePath',
      ]),
      'linux' => await Process.run('xdg-open', <String>[p.dirname(filePath)]),
      final unsupported => throw UnsupportedError(
        'Reveal in folder is unavailable on $unsupported.',
      ),
    };
    if (result.exitCode != 0) {
      throw FileSystemException('Could not reveal export', filePath);
    }
  }
}

final class JsonRecentProjectsStore implements RecentProjectsPort {
  const JsonRecentProjectsStore(this.file);

  static const schemaVersion = 1;
  final File file;

  @override
  Future<List<Uri>> load() async {
    try {
      if (!await file.exists()) return const <Uri>[];
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic> ||
          decoded.length != 2 ||
          decoded['schemaVersion'] != schemaVersion ||
          decoded['projects'] is! List<dynamic>) {
        return const <Uri>[];
      }
      final projects = <Uri>[];
      for (final value in decoded['projects'] as List<dynamic>) {
        if (value is! String) return const <Uri>[];
        final uri = Uri.tryParse(value);
        if (uri == null || !uri.isScheme('file')) return const <Uri>[];
        projects.add(uri);
      }
      return List<Uri>.unmodifiable(projects);
    } on Object {
      return const <Uri>[];
    }
  }

  @override
  Future<void> save(List<Uri> projects) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      '${jsonEncode(<String, Object>{'schemaVersion': schemaVersion, 'projects': projects.map((uri) => uri.toString()).toList()})}\n',
      flush: true,
    );
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }

  @override
  Future<bool> exists(Uri project) => File.fromUri(project).exists();
}

final class ProjectRepositorySourceResolver implements EditorSourceResolver {
  const ProjectRepositorySourceResolver(this.repository);

  final ProjectRepository repository;

  @override
  Future<Uri?> resolve(Uri project, SourceReference source) =>
      repository.resolveSource(project, source);
}

final class CoordinatedEditorAnalysis implements EditorAnalysisPort {
  CoordinatedEditorAnalysis(this.coordinator) {
    _subscription = coordinator.states.listen((state) {
      final requestId = _requestId;
      if (requestId != null && !_disposed) {
        _updates.add(EditorAnalysisUpdate(requestId: requestId, state: state));
      }
    });
  }

  final AnalysisCoordinator coordinator;
  final StreamController<EditorAnalysisUpdate> _updates =
      StreamController<EditorAnalysisUpdate>.broadcast(sync: true);
  late final StreamSubscription<AnalysisState> _subscription;
  int? _requestId;
  Future<void>? _disposeFuture;
  var _disposed = false;

  @override
  AnalysisState get state => coordinator.state;

  @override
  Stream<EditorAnalysisUpdate> get updates => _updates.stream;

  @override
  void request(ProjectDocument document, {required int requestId}) {
    if (_disposed) throw StateError('Editor analysis is disposed.');
    _requestId = requestId;
    coordinator.request(document);
  }

  @override
  Future<void> cancel() => coordinator.cancel();

  @override
  void invalidate() {
    if (!_disposed) _requestId = null;
  }

  @override
  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    _requestId = null;
    await _subscription.cancel();
    await coordinator.dispose();
    await _updates.close();
  }
}

final class CallbackEditorExportPort implements EditorExportPort {
  const CallbackEditorExportPort(this.onRequest);

  final Future<void> Function(EditorExportRequest request) onRequest;

  @override
  Future<void> request(EditorExportRequest request) => onRequest(request);
}
