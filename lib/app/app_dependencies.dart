import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:gapless/features/analysis/application/analysis_coordinator.dart';
import 'package:gapless/features/editor/presentation/editor_view_model.dart';
import 'package:gapless/features/project/data/project_repository.dart';
import 'package:gapless/features/project/domain/project_document.dart';
import 'package:gapless/features/project/domain/source_reference.dart';
import 'package:media_kit_video/media_kit_video.dart';

typedef EditorViewModelFactory = EditorViewModel Function();

final class AppDependencies {
  const AppDependencies({
    required this.editorViewModelFactory,
    this.videoController,
  });

  const AppDependencies.empty()
    : editorViewModelFactory = null,
      videoController = null;

  final EditorViewModelFactory? editorViewModelFactory;
  final VideoController? videoController;

  EditorViewModel createEditorViewModel() =>
      editorViewModelFactory?.call() ?? EditorViewModel.empty();
}

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
  const CoordinatedEditorAnalysis(this.coordinator);

  final AnalysisCoordinator coordinator;

  @override
  AnalysisState get state => coordinator.state;

  @override
  Stream<AnalysisState> get states => coordinator.states;

  @override
  void request(ProjectDocument document) => coordinator.request(document);

  @override
  Future<void> dispose() => coordinator.dispose();
}

final class CallbackEditorExportPort implements EditorExportPort {
  const CallbackEditorExportPort(this.onRequest);

  final Future<void> Function(EditorExportRequest request) onRequest;

  @override
  Future<void> request(EditorExportRequest request) => onRequest(request);
}
