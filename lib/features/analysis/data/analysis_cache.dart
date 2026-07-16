import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:gapless/core/time/source_time_range.dart';
import 'package:gapless/features/editor/domain/analysis_settings.dart';
import 'package:gapless/features/editor/domain/timeline_segment.dart';
import 'package:gapless/features/engine/domain/engine_models.dart';
import 'package:path/path.dart' as p;

final class AnalysisCacheKey {
  AnalysisCacheKey({
    required this.sampledSha256,
    required this.engineVersion,
    required this.settings,
  }) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sampledSha256)) {
      throw ArgumentError.value(sampledSha256, 'sampledSha256');
    }
    if (engineVersion.trim().isEmpty) {
      throw ArgumentError.value(engineVersion, 'engineVersion');
    }
    if (!settings.thresholdDb.isFinite) {
      throw ArgumentError.value(settings.thresholdDb, 'settings.thresholdDb');
    }
    if (settings.marginBeforeUs < 0) {
      throw ArgumentError.value(
        settings.marginBeforeUs,
        'settings.marginBeforeUs',
      );
    }
    if (settings.marginAfterUs < 0) {
      throw ArgumentError.value(
        settings.marginAfterUs,
        'settings.marginAfterUs',
      );
    }
    if (!settings.fastForwardRate.isFinite || settings.fastForwardRate <= 1) {
      throw ArgumentError.value(
        settings.fastForwardRate,
        'settings.fastForwardRate',
      );
    }
  }

  final String sampledSha256;
  final String engineVersion;
  final AnalysisSettings settings;

  String canonicalJson() => jsonEncode(<String, Object>{
    'sampledSha256': sampledSha256,
    'engineVersion': engineVersion,
    'method': settings.method.name,
    'thresholdDb': settings.thresholdDb,
    'marginBeforeUs': settings.marginBeforeUs,
    'marginAfterUs': settings.marginAfterUs,
    'inactiveBehavior': settings.inactiveBehavior.name,
    'fastForwardRate': settings.fastForwardRate,
  });

  String get stableKey =>
      sha256.convert(utf8.encode(canonicalJson())).toString();
}

abstract interface class AnalysisCacheStore {
  Future<AnalysisLevels?> readLevels(AnalysisCacheKey key);

  Future<void> writeLevels(AnalysisCacheKey key, AnalysisLevels levels);

  Future<DetectedTimeline?> readDetectedTimeline(AnalysisCacheKey key);

  Future<void> writeDetectedTimeline(
    AnalysisCacheKey key,
    DetectedTimeline timeline,
  );
}

final class AnalysisCache implements AnalysisCacheStore {
  AnalysisCache({required Directory directory}) : _directory = directory {
    if (!p.isAbsolute(directory.path)) {
      throw ArgumentError.value(directory.path, 'directory');
    }
  }

  static const _schemaVersion = 1;
  static int _temporarySequence = 0;

  final Directory _directory;

  @override
  Future<AnalysisLevels?> readLevels(AnalysisCacheKey key) =>
      _read(_entryFile(key, 'levels'), key, 'levels', _decodeLevels);

  @override
  Future<void> writeLevels(AnalysisCacheKey key, AnalysisLevels levels) =>
      _write(_entryFile(key, 'levels'), <String, Object>{
        'schemaVersion': _schemaVersion,
        'kind': 'levels',
        'key': key.stableKey,
        'payload': <String, Object>{
          'samples': levels.samples,
          'samplePeriodUs': levels.samplePeriodUs,
        },
      });

  @override
  Future<DetectedTimeline?> readDetectedTimeline(AnalysisCacheKey key) =>
      _read(_entryFile(key, 'timeline'), key, 'timeline', _decodeTimeline);

  @override
  Future<void> writeDetectedTimeline(
    AnalysisCacheKey key,
    DetectedTimeline timeline,
  ) => _write(_entryFile(key, 'timeline'), <String, Object>{
    'schemaVersion': _schemaVersion,
    'kind': 'timeline',
    'key': key.stableKey,
    'payload': <String, Object>{
      'durationUs': timeline.durationUs,
      'segments': timeline.segments
          .map(
            (segment) => <String, Object>{
              'startUs': segment.range.startUs,
              'endUs': segment.range.endUs,
              'action': segment.action.name,
              'rate': segment.rate,
              'origin': segment.origin.name,
            },
          )
          .toList(growable: false),
    },
  });

  File _entryFile(AnalysisCacheKey key, String kind) =>
      File(p.join(_directory.path, '${key.stableKey}.$kind.json'));

  Future<T?> _read<T>(
    File file,
    AnalysisCacheKey key,
    String kind,
    T Function(Map<String, Object?> payload) decode,
  ) async {
    try {
      if (!await file.exists()) return null;
      final root = _object(jsonDecode(await file.readAsString()), 'entry');
      _exactKeys(root, const {'schemaVersion', 'kind', 'key', 'payload'});
      if (root['schemaVersion'] != _schemaVersion ||
          root['kind'] != kind ||
          root['key'] != key.stableKey) {
        throw const FormatException('Cache identity mismatch');
      }
      return decode(_object(root['payload'], 'payload'));
    } on Object {
      await _deleteBestEffort(file);
      return null;
    }
  }

  Future<void> _write(File target, Map<String, Object> payload) async {
    File? temporary;
    try {
      await _directory.create(recursive: true);
      temporary = File(
        '${target.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.'
        '${_temporarySequence++}.tmp',
      );
      await temporary.writeAsString(jsonEncode(payload), flush: true);
      if (Platform.isWindows && await target.exists()) {
        await _deleteBestEffort(temporary);
        return;
      }
      await temporary.rename(target.path);
      temporary = null;
    } on Object {
      // Cache population is disposable and must never fail analysis.
    } finally {
      if (temporary != null) await _deleteBestEffort(temporary);
    }
  }
}

AnalysisLevels _decodeLevels(Map<String, Object?> payload) {
  _exactKeys(payload, const {'samples', 'samplePeriodUs'});
  final samplesJson = payload['samples'];
  if (samplesJson is! List<Object?>) {
    throw const FormatException('samples must be an array');
  }
  final samples = samplesJson
      .map((sample) => _integer(sample, 'sample'))
      .toList();
  return AnalysisLevels(
    samples: samples,
    samplePeriodUs: _integer(payload['samplePeriodUs'], 'samplePeriodUs'),
  );
}

DetectedTimeline _decodeTimeline(Map<String, Object?> payload) {
  _exactKeys(payload, const {'durationUs', 'segments'});
  final durationUs = _integer(payload['durationUs'], 'durationUs');
  final segmentsJson = payload['segments'];
  if (segmentsJson is! List<Object?>) {
    throw const FormatException('segments must be an array');
  }
  final segments = <TimelineSegment>[];
  for (final value in segmentsJson) {
    final segment = _object(value, 'segment');
    _exactKeys(segment, const {'startUs', 'endUs', 'action', 'rate', 'origin'});
    final action = _enumValue(
      segment['action'],
      SegmentAction.values,
      'action',
    );
    final origin = _enumValue(
      segment['origin'],
      SegmentOrigin.values,
      'origin',
    );
    final rate = _finiteNumber(segment['rate'], 'rate');
    if (origin != SegmentOrigin.detected ||
        (action == SegmentAction.fastForward ? rate <= 1 : rate != 1)) {
      throw const FormatException('Invalid detected segment');
    }
    segments.add(
      TimelineSegment(
        range: SourceTimeRange(
          _integer(segment['startUs'], 'startUs'),
          _integer(segment['endUs'], 'endUs'),
        ),
        action: action,
        rate: rate,
        origin: origin,
      ),
    );
  }
  return DetectedTimeline(durationUs: durationUs, segments: segments);
}

Map<String, Object?> _object(Object? value, String name) {
  if (value is! Map<String, Object?>) {
    throw FormatException('$name must be an object');
  }
  return value;
}

void _exactKeys(Map<String, Object?> value, Set<String> expected) {
  if (value.length != expected.length ||
      !value.keys.toSet().containsAll(expected)) {
    throw const FormatException('Unexpected cache fields');
  }
}

int _integer(Object? value, String name) {
  if (value is! int) throw FormatException('$name must be an integer');
  return value;
}

double _finiteNumber(Object? value, String name) {
  if (value is! num || !value.isFinite) {
    throw FormatException('$name must be finite');
  }
  return value.toDouble();
}

T _enumValue<T extends Enum>(Object? value, List<T> values, String name) {
  if (value is! String) throw FormatException('$name must be a string');
  for (final candidate in values) {
    if (candidate.name == value) return candidate;
  }
  throw FormatException('$name is invalid');
}

Future<void> _deleteBestEffort(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } on Object {
    // A disposable cache may be left for a later cleanup attempt.
  }
}
