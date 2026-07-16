import 'dart:convert';

import 'package:gapless/features/engine/domain/engine_models.dart';

/// Parsers for the machine-readable output emitted by Auto-Editor 31.2.0.
abstract final class AutoEditorParsers {
  static MediaMetadata parseInfoJson(String text) {
    rejectDuplicateJsonKeys(text);
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic> || decoded.length != 1) {
      throw const FormatException('Expected metadata for exactly one source');
    }
    final media = _map(decoded.values.single, 'source metadata');
    if (media['type'] != 'media') {
      throw const FormatException('Expected media metadata');
    }

    final timebase = _positiveRational(
      media['recommendedTimebase'],
      'recommendedTimebase',
    );
    final video = _list(media['video'], 'video');
    if (video.length != 1) {
      throw const FormatException('Expected exactly one video stream');
    }
    final videoStream = _map(video.single, 'video stream');
    _finitePositiveNumber(videoStream['duration'], 'video.duration');
    final resolution = _list(videoStream['resolution'], 'resolution');
    if (resolution.length != 2) {
      throw const FormatException('Expected width and height');
    }

    final audio = _list(media['audio'], 'audio');
    if (audio.length > 1) {
      throw const FormatException('Expected at most one audio stream');
    }
    final audioStream = audio.isEmpty
        ? null
        : _map(audio.single, 'audio stream');
    if (audioStream != null) {
      _finitePositiveNumber(audioStream['duration'], 'audio.duration');
    }
    final container = _map(media['container'], 'container');
    final durationSeconds = _finitePositiveNumber(
      container['duration'],
      'container.duration',
    );
    final durationUs = (durationSeconds * Duration.microsecondsPerSecond)
        .round();

    try {
      return MediaMetadata(
        durationUs: durationUs,
        // Auto-Editor's rational is ticks/second. The domain stores seconds/tick.
        timebaseNumerator: timebase.$2,
        timebaseDenominator: timebase.$1,
        resolution: SizeInt(
          _positiveInt(resolution[0], 'resolution width'),
          _positiveInt(resolution[1], 'resolution height'),
        ),
        videoCodec: _nonEmptyString(videoStream['codec'], 'video codec'),
        hasAudio: audioStream != null,
        sampleRate: audioStream == null
            ? 0
            : _positiveInt(audioStream['samplerate'], 'samplerate'),
        audioLayout: audioStream == null
            ? ''
            : _nonEmptyString(audioStream['layout'], 'audio layout'),
      );
    } on ArgumentError catch (error) {
      throw FormatException('Invalid media metadata: $error');
    }
  }

  static AnalysisLevels parseLevels(
    String text, {
    required int samplePeriodUs,
  }) {
    if (samplePeriodUs <= 0) {
      throw const FormatException('samplePeriodUs must be positive');
    }
    final lines = const LineSplitter().convert(text);
    var index = 0;
    while (index < lines.length && lines[index].trim().isEmpty) {
      index++;
    }
    if (index == lines.length || lines[index].trim() != '@start') {
      throw const FormatException('Expected @start levels header');
    }

    final samples = <int>[];
    for (index++; index < lines.length; index++) {
      final line = lines[index].trim();
      if (line.isEmpty) continue;
      final value = double.tryParse(line);
      if (value == null || !value.isFinite || value < 0 || value > 1) {
        throw FormatException('Invalid Auto-Editor level: $line');
      }
      samples.add((value * 65535).round());
    }
    return AnalysisLevels(samples: samples, samplePeriodUs: samplePeriodUs);
  }
}

/// Ensures duplicate object fields cannot be hidden by [jsonDecode]'s last-key
/// behavior. The normal decoder still performs value decoding after this pass.
void rejectDuplicateJsonKeys(String text) => _JsonKeyGuard(text).parse();

Map<String, dynamic> _map(Object? value, String name) {
  if (value is! Map<String, dynamic>) {
    throw FormatException('Expected $name to be an object');
  }
  return value;
}

List<dynamic> _list(Object? value, String name) {
  if (value is! List<dynamic>) {
    throw FormatException('Expected $name to be an array');
  }
  return value;
}

(int, int) _positiveRational(Object? value, String name) {
  if (value is! String) throw FormatException('Expected $name rational');
  final match = RegExp(r'^(\d+)/(\d+)$').firstMatch(value);
  if (match == null) throw FormatException('Expected $name rational');
  final numerator = int.parse(match.group(1)!);
  final denominator = int.parse(match.group(2)!);
  if (numerator <= 0 || denominator <= 0) {
    throw FormatException('Expected positive $name rational');
  }
  return (numerator, denominator);
}

int _positiveInt(Object? value, String name) {
  if (value is! int || value <= 0) {
    throw FormatException('Expected positive integer $name');
  }
  return value;
}

double _finitePositiveNumber(Object? value, String name) {
  if (value is! num || !value.isFinite || value <= 0) {
    throw FormatException('Expected positive finite number $name');
  }
  return value.toDouble();
}

String _nonEmptyString(Object? value, String name) {
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('Expected non-empty $name');
  }
  return value;
}

final class _JsonKeyGuard {
  _JsonKeyGuard(this.source);

  final String source;
  var offset = 0;

  void parse() {
    _value();
    _space();
    if (offset != source.length) {
      throw FormatException('Unexpected JSON content', source, offset);
    }
  }

  void _value() {
    _space();
    if (offset >= source.length) {
      throw FormatException('Unexpected end of JSON', source, offset);
    }
    switch (source.codeUnitAt(offset)) {
      case 0x7b: // {
        _object();
      case 0x5b: // [
        _array();
      case 0x22: // "
        _string();
      case 0x74: // t
        _literal('true');
      case 0x66: // f
        _literal('false');
      case 0x6e: // n
        _literal('null');
      default:
        _number();
    }
  }

  void _object() {
    offset++;
    _space();
    final keys = <String>{};
    if (_consume(0x7d)) return;
    while (true) {
      _space();
      if (offset >= source.length || source.codeUnitAt(offset) != 0x22) {
        throw FormatException('Expected JSON object key', source, offset);
      }
      final key = _string();
      if (!keys.add(key)) {
        throw FormatException('Duplicate JSON key: $key', source, offset);
      }
      _space();
      _expect(0x3a);
      _value();
      _space();
      if (_consume(0x7d)) return;
      _expect(0x2c);
    }
  }

  void _array() {
    offset++;
    _space();
    if (_consume(0x5d)) return;
    while (true) {
      _value();
      _space();
      if (_consume(0x5d)) return;
      _expect(0x2c);
    }
  }

  String _string() {
    final start = offset;
    offset++;
    var escaped = false;
    while (offset < source.length) {
      final unit = source.codeUnitAt(offset++);
      if (!escaped && unit == 0x22) {
        return jsonDecode(source.substring(start, offset)) as String;
      }
      if (!escaped && unit == 0x5c) {
        escaped = true;
      } else {
        escaped = false;
      }
    }
    throw FormatException('Unterminated JSON string', source, start);
  }

  void _literal(String literal) {
    if (!source.startsWith(literal, offset)) {
      throw FormatException('Invalid JSON literal', source, offset);
    }
    offset += literal.length;
  }

  void _number() {
    final match = RegExp(
      r'-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?',
    ).matchAsPrefix(source, offset);
    if (match == null) {
      throw FormatException('Invalid JSON value', source, offset);
    }
    offset = match.end;
  }

  void _space() {
    while (offset < source.length) {
      final unit = source.codeUnitAt(offset);
      if (unit != 0x20 && unit != 0x09 && unit != 0x0a && unit != 0x0d) {
        return;
      }
      offset++;
    }
  }

  bool _consume(int unit) {
    if (offset < source.length && source.codeUnitAt(offset) == unit) {
      offset++;
      return true;
    }
    return false;
  }

  void _expect(int unit) {
    if (!_consume(unit)) {
      throw FormatException('Unexpected JSON token', source, offset);
    }
  }
}
