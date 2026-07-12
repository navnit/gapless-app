import 'package:gapless/features/editor/domain/analysis_settings.dart';
import 'package:gapless/features/editor/domain/timeline_segment.dart';
import 'package:gapless/features/project/domain/source_reference.dart';

enum PreviewMode { original, edited }

final class ProjectUiState {
  const ProjectUiState({
    required this.previewMode,
    required this.timelineZoom,
    required this.sidebarWidth,
    required this.waveformHeight,
  });

  final PreviewMode previewMode;
  final double timelineZoom;
  final double sidebarWidth;
  final double waveformHeight;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectUiState &&
          previewMode == other.previewMode &&
          timelineZoom == other.timelineZoom &&
          sidebarWidth == other.sidebarWidth &&
          waveformHeight == other.waveformHeight;

  @override
  int get hashCode =>
      Object.hash(previewMode, timelineZoom, sidebarWidth, waveformHeight);
}

final class ProjectDocument {
  const ProjectDocument({
    required this.schemaVersion,
    required this.appVersion,
    required this.source,
    required this.settings,
    required this.detectedSegments,
    required this.manualOverrides,
    required this.ui,
  });

  static const currentSchemaVersion = 1;

  final int schemaVersion;
  final String appVersion;
  final SourceReference source;
  final AnalysisSettings settings;
  final List<TimelineSegment> detectedSegments;
  final List<TimelineSegment> manualOverrides;
  final ProjectUiState ui;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectDocument &&
          schemaVersion == other.schemaVersion &&
          appVersion == other.appVersion &&
          source == other.source &&
          settings == other.settings &&
          _listsEqual(detectedSegments, other.detectedSegments) &&
          _listsEqual(manualOverrides, other.manualOverrides) &&
          ui == other.ui;

  @override
  int get hashCode => Object.hash(
    schemaVersion,
    appVersion,
    source,
    settings,
    Object.hashAll(detectedSegments),
    Object.hashAll(manualOverrides),
    ui,
  );
}

bool _listsEqual<T>(List<T> first, List<T> second) {
  if (identical(first, second)) return true;
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    if (first[index] != second[index]) return false;
  }
  return true;
}

final class RecoveryCandidate {
  const RecoveryCandidate(this.uri, this.savedAtUtc, this.document);

  final Uri uri;
  final DateTime savedAtUtc;
  final ProjectDocument document;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RecoveryCandidate &&
          uri == other.uri &&
          savedAtUtc == other.savedAtUtc &&
          document == other.document;

  @override
  int get hashCode => Object.hash(uri, savedAtUtc, document);
}
