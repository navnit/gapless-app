import 'dart:convert';

import 'package:gapless/core/errors/app_failure.dart';
import 'package:gapless/core/time/source_time_range.dart';
import 'package:gapless/features/editor/domain/analysis_settings.dart';
import 'package:gapless/features/editor/domain/timeline_segment.dart';
import 'package:gapless/features/project/domain/project_document.dart';
import 'package:gapless/features/project/domain/source_reference.dart';

final class ProjectCodec {
  ProjectDocument decode(String source) {
    try {
      final root = _object(jsonDecode(source), 'project');
      final schemaVersion = _integer(root, 'schemaVersion');
      if (schemaVersion != ProjectDocument.currentSchemaVersion) {
        throw ProjectFormatFailure('Unsupported schema version $schemaVersion');
      }

      final sourceJson = _object(_required(root, 'source'), 'source');
      final fingerprint = _string(sourceJson, 'fingerprint');
      final match = RegExp(r'^sha256:([0-9a-f]{64})$').firstMatch(fingerprint);
      if (match == null) {
        throw const ProjectFormatFailure('source.fingerprint is invalid');
      }

      final settingsJson = _object(_required(root, 'settings'), 'settings');
      final settings = AnalysisSettings(
        method: _enumValue(
          _string(settingsJson, 'method'),
          AnalysisMethod.values,
          'settings.method',
        ),
        thresholdDb: _finiteNumber(settingsJson, 'thresholdDb'),
        marginBeforeUs: _nonNegativeInteger(settingsJson, 'marginBeforeUs'),
        marginAfterUs: _nonNegativeInteger(settingsJson, 'marginAfterUs'),
        inactiveBehavior: _inactiveBehavior(settingsJson),
        fastForwardRate: _fastForwardRate(settingsJson),
      );

      final detected = _segments(
        root,
        'detectedSegments',
        SegmentOrigin.detected,
      );
      final overrides = _segments(
        root,
        'manualOverrides',
        SegmentOrigin.manual,
      );
      final uiJson = _object(_required(root, 'ui'), 'ui');

      return ProjectDocument(
        schemaVersion: schemaVersion,
        appVersion: _nonEmptyString(root, 'appVersion'),
        source: SourceReference(
          relativePath: _nonEmptyString(sourceJson, 'relativePath'),
          absolutePath: _nonEmptyString(sourceJson, 'absolutePath'),
          fingerprint: SourceFingerprint(
            size: _nonNegativeInteger(sourceJson, 'size'),
            modifiedAtUtc: _dateTime(sourceJson, 'modifiedAt'),
            sampledSha256: match.group(1)!,
          ),
        ),
        settings: settings,
        detectedSegments: List.unmodifiable(detected),
        manualOverrides: List.unmodifiable(overrides),
        ui: ProjectUiState(
          previewMode: _enumValue(
            _string(uiJson, 'previewMode'),
            PreviewMode.values,
            'ui.previewMode',
          ),
          timelineZoom: _positiveNumber(uiJson, 'timelineZoom'),
          sidebarWidth: _positiveNumber(uiJson, 'sidebarWidth'),
          waveformHeight: _positiveNumber(uiJson, 'waveformHeight'),
        ),
      );
    } on ProjectFormatFailure {
      rethrow;
    } catch (error) {
      throw ProjectFormatFailure('Invalid project: $error');
    }
  }

  String encode(ProjectDocument document) {
    final root = <String, Object?>{
      'schemaVersion': document.schemaVersion,
      'appVersion': document.appVersion,
      'source': <String, Object?>{
        'relativePath': document.source.relativePath,
        'absolutePath': document.source.absolutePath,
        'size': document.source.fingerprint.size,
        'modifiedAt': document.source.fingerprint.modifiedAtUtc
            .toUtc()
            .toIso8601String(),
        'fingerprint': 'sha256:${document.source.fingerprint.sampledSha256}',
      },
      'settings': <String, Object?>{
        'method': document.settings.method.name,
        'thresholdDb': document.settings.thresholdDb,
        'marginBeforeUs': document.settings.marginBeforeUs,
        'marginAfterUs': document.settings.marginAfterUs,
        'inactiveAction': switch (document.settings.inactiveBehavior) {
          InactiveBehavior.cut => 'cut',
          InactiveBehavior.fastForward => 'fastForward',
        },
        'fastForwardRate': document.settings.fastForwardRate,
      },
      'detectedSegments': document.detectedSegments
          .map(_encodeSegment)
          .toList(),
      'manualOverrides': document.manualOverrides.map(_encodeSegment).toList(),
      'ui': <String, Object?>{
        'previewMode': document.ui.previewMode.name,
        'timelineZoom': document.ui.timelineZoom,
        'sidebarWidth': document.ui.sidebarWidth,
        'waveformHeight': document.ui.waveformHeight,
      },
    };
    return '${const JsonEncoder.withIndent('  ').convert(root)}\n';
  }
}

Map<String, Object?> _encodeSegment(TimelineSegment segment) => {
  'startUs': segment.range.startUs,
  'endUs': segment.range.endUs,
  'action': segment.action.name,
  'rate': segment.rate,
};

List<TimelineSegment> _segments(
  Map<String, dynamic> root,
  String key,
  SegmentOrigin origin,
) {
  final values = _list(_required(root, key), key);
  return [
    for (var index = 0; index < values.length; index++)
      _segment(_object(values[index], '$key[$index]'), '$key[$index]', origin),
  ];
}

TimelineSegment _segment(
  Map<String, dynamic> json,
  String path,
  SegmentOrigin origin,
) {
  final action = _enumValue(
    _string(json, 'action'),
    SegmentAction.values,
    '$path.action',
  );
  final rate = _finiteNumber(json, 'rate');
  if (action == SegmentAction.fastForward ? rate <= 1 : rate != 1) {
    throw ProjectFormatFailure('$path.rate is invalid for ${action.name}');
  }
  return TimelineSegment(
    range: SourceTimeRange(
      _nonNegativeInteger(json, 'startUs'),
      _nonNegativeInteger(json, 'endUs'),
    ),
    action: action,
    rate: rate,
    origin: origin,
  );
}

InactiveBehavior _inactiveBehavior(Map<String, dynamic> settings) {
  return switch (_string(settings, 'inactiveAction')) {
    'cut' => InactiveBehavior.cut,
    'fastForward' => InactiveBehavior.fastForward,
    final value => throw ProjectFormatFailure(
      'settings.inactiveAction has invalid value $value',
    ),
  };
}

double _fastForwardRate(Map<String, dynamic> settings) {
  final value = _finiteNumber(settings, 'fastForwardRate');
  if (value <= 1) {
    throw const ProjectFormatFailure(
      'settings.fastForwardRate must be greater than 1',
    );
  }
  return value;
}

T _enumValue<T extends Enum>(String name, List<T> values, String path) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  throw ProjectFormatFailure('$path has invalid value $name');
}

dynamic _required(Map<String, dynamic> json, String key) {
  if (!json.containsKey(key)) {
    throw ProjectFormatFailure('Missing required key $key');
  }
  return json[key];
}

Map<String, dynamic> _object(dynamic value, String path) {
  if (value is! Map) {
    throw ProjectFormatFailure('$path must be an object');
  }
  final result = <String, dynamic>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw ProjectFormatFailure('$path contains a non-string key');
    }
    result[entry.key as String] = entry.value;
  }
  return result;
}

List<dynamic> _list(dynamic value, String path) {
  if (value is! List) throw ProjectFormatFailure('$path must be an array');
  return value;
}

String _string(Map<String, dynamic> json, String key) {
  final value = _required(json, key);
  if (value is! String) throw ProjectFormatFailure('$key must be a string');
  return value;
}

String _nonEmptyString(Map<String, dynamic> json, String key) {
  final value = _string(json, key);
  if (value.isEmpty) throw ProjectFormatFailure('$key must not be empty');
  return value;
}

int _integer(Map<String, dynamic> json, String key) {
  final value = _required(json, key);
  if (value is! int) throw ProjectFormatFailure('$key must be an integer');
  return value;
}

int _nonNegativeInteger(Map<String, dynamic> json, String key) {
  final value = _integer(json, key);
  if (value < 0) throw ProjectFormatFailure('$key must not be negative');
  return value;
}

double _finiteNumber(Map<String, dynamic> json, String key) {
  final value = _required(json, key);
  if (value is! num || !value.isFinite) {
    throw ProjectFormatFailure('$key must be a finite number');
  }
  return value.toDouble();
}

double _positiveNumber(Map<String, dynamic> json, String key) {
  final value = _finiteNumber(json, key);
  if (value <= 0) throw ProjectFormatFailure('$key must be positive');
  return value;
}

DateTime _dateTime(Map<String, dynamic> json, String key) {
  final raw = _string(json, key);
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) throw ProjectFormatFailure('$key must be an ISO date');
  return parsed.toUtc();
}
