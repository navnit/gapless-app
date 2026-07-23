import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/core/errors/app_failure.dart';
import 'package:gapless/core/time/source_time_range.dart';
import 'package:gapless/features/editor/domain/effective_timeline.dart';
import 'package:gapless/features/editor/domain/timeline_segment.dart';
import 'package:gapless/features/engine/data/auto_editor/v3_codec.dart';
import 'package:gapless/features/engine/domain/engine_models.dart';

void main() {
  test('decodes real 31.2.0 v3 and reconstructs every omitted gap', () {
    final timeline = V3Codec().decodeDetected(
      _fixtureText('detected.v3'),
      sourceDurationUs: 42_400_000,
    );

    expect(timeline.durationUs, 42_400_000);
    expect(timeline.segments, [
      _segment(0, _tickUs(23), SegmentAction.keep),
      _segment(_tickUs(23), _tickUs(35), SegmentAction.cut),
      _segment(_tickUs(35), _tickUs(394), SegmentAction.keep),
      _segment(_tickUs(394), _tickUs(411), SegmentAction.cut),
      _segment(_tickUs(411), _tickUs(521), SegmentAction.keep),
      _segment(_tickUs(521), _tickUs(1196), SegmentAction.cut),
      _segment(_tickUs(1196), _tickUs(1219), SegmentAction.keep),
      _segment(_tickUs(1219), 42_400_000, SegmentAction.cut),
    ]);
  });

  test('encodes and decodes keep, cut, and speed within one rational tick', () {
    final metadata = _metadata(
      durationUs: 4_000_000,
      timebaseNumerator: 1001,
      timebaseDenominator: 30_000,
    );
    final timeline = EffectiveTimeline.compose(
      durationUs: metadata.durationUs,
      detected: [
        _segment(0, 1_000_000, SegmentAction.keep),
        _segment(1_000_000, 1_500_000, SegmentAction.cut),
        _segment(1_500_000, 3_000_000, SegmentAction.fastForward, rate: 4),
        _segment(3_000_000, 4_000_000, SegmentAction.keep),
      ],
      overrides: const [],
    );

    final encoded = V3Codec().encodeEffective(
      timeline,
      metadata,
      source: Uri.file('/absolute/source.mp4'),
    );
    late final DetectedTimeline decoded;
    try {
      decoded = V3Codec().decodeDetected(
        encoded,
        sourceDurationUs: timeline.durationUs,
      );
    } on EngineContractFailure catch (failure) {
      fail('decode failed: ${failure.reason} ${failure.diagnostics}\n$encoded');
    }
    final json = jsonDecode(encoded) as Map<String, dynamic>;

    expect(json['version'], '3');
    expect(json['timebase'], '30000/1001');
    expect(jsonEncode(json), isNot(contains('"cut"')));
    expect(jsonEncode(json), contains('speed:4.0'));
    _expectEquivalentWithinTick(
      decoded.segments,
      timeline.segments,
      tickUs: _frameDurationUs(metadata),
    );
  });

  test('decodes leading, interior, trailing, and all-cut gaps', () {
    final withGaps = _minimalV3([
      _clip(start: 0, duration: 5, offset: 3),
      _clip(start: 5, duration: 5, offset: 12),
    ]);
    final decoded = V3Codec().decodeDetected(
      jsonEncode(withGaps),
      sourceDurationUs: _tickUs(20),
    );

    expect(decoded.segments, [
      _segment(0, _tickUs(3), SegmentAction.cut),
      _segment(_tickUs(3), _tickUs(8), SegmentAction.keep),
      _segment(_tickUs(8), _tickUs(12), SegmentAction.cut),
      _segment(_tickUs(12), _tickUs(17), SegmentAction.keep),
      _segment(_tickUs(17), _tickUs(20), SegmentAction.cut),
    ]);

    final allCut = V3Codec().decodeDetected(
      jsonEncode(_minimalV3(const [])),
      sourceDurationUs: _tickUs(20),
    );
    expect(allCut.segments, [_segment(0, _tickUs(20), SegmentAction.cut)]);
  });

  test(
    'round trips a validated non-integer speed with scaled tick tolerance',
    () {
      final metadata = _metadata(
        durationUs: 3_000_000,
        timebaseNumerator: 1001,
        timebaseDenominator: 30_000,
      );
      final timeline = EffectiveTimeline.compose(
        durationUs: metadata.durationUs,
        detected: [
          _segment(0, 700_000, SegmentAction.keep),
          _segment(700_000, 2_400_000, SegmentAction.fastForward, rate: 2.5),
          _segment(2_400_000, 3_000_000, SegmentAction.keep),
        ],
        overrides: const [],
      );

      final decoded = V3Codec().decodeDetected(
        V3Codec().encodeEffective(
          timeline,
          metadata,
          source: Uri.file('/absolute/non-integer.mp4'),
        ),
        sourceDurationUs: timeline.durationUs,
      );

      _expectEquivalentWithinTick(
        decoded.segments,
        timeline.segments,
        tickUs: _frameDurationUs(metadata),
      );
    },
  );

  test('clamps only a one-tick endpoint rounding difference', () {
    final withinTick = V3Codec().decodeDetected(
      jsonEncode(_minimalV3([_clip(start: 0, duration: 10, offset: 0)])),
      sourceDurationUs: 320_000,
    );
    expect(withinTick.segments.last.range.endUs, 320_000);

    expect(
      () => V3Codec().decodeDetected(
        jsonEncode(_minimalV3([_clip(start: 0, duration: 10, offset: 0)])),
        sourceDurationUs: 250_000,
      ),
      throwsA(_isInvalidTimeline),
    );
  });

  test('scales the endpoint tolerance by the speed-clip count', () {
    // Auto-Editor 31.2.0 rounds speed-clip source bounds with integer ceil
    // division, so each speed clip can push the reconstructed source end past
    // the probed duration by up to one tick. A single speed clip must therefore
    // absorb sub-two-tick drift by clamping, not reject it. (timebase 30/1 ->
    // one tick == 33_333us; the clip ends at 30 ticks == 1_000_000us.)
    final oneSpeedClip = _minimalV3([
      (_clip(start: 0, duration: 10, offset: 0)
        ..['effects'] = <Object>['speed:3.0']),
    ]);

    final clamped = V3Codec().decodeDetected(
      jsonEncode(oneSpeedClip),
      sourceDurationUs: 950_000, // overshoot 50_000us ~= 1.5 ticks
    );
    expect(clamped.segments.single.action, SegmentAction.fastForward);
    expect(clamped.segments.last.range.endUs, 950_000);

    // Drift beyond the scaled tolerance is still a genuine contract violation.
    expect(
      () => V3Codec().decodeDetected(
        jsonEncode(oneSpeedClip),
        sourceDurationUs: 920_000, // overshoot 80_000us ~= 2.4 ticks
      ),
      throwsA(_isInvalidTimeline),
    );
  });

  test('rejects overlaps, extra layers, and multiple sources structurally', () {
    final overlap = _minimalV3([
      _clip(start: 0, duration: 10, offset: 0),
      _clip(start: 10, duration: 10, offset: 5),
    ]);
    final extraLayer = _minimalV3([_clip(start: 0, duration: 10, offset: 0)]);
    (extraLayer['v'] as List<Object?>).add([
      _clip(start: 0, duration: 10, offset: 0),
    ]);
    final multipleSources = _minimalV3([
      _clip(start: 0, duration: 10, offset: 0),
      _clip(start: 10, duration: 10, offset: 10, source: 'other.mp4'),
    ]);

    for (final value in [overlap, extraLayer, multipleSources]) {
      expect(
        () => V3Codec().decodeDetected(
          jsonEncode(value),
          sourceDurationUs: _tickUs(30),
        ),
        throwsA(isA<EngineContractFailure>()),
      );
    }
  });

  test(
    'rejects invalid rationals, numeric traps, and incomplete structure',
    () {
      final invalidValues = <Map<String, Object?>>[];
      for (final timebase in ['30/0', '30/-1', '0/1']) {
        invalidValues.add(
          _minimalV3([_clip(start: 0, duration: 10, offset: 0)])
            ..['timebase'] = timebase,
        );
      }
      invalidValues.add(
        _minimalV3([_clip(start: 0, duration: 10, offset: 0)..['dur'] = true]),
      );
      invalidValues.add(
        _minimalV3([_clip(start: 0, duration: 10, offset: 0)])
          ..['langs'] = <Object>[],
      );

      for (final value in invalidValues) {
        expect(
          () => V3Codec().decodeDetected(
            jsonEncode(value),
            sourceDurationUs: _tickUs(30),
          ),
          throwsA(isA<EngineContractFailure>()),
        );
      }
    },
  );

  test('rejects integer conversion overflow structurally', () {
    const maxInt64 = 0x7fffffffffffffff;
    final value = _minimalV3([
      _clip(start: 0, duration: maxInt64, offset: maxInt64),
    ]);

    expect(
      () => V3Codec().decodeDetected(
        jsonEncode(value),
        sourceDurationUs: 1_000_000,
      ),
      throwsA(isA<EngineContractFailure>()),
    );
  });
}

Map<String, Object?> _minimalV3(List<Map<String, Object?>> clips) => {
  'version': '3',
  'templateFile': 'source.mp4',
  'timebase': '30/1',
  'background': '#000000',
  'resolution': [1920, 1080],
  'samplerate': 48000,
  'layout': 'stereo',
  'langs': clips.isEmpty ? <Object>[] : ['und'],
  'v': clips.isEmpty ? <Object>[] : <Object>[clips],
  'a': <Object>[],
};

Map<String, Object?> _clip({
  required int start,
  required int duration,
  required int offset,
  String source = 'source.mp4',
}) => {
  'src': source,
  'start': start,
  'dur': duration,
  'offset': offset,
  'stream': 0,
};

MediaMetadata _metadata({
  required int durationUs,
  required int timebaseNumerator,
  required int timebaseDenominator,
}) => MediaMetadata(
  durationUs: durationUs,
  timebaseNumerator: timebaseNumerator,
  timebaseDenominator: timebaseDenominator,
  resolution: SizeInt(1920, 1080),
  videoCodec: 'h264',
  hasAudio: true,
  sampleRate: 48_000,
  audioLayout: 'stereo',
);

TimelineSegment _segment(
  int startUs,
  int endUs,
  SegmentAction action, {
  double rate = 1,
}) => TimelineSegment(
  range: SourceTimeRange(startUs, endUs),
  action: action,
  rate: rate,
  origin: SegmentOrigin.detected,
);

int _tickUs(int tick) => (tick * 1000000 / 30).round();

int _frameDurationUs(MediaMetadata metadata) =>
    (metadata.timebaseNumerator * 1000000 / metadata.timebaseDenominator)
        .ceil();

void _expectEquivalentWithinTick(
  List<TimelineSegment> actual,
  List<TimelineSegment> expected, {
  required int tickUs,
}) {
  expect(actual, hasLength(expected.length));
  for (var index = 0; index < expected.length; index++) {
    expect(actual[index].action, expected[index].action);
    expect(actual[index].rate, closeTo(expected[index].rate, 1e-12));
    final startRate = <double>[
      expected[index].rate,
      if (index > 0) expected[index - 1].rate,
    ].reduce((first, second) => first > second ? first : second);
    final endRate = <double>[
      expected[index].rate,
      if (index + 1 < expected.length) expected[index + 1].rate,
    ].reduce((first, second) => first > second ? first : second);
    expect(
      (actual[index].range.startUs - expected[index].range.startUs).abs(),
      lessThanOrEqualTo(tickUs * startRate.ceil()),
    );
    expect(
      (actual[index].range.endUs - expected[index].range.endUs).abs(),
      lessThanOrEqualTo(tickUs * endRate.ceil()),
    );
  }
}

String _fixtureText(String name) =>
    File('test/fixtures/auto_editor/31.2.0/$name').readAsStringSync();

Matcher get _isInvalidTimeline => isA<EngineContractFailure>().having(
  (failure) => failure.reason,
  'reason',
  EngineContractReason.invalidTimeline,
);
