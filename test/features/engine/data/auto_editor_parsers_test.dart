import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/features/engine/data/auto_editor/auto_editor_parsers.dart';
import 'package:gapless/features/engine/domain/engine_models.dart';

void main() {
  test('parses Auto-Editor 31.2.0 machine-readable media metadata', () {
    final metadata = AutoEditorParsers.parseInfoJson(_fixtureText('info.json'));

    expect(metadata.resolution, SizeInt(1280, 720));
    expect(metadata.durationUs, 42_400_000);
    expect(metadata.timebaseNumerator, 1);
    expect(metadata.timebaseDenominator, 30);
    expect(metadata.videoCodec, 'h264');
    expect(metadata.hasAudio, isTrue);
    expect(metadata.sampleRate, 48_000);
    expect(metadata.audioLayout, 'stereo');
  });

  test('parses levels after @start into unsigned 16-bit samples', () {
    final levels = AutoEditorParsers.parseLevels(
      '\n@start\n0.0\n0.5\n1.0\n',
      samplePeriodUs: 33_367,
    );

    expect(levels.samples, [0, 32768, 65535]);
    expect(levels.samplePeriodUs, 33_367);
  });

  test('parses the complete levels fixture emitted by 31.2.0', () {
    final levels = AutoEditorParsers.parseLevels(
      _fixtureText('levels.txt'),
      samplePeriodUs: 33_333,
    );

    expect(levels.samples, hasLength(1273));
    expect(levels.samples.take(5), [2, 6, 6, 4, 176]);
    expect(levels.samples.last, 0);
  });

  test('rejects malformed and non-finite levels output', () {
    for (final output in [
      '0.5\n',
      '@start\nnan\n',
      '@start\ninfinity\n',
      '@start\n-0.1\n',
      '@start\n1.1\n',
      '@start\nnot-a-number\n',
    ]) {
      expect(
        () => AutoEditorParsers.parseLevels(output, samplePeriodUs: 1),
        throwsFormatException,
        reason: output,
      );
    }
  });

  test('rejects duplicate, missing, boolean, and non-finite info fields', () {
    final valid = _fixtureText('info.json');
    final duplicate = valid.replaceFirst(
      '"type": "media",',
      '"type": "media", "type": "media",',
    );
    final missing = valid.replaceFirst('"recommendedTimebase": "30/1",', '');
    final booleanDuration = valid.replaceFirst(
      '"duration": 42.4',
      '"duration": true',
    );
    final nonFiniteDuration = valid.replaceFirst(
      '"duration": 42.4',
      '"duration": 1e999',
    );
    final zeroTimebase = valid.replaceFirst('"30/1"', '"0/1"');

    for (final entry in <String, String>{
      'duplicate': duplicate,
      'missing': missing,
      'boolean duration': booleanDuration,
      'non-finite duration': nonFiniteDuration,
      'zero timebase': zeroTimebase,
    }.entries) {
      expect(
        () => AutoEditorParsers.parseInfoJson(entry.value),
        throwsFormatException,
        reason: entry.key,
      );
    }
  });
}

String _fixtureText(String name) =>
    File('test/fixtures/auto_editor/31.2.0/$name').readAsStringSync();
