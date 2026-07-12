import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/core/errors/app_failure.dart';
import 'package:gapless/features/project/data/project_codec.dart';
import 'package:gapless/features/project/domain/project_document.dart';

void main() {
  late String validJson;

  setUpAll(() {
    validJson = File(
      'test/fixtures/projects/v1_audio_cut.gapless',
    ).readAsStringSync();
  });

  group('ProjectCodec', () {
    test('round trips v1 without losing source-time decisions', () {
      final codec = ProjectCodec();
      final decoded = codec.decode(validJson);

      final again = codec.decode(codec.encode(decoded));

      expect(again, decoded);
      expect(again.schemaVersion, ProjectDocument.currentSchemaVersion);
      expect(again.detectedSegments, decoded.detectedSegments);
      expect(again.manualOverrides, decoded.manualOverrides);
    });

    test('encodes with two-space indentation and a trailing newline', () {
      final codec = ProjectCodec();

      final encoded = codec.encode(codec.decode(validJson));

      expect(encoded, endsWith('\n'));
      expect(encoded, contains('\n  "schemaVersion": 1,'));
      expect(encoded, contains('\n    "relativePath":'));
      expect(const JsonDecoder().convert(encoded), isA<Map<String, Object?>>());
    });

    test('project values use structural equality', () {
      final codec = ProjectCodec();

      expect(codec.decode(validJson), codec.decode(validJson));
      expect(
        codec.decode(validJson).hashCode,
        codec.decode(validJson).hashCode,
      );
    });

    test('rejects malformed JSON as ProjectFormatFailure', () {
      expect(
        () => ProjectCodec().decode('{'),
        throwsA(isA<ProjectFormatFailure>()),
      );
    });

    test('rejects a non-object root as ProjectFormatFailure', () {
      expect(
        () => ProjectCodec().decode('[]'),
        throwsA(isA<ProjectFormatFailure>()),
      );
    });

    test('rejects each missing required top-level key', () {
      final original = jsonDecode(validJson) as Map<String, dynamic>;

      for (final key in [
        'schemaVersion',
        'appVersion',
        'source',
        'settings',
        'detectedSegments',
        'manualOverrides',
        'ui',
      ]) {
        final changed = Map<String, dynamic>.from(original)..remove(key);
        expect(
          () => ProjectCodec().decode(jsonEncode(changed)),
          throwsA(isA<ProjectFormatFailure>()),
          reason: 'missing $key must be rejected',
        );
      }
    });

    test('rejects unsupported future schema versions', () {
      expect(
        () => ProjectCodec().decode(_with(validJson, ['schemaVersion'], 2)),
        throwsA(isA<ProjectFormatFailure>()),
      );
    });

    test('rejects non-integer source microseconds', () {
      expect(
        () => ProjectCodec().decode(
          _with(validJson, ['detectedSegments', 0, 'startUs'], 0.5),
        ),
        throwsA(isA<ProjectFormatFailure>()),
      );
    });

    test('rejects invalid segment actions', () {
      expect(
        () => ProjectCodec().decode(
          _with(validJson, ['detectedSegments', 0, 'action'], 'delete'),
        ),
        throwsA(isA<ProjectFormatFailure>()),
      );
    });

    test('rejects invalid segment rates', () {
      for (final actionAndRate in [
        ('fastForward', 1.0),
        ('fastForward', 0.0),
        ('keep', 2.0),
        ('cut', 4.0),
      ]) {
        var changed = _with(validJson, [
          'detectedSegments',
          0,
          'action',
        ], actionAndRate.$1);
        changed = _with(changed, [
          'detectedSegments',
          0,
          'rate',
        ], actionAndRate.$2);
        expect(
          () => ProjectCodec().decode(changed),
          throwsA(isA<ProjectFormatFailure>()),
          reason: '${actionAndRate.$1} at ${actionAndRate.$2} must fail',
        );
      }
    });

    test('rejects invalid analysis fast-forward rates', () {
      expect(
        () => ProjectCodec().decode(
          _with(validJson, ['settings', 'fastForwardRate'], 1.0),
        ),
        throwsA(isA<ProjectFormatFailure>()),
      );
    });

    test('does not leak TypeError, FormatException, or ArgumentError', () {
      for (final malformed in [
        _with(validJson, ['source', 'size'], 'large'),
        _with(validJson, ['source', 'modifiedAt'], 'yesterday'),
        _with(validJson, ['ui'], <Object?>[]),
        _with(validJson, ['manualOverrides', 0, 'endUs'], 0),
      ]) {
        expect(
          () => ProjectCodec().decode(malformed),
          throwsA(
            isA<ProjectFormatFailure>().having(
              (failure) => failure.reason,
              'reason',
              isNotEmpty,
            ),
          ),
        );
      }
    });
  });
}

String _with(String source, List<Object> path, Object? value) {
  final root = jsonDecode(source) as Map<String, dynamic>;
  dynamic cursor = root;
  for (final component in path.take(path.length - 1)) {
    cursor = component is int
        ? (cursor as List<dynamic>)[component]
        : (cursor as Map<String, dynamic>)[component];
  }
  final leaf = path.last;
  if (leaf is int) {
    (cursor as List<dynamic>)[leaf] = value;
  } else {
    (cursor as Map<String, dynamic>)[leaf as String] = value;
  }
  return jsonEncode(root);
}
