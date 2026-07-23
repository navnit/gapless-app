import 'dart:convert';

import 'package:gapless/core/errors/app_failure.dart';
import 'package:gapless/core/time/source_time_range.dart';
import 'package:gapless/features/editor/domain/effective_timeline.dart';
import 'package:gapless/features/editor/domain/timeline_segment.dart';
import 'package:gapless/features/engine/data/auto_editor/auto_editor_parsers.dart';
import 'package:gapless/features/engine/domain/engine_models.dart';
import 'package:path/path.dart' as p;

/// Auto-Editor 31.2.0's partially-stable v3 timeline codec.
final class V3Codec {
  DetectedTimeline decodeDetected(
    String text, {
    required int sourceDurationUs,
  }) {
    try {
      if (sourceDurationUs <= 0) {
        throw const FormatException('sourceDurationUs must be positive');
      }
      rejectDuplicateJsonKeys(text);
      final root = _map(jsonDecode(text), 'v3 root');
      _exactKeys(root, const {
        'version',
        'templateFile',
        'timebase',
        'background',
        'resolution',
        'samplerate',
        'layout',
        'langs',
        'v',
        'a',
      }, 'v3 root');
      if (root['version'] != '3') {
        throw _ContractSignal(EngineContractReason.unsupportedVersion);
      }
      final timebase = _parsePositiveRational(root['timebase'], 'timebase');
      _validateHeader(root);
      final video = _parseTracks(root['v'], 'v');
      final audio = _parseTracks(root['a'], 'a');
      if (_list(root['langs'], 'langs').length != video.length + audio.length) {
        throw const FormatException('Invalid langs count');
      }
      if (video.length > 1 || audio.length > 1) {
        throw _ContractSignal(EngineContractReason.unsupportedSources);
      }
      if (video.isNotEmpty && audio.isNotEmpty) {
        _requireMatchingBaseTracks(video.single, audio.single);
      }
      final clips = video.isNotEmpty
          ? video.single
          : audio.isNotEmpty
          ? audio.single
          : const <_Clip>[];
      _requireOneSource(video, audio);

      final tickUs = _ticksToUs(1, timebase);
      final segments = <TimelineSegment>[];
      var outputCursorTick = 0;
      final sourceClips = <_SourceClip>[];
      for (final clip in clips) {
        if (clip.start != outputCursorTick) {
          throw _ContractSignal(EngineContractReason.invalidTimeline);
        }
        outputCursorTick = _checkedAdd(clip.start, clip.duration);

        final sourceStartTick = _roundDiv(
          clip.offset * clip.rate.numerator,
          clip.rate.denominator,
        );
        final sourceEndTick = _roundDiv(
          _checkedAdd(clip.offset, clip.duration) * clip.rate.numerator,
          clip.rate.denominator,
        );
        if (sourceEndTick <= sourceStartTick) {
          throw _ContractSignal(EngineContractReason.invalidTimeline);
        }

        sourceClips.add(
          _SourceClip(
            start: sourceStartTick,
            end: sourceEndTick,
            rate: clip.rate,
          ),
        );
      }

      // Auto-Editor 31.2.0's clipBounds uses integer ceil division for speed
      // clips. A following clip's offset can therefore overlap the rounded
      // end by less than one output tick. Normalize that documented loss here.
      for (var index = 1; index < sourceClips.length; index++) {
        final previous = sourceClips[index - 1];
        final current = sourceClips[index];
        if (current.start > previous.end && current.rate.value > 1) {
          final gap = current.start - previous.end;
          final tolerance = _ceilDiv(
            current.rate.numerator,
            current.rate.denominator,
          );
          if (gap <= tolerance) current.start = previous.end;
        }
        if (current.start < previous.end) {
          final overlap = previous.end - current.start;
          if (overlap >
              _ceilDiv(previous.rate.numerator, previous.rate.denominator)) {
            throw _ContractSignal(EngineContractReason.invalidTimeline);
          }
          previous.end = current.start;
          if (previous.end <= previous.start) {
            throw _ContractSignal(EngineContractReason.invalidTimeline);
          }
        }
      }

      var sourceCursorTick = 0;
      for (final clip in sourceClips) {
        if (clip.start < sourceCursorTick) {
          throw _ContractSignal(EngineContractReason.invalidTimeline);
        }

        if (clip.start > sourceCursorTick) {
          _appendSegment(
            segments,
            _ticksToUs(sourceCursorTick, timebase),
            _ticksToUs(clip.start, timebase),
            SegmentAction.cut,
            1,
          );
        }
        _appendSegment(
          segments,
          _ticksToUs(clip.start, timebase),
          _ticksToUs(clip.end, timebase),
          clip.rate.value == 1 ? SegmentAction.keep : SegmentAction.fastForward,
          clip.rate.value,
        );
        sourceCursorTick = clip.end;
      }

      // Each speed clip rounds its source bounds with integer ceil division
      // (see the clipBounds note above), so the reconstructed source end can
      // drift past the probed duration by up to one tick per speed clip. Scale
      // the endpoint tolerance accordingly; a timeline with no speed clips
      // keeps the original single-tick bound.
      final speedClipCount = sourceClips
          .where((clip) => clip.rate.value > 1)
          .length;
      final endpointToleranceUs = _checkedInt64(tickUs * (1 + speedClipCount));
      final decodedEndUs = _ticksToUs(sourceCursorTick, timebase);
      if (decodedEndUs - sourceDurationUs > endpointToleranceUs) {
        throw _ContractSignal(EngineContractReason.invalidTimeline);
      }
      _trimEndpointWithinTick(segments, sourceDurationUs, endpointToleranceUs);
      final coveredUs = segments.isEmpty ? 0 : segments.last.range.endUs;
      if (coveredUs < sourceDurationUs) {
        _appendSegment(
          segments,
          coveredUs,
          sourceDurationUs,
          SegmentAction.cut,
          1,
        );
      }
      return DetectedTimeline(durationUs: sourceDurationUs, segments: segments);
    } on EngineContractFailure {
      rethrow;
    } on _ContractSignal catch (signal) {
      throw EngineContractFailure(
        operation: 'decode-v3',
        reason: signal.reason,
      );
    } on Object catch (error) {
      throw EngineContractFailure(
        operation: 'decode-v3',
        reason: EngineContractReason.invalidOutput,
        diagnostics: [_boundedMessage(error)],
      );
    }
  }

  String encodeEffective(
    EffectiveTimeline timeline,
    MediaMetadata metadata, {
    required Uri source,
  }) {
    try {
      if (!source.isScheme('file') ||
          !p.isAbsolute(source.toFilePath()) ||
          timeline.durationUs != metadata.durationUs) {
        throw const FormatException('Invalid v3 source or duration');
      }
      final timebase = _Rational(
        metadata.timebaseDenominator,
        metadata.timebaseNumerator,
      );
      final clips = <Map<String, Object>>[];
      var outputStartTick = 0;
      for (final segment in timeline.segments) {
        if (segment.action == SegmentAction.cut) continue;
        final rate = segment.action == SegmentAction.fastForward
            ? _rateRational(segment.rate)
            : const _Rational(1, 1);
        final sourceStartTick = _usToTicks(segment.range.startUs, timebase);
        final sourceEndTick = _usToTicks(segment.range.endUs, timebase);
        final offset = _ceilDiv(
          sourceStartTick * rate.denominator,
          rate.numerator,
        );
        final end = _ceilDiv(sourceEndTick * rate.denominator, rate.numerator);
        final duration = end - offset;
        if (duration <= 0) continue;
        final clip = <String, Object>{
          'src': source.toFilePath(),
          'start': outputStartTick,
          'dur': duration,
          'offset': offset,
          'stream': 0,
        };
        if (segment.action == SegmentAction.fastForward) {
          clip['effects'] = ['speed:${_formatRate(segment.rate)}'];
        }
        clips.add(clip);
        outputStartTick = _checkedAdd(outputStartTick, duration);
      }

      final video = clips.isEmpty ? <Object>[] : <Object>[clips];
      final audio = !metadata.hasAudio || clips.isEmpty
          ? <Object>[]
          : <Object>[
              clips.map((clip) => Map<String, Object>.from(clip)).toList(),
            ];
      final root = <String, Object>{
        'version': '3',
        'templateFile': source.toFilePath(),
        'timebase': '${timebase.numerator}/${timebase.denominator}',
        'background': '#000000',
        'resolution': [metadata.resolution.width, metadata.resolution.height],
        'samplerate': metadata.hasAudio ? metadata.sampleRate : 48000,
        'layout': metadata.hasAudio ? metadata.audioLayout : 'stereo',
        'langs': [
          if (clips.isNotEmpty) 'und',
          if (clips.isNotEmpty && metadata.hasAudio) 'und',
        ],
        'v': video,
        'a': audio,
      };
      return const JsonEncoder.withIndent('  ').convert(root);
    } on EngineContractFailure {
      rethrow;
    } on Object catch (error) {
      throw EngineContractFailure(
        operation: 'encode-v3',
        reason: EngineContractReason.invalidTimeline,
        diagnostics: [_boundedMessage(error)],
      );
    }
  }
}

void _validateHeader(Map<String, dynamic> root) {
  final template = root['templateFile'];
  if (template is! String) throw const FormatException('Invalid templateFile');
  final background = root['background'];
  if (background is! String ||
      !RegExp(r'^#[0-9a-fA-F]{3}(?:[0-9a-fA-F]{3})?$').hasMatch(background)) {
    throw const FormatException('Invalid background');
  }
  final resolution = _list(root['resolution'], 'resolution');
  if (resolution.length != 2 ||
      !_isPositiveEvenInt(resolution[0]) ||
      !_isPositiveEvenInt(resolution[1])) {
    throw const FormatException('Invalid resolution');
  }
  final samplerate = root['samplerate'];
  if (samplerate is! int || samplerate < 100) {
    throw const FormatException('Invalid samplerate');
  }
  final layout = root['layout'];
  if (layout is! String || layout.isEmpty) {
    throw const FormatException('Invalid layout');
  }
  final langs = _list(root['langs'], 'langs');
  if (langs.any((lang) => lang is! String)) {
    throw const FormatException('Invalid langs');
  }
}

List<List<_Clip>> _parseTracks(Object? value, String name) {
  final layers = _list(value, name);
  return layers
      .map((layer) {
        final nodes = _list(layer, '$name layer');
        if (nodes.isEmpty) {
          throw const FormatException('Layers must not be empty');
        }
        return nodes.map(_parseClip).toList(growable: false);
      })
      .toList(growable: false);
}

_Clip _parseClip(Object? value) {
  final map = _map(value, 'clip');
  final allowed = <String>{'src', 'start', 'dur', 'offset', 'stream'};
  if (map.containsKey('effects')) allowed.add('effects');
  _exactKeys(map, allowed, 'clip');
  final src = map['src'];
  if (src is! String || src.isEmpty) throw const FormatException('Invalid src');
  final start = _natural(map['start'], 'start');
  final duration = _positive(map['dur'], 'dur');
  final offset = _natural(map['offset'], 'offset');
  final stream = _natural(map['stream'], 'stream');
  if (stream != 0) {
    throw _ContractSignal(EngineContractReason.unsupportedSources);
  }
  var rate = const _Rational(1, 1);
  if (map['effects'] case final effects?) {
    final list = _list(effects, 'effects');
    if (list.length != 1 || list.single is! String) {
      throw _ContractSignal(EngineContractReason.invalidTimeline);
    }
    final effect = list.single as String;
    if (!effect.startsWith('speed:')) {
      throw _ContractSignal(EngineContractReason.invalidTimeline);
    }
    rate = _parseDecimalRational(effect.substring('speed:'.length), 'speed');
    if (rate.value <= 1) {
      throw _ContractSignal(EngineContractReason.invalidTimeline);
    }
  }
  return _Clip(
    source: src,
    start: start,
    duration: duration,
    offset: offset,
    rate: rate,
  );
}

void _requireMatchingBaseTracks(List<_Clip> video, List<_Clip> audio) {
  if (video.length != audio.length) {
    throw _ContractSignal(EngineContractReason.invalidTimeline);
  }
  for (var index = 0; index < video.length; index++) {
    if (video[index] != audio[index]) {
      throw _ContractSignal(EngineContractReason.invalidTimeline);
    }
  }
}

void _requireOneSource(List<List<_Clip>> video, List<List<_Clip>> audio) {
  final sources = <String>{
    for (final layer in video)
      for (final clip in layer) clip.source,
    for (final layer in audio)
      for (final clip in layer) clip.source,
  };
  if (sources.length > 1) {
    throw _ContractSignal(EngineContractReason.unsupportedSources);
  }
}

void _appendSegment(
  List<TimelineSegment> segments,
  int startUs,
  int endUs,
  SegmentAction action,
  double rate,
) {
  if (endUs <= startUs) return;
  if (segments.isNotEmpty &&
      segments.last.range.endUs == startUs &&
      segments.last.action == action &&
      segments.last.rate == rate) {
    final previous = segments.removeLast();
    segments.add(
      TimelineSegment(
        range: SourceTimeRange(previous.range.startUs, endUs),
        action: action,
        rate: rate,
        origin: SegmentOrigin.detected,
      ),
    );
    return;
  }
  segments.add(
    TimelineSegment(
      range: SourceTimeRange(startUs, endUs),
      action: action,
      rate: rate,
      origin: SegmentOrigin.detected,
    ),
  );
}

void _trimEndpointWithinTick(
  List<TimelineSegment> segments,
  int sourceDurationUs,
  int tickUs,
) {
  if (segments.isEmpty) return;
  final last = segments.last;
  if (last.range.endUs <= sourceDurationUs) return;
  if (last.range.endUs - sourceDurationUs > tickUs ||
      last.range.startUs >= sourceDurationUs) {
    throw _ContractSignal(EngineContractReason.invalidTimeline);
  }
  segments[segments.length - 1] = TimelineSegment(
    range: SourceTimeRange(last.range.startUs, sourceDurationUs),
    action: last.action,
    rate: last.rate,
    origin: SegmentOrigin.detected,
  );
}

int _ticksToUs(int ticks, _Rational timebase) => _checkedInt64(
  _roundDiv(
    ticks * timebase.denominator * Duration.microsecondsPerSecond,
    timebase.numerator,
  ),
);

int _usToTicks(int us, _Rational timebase) => _checkedInt64(
  _roundDiv(
    us * timebase.numerator,
    timebase.denominator * Duration.microsecondsPerSecond,
  ),
);

_Rational _parsePositiveRational(Object? value, String name) {
  if (value is! String) throw FormatException('Invalid $name');
  final match = RegExp(r'^(\d+)/(\d+)$').firstMatch(value);
  if (match == null) throw FormatException('Invalid $name');
  final numerator = int.parse(match.group(1)!);
  final denominator = int.parse(match.group(2)!);
  if (numerator <= 0 || denominator <= 0) {
    throw FormatException('Invalid $name');
  }
  return _Rational(numerator, denominator);
}

_Rational _parseDecimalRational(String value, String name) {
  final match = RegExp(r'^(\d+)(?:\.(\d+))?$').firstMatch(value);
  if (match == null) throw FormatException('Invalid $name');
  final fraction = match.group(2) ?? '';
  final denominator = _pow10(fraction.length);
  final numerator = int.parse('${match.group(1)}$fraction');
  if (numerator <= 0) throw FormatException('Invalid $name');
  return _Rational(numerator, denominator);
}

_Rational _rateRational(double rate) {
  if (!rate.isFinite || rate <= 1) {
    throw const FormatException('Invalid speed rate');
  }
  return _parseDecimalRational(_formatRate(rate), 'speed rate');
}

String _formatRate(double rate) {
  final value = rate.toString();
  if (value.contains('e') || value.contains('E')) {
    return rate
        .toStringAsFixed(12)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '.0');
  }
  return value.contains('.') ? value : '$value.0';
}

int _pow10(int power) {
  var result = 1;
  for (var index = 0; index < power; index++) {
    result *= 10;
  }
  return result;
}

int _roundDiv(int numerator, int denominator) {
  if (numerator < 0 || denominator <= 0) {
    throw const FormatException('Invalid rational conversion');
  }
  return (numerator + denominator ~/ 2) ~/ denominator;
}

int _ceilDiv(int numerator, int denominator) {
  if (numerator < 0 || denominator <= 0) {
    throw const FormatException('Invalid rational conversion');
  }
  return (numerator + denominator - 1) ~/ denominator;
}

int _checkedAdd(int first, int second) => _checkedInt64(first + second);

int _checkedInt64(int value) {
  const max = 0x7fffffffffffffff;
  if (value < 0 || value > max) {
    throw const FormatException('Integer conversion overflow');
  }
  return value;
}

int _natural(Object? value, String name) {
  if (value is! int || value < 0) throw FormatException('Invalid $name');
  return _checkedInt64(value);
}

int _positive(Object? value, String name) {
  final result = _natural(value, name);
  if (result == 0) throw FormatException('Invalid $name');
  return result;
}

bool _isPositiveEvenInt(Object? value) =>
    value is int && value >= 2 && value.isEven;

Map<String, dynamic> _map(Object? value, String name) {
  if (value is! Map<String, dynamic>) throw FormatException('Invalid $name');
  return value;
}

List<dynamic> _list(Object? value, String name) {
  if (value is! List<dynamic>) throw FormatException('Invalid $name');
  return value;
}

void _exactKeys(Map<String, dynamic> map, Set<String> expected, String name) {
  if (map.keys.toSet().difference(expected).isNotEmpty ||
      expected.difference(map.keys.toSet()).isNotEmpty) {
    throw FormatException('Invalid $name fields');
  }
}

String _boundedMessage(Object error) {
  final value = error.toString().replaceAll(RegExp(r'[\r\n]+'), ' ');
  return value.length <= 512 ? value : '${value.substring(0, 512)}…';
}

final class _Clip {
  const _Clip({
    required this.source,
    required this.start,
    required this.duration,
    required this.offset,
    required this.rate,
  });

  final String source;
  final int start;
  final int duration;
  final int offset;
  final _Rational rate;

  @override
  bool operator ==(Object other) =>
      other is _Clip &&
      source == other.source &&
      start == other.start &&
      duration == other.duration &&
      offset == other.offset &&
      rate == other.rate;

  @override
  int get hashCode => Object.hash(source, start, duration, offset, rate);
}

final class _SourceClip {
  _SourceClip({required this.start, required this.end, required this.rate});

  int start;
  int end;
  final _Rational rate;
}

final class _Rational {
  const _Rational(this.numerator, this.denominator);

  final int numerator;
  final int denominator;

  double get value => numerator / denominator;

  @override
  bool operator ==(Object other) =>
      other is _Rational &&
      numerator * other.denominator == other.numerator * denominator;

  @override
  int get hashCode => value.hashCode;
}

final class _ContractSignal implements Exception {
  const _ContractSignal(this.reason);

  final EngineContractReason reason;
}
