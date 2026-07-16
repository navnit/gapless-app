import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/core/time/source_time_range.dart';
import 'package:gapless/features/analysis/data/analysis_cache.dart';
import 'package:gapless/features/editor/domain/analysis_settings.dart';
import 'package:gapless/features/editor/domain/timeline_segment.dart';
import 'package:gapless/features/engine/domain/engine_models.dart';

void main() {
  group('AnalysisCacheKey', () {
    test('uses fixed canonical JSON and SHA-256 stable key', () {
      final key = _key();
      const expected =
          '{"sampledSha256":"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",'
          '"engineVersion":"31.2.0","method":"audio","thresholdDb":-19.0,'
          '"marginBeforeUs":200000,"marginAfterUs":300000,'
          '"inactiveBehavior":"cut","fastForwardRate":4.0}';

      expect(key.canonicalJson(), expected);
      expect(key.stableKey, sha256.convert(utf8.encode(expected)).toString());
    });

    test('changes for the engine version and every analysis setting', () {
      final baseline = _key().stableKey;
      final variants = [
        _key(engineVersion: '31.2.1'),
        _key(settings: _settings(method: AnalysisMethod.motion)),
        _key(settings: _settings(thresholdDb: -18)),
        _key(settings: _settings(marginBeforeUs: 200001)),
        _key(settings: _settings(marginAfterUs: 300001)),
        _key(
          settings: _settings(inactiveBehavior: InactiveBehavior.fastForward),
        ),
        _key(settings: _settings(fastForwardRate: 2.5)),
        AnalysisCacheKey(
          sampledSha256: 'e' * 64,
          engineVersion: '31.2.0',
          settings: _settings(),
        ),
      ];

      expect(
        variants.map((variant) => variant.stableKey),
        everyElement(isNot(baseline)),
      );
      expect(
        variants.map((variant) => variant.stableKey).toSet(),
        hasLength(variants.length),
      );
    });

    test('rejects malformed identity and invalid numeric settings', () {
      expect(
        () => AnalysisCacheKey(
          sampledSha256: 'not-a-hash',
          engineVersion: '31.2.0',
          settings: _settings(),
        ),
        throwsArgumentError,
      );
      expect(() => _key(engineVersion: '  '), throwsArgumentError);
      for (final threshold in [double.nan, double.infinity]) {
        expect(
          () => _key(settings: _settings(thresholdDb: threshold)),
          throwsArgumentError,
        );
      }
      expect(
        () => _key(settings: _settings(marginBeforeUs: -1)),
        throwsArgumentError,
      );
      expect(
        () => _key(settings: _settings(marginAfterUs: -1)),
        throwsArgumentError,
      );
      for (final rate in [double.nan, double.infinity, 1.0, 0.0]) {
        expect(
          () => _key(settings: _settings(fastForwardRate: rate)),
          throwsArgumentError,
        );
      }
    });
  });

  group('AnalysisCache', () {
    late Directory directory;
    late AnalysisCache cache;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('gapless-cache-test-');
      cache = AnalysisCache(directory: directory);
    });

    tearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    test('atomically round-trips levels and normalized timeline', () async {
      final levels = AnalysisLevels(
        samples: const [0, 32768, 65535],
        samplePeriodUs: 20000,
      );
      final timeline = _timeline();

      await cache.writeLevels(_key(), levels);
      await cache.writeDetectedTimeline(_key(), timeline);

      expect(await cache.readLevels(_key()), levels);
      expect(await cache.readDetectedTimeline(_key()), timeline);
      final names = directory.listSync().map((entry) => entry.path).toList();
      expect(names.where((name) => name.endsWith('.tmp')), isEmpty);
      expect(
        names.where((name) => name.endsWith('.levels.json')),
        hasLength(1),
      );
      expect(
        names.where((name) => name.endsWith('.timeline.json')),
        hasLength(1),
      );
    });

    test(
      'corrupt and wrong-key entries are deleted and become misses',
      () async {
        await cache.writeLevels(
          _key(),
          AnalysisLevels(samples: const [42], samplePeriodUs: 1000),
        );
        final levelsFile = directory.listSync().whereType<File>().singleWhere(
          (file) => file.path.endsWith('.levels.json'),
        );
        await levelsFile.writeAsString('{truncated');

        expect(await cache.readLevels(_key()), isNull);
        expect(await levelsFile.exists(), isFalse);

        await cache.writeDetectedTimeline(_key(), _timeline());
        final timelineFile = directory.listSync().whereType<File>().singleWhere(
          (file) => file.path.endsWith('.timeline.json'),
        );
        final json =
            jsonDecode(await timelineFile.readAsString())
                as Map<String, dynamic>;
        json['key'] = '0' * 64;
        await timelineFile.writeAsString(jsonEncode(json));

        expect(await cache.readDetectedTimeline(_key()), isNull);
        expect(await timelineFile.exists(), isFalse);
      },
    );

    test(
      'rejects malformed, overlapping, non-finite timeline payloads',
      () async {
        await cache.writeDetectedTimeline(_key(), _timeline());
        final file = directory.listSync().whereType<File>().singleWhere(
          (entry) => entry.path.endsWith('.timeline.json'),
        );
        final valid =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        final mutations = <void Function(Map<String, dynamic>)>[
          (root) => (root['payload'] as Map<String, dynamic>)['extra'] = true,
          (root) {
            final segments =
                ((root['payload'] as Map<String, dynamic>)['segments']
                    as List<dynamic>);
            (segments[1] as Map<String, dynamic>)['startUs'] = 100000;
          },
          (root) {
            final segments =
                ((root['payload'] as Map<String, dynamic>)['segments']
                    as List<dynamic>);
            (segments[0] as Map<String, dynamic>)['rate'] = 'NaN';
          },
          (root) {
            final segments =
                ((root['payload'] as Map<String, dynamic>)['segments']
                    as List<dynamic>);
            (segments[0] as Map<String, dynamic>)['origin'] = 'manual';
          },
        ];

        for (final mutate in mutations) {
          final changed = jsonDecode(jsonEncode(valid)) as Map<String, dynamic>;
          mutate(changed);
          await file.writeAsString(jsonEncode(changed));
          expect(await cache.readDetectedTimeline(_key()), isNull);
          expect(await file.exists(), isFalse);
          if (!identical(mutate, mutations.last)) {
            await cache.writeDetectedTimeline(_key(), _timeline());
          }
        }
      },
    );

    test(
      'concurrent writers leave one valid entry and clean temporary files',
      () async {
        final values = List.generate(
          20,
          (index) =>
              AnalysisLevels(samples: [index], samplePeriodUs: index + 1),
        );

        await Future.wait(
          values.map((value) => cache.writeLevels(_key(), value)),
        );

        expect(values, contains(await cache.readLevels(_key())));
        expect(
          directory.listSync().where((entry) => entry.path.endsWith('.tmp')),
          isEmpty,
        );
      },
    );

    test('requires an absolute cache directory', () {
      expect(
        () => AnalysisCache(directory: Directory('relative/cache')),
        throwsArgumentError,
      );
    });
  });
}

AnalysisSettings _settings({
  AnalysisMethod method = AnalysisMethod.audio,
  double thresholdDb = -19,
  int marginBeforeUs = 200000,
  int marginAfterUs = 300000,
  InactiveBehavior inactiveBehavior = InactiveBehavior.cut,
  double fastForwardRate = 4,
}) => AnalysisSettings(
  method: method,
  thresholdDb: thresholdDb,
  marginBeforeUs: marginBeforeUs,
  marginAfterUs: marginAfterUs,
  inactiveBehavior: inactiveBehavior,
  fastForwardRate: fastForwardRate,
);

AnalysisCacheKey _key({
  String engineVersion = '31.2.0',
  AnalysisSettings? settings,
}) => AnalysisCacheKey(
  sampledSha256: 'f' * 64,
  engineVersion: engineVersion,
  settings: settings ?? _settings(),
);

DetectedTimeline _timeline() => DetectedTimeline(
  durationUs: 1000000,
  segments: [
    TimelineSegment(
      range: SourceTimeRange(0, 250000),
      action: SegmentAction.keep,
      origin: SegmentOrigin.detected,
    ),
    TimelineSegment(
      range: SourceTimeRange(250000, 750000),
      action: SegmentAction.fastForward,
      rate: 2.5,
      origin: SegmentOrigin.detected,
    ),
    TimelineSegment(
      range: SourceTimeRange(750000, 1000000),
      action: SegmentAction.cut,
      origin: SegmentOrigin.detected,
    ),
  ],
);
