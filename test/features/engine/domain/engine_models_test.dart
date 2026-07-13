import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/core/errors/app_failure.dart';
import 'package:gapless/core/time/source_time_range.dart';
import 'package:gapless/features/editor/domain/effective_timeline.dart';
import 'package:gapless/features/editor/domain/timeline_segment.dart';
import 'package:gapless/features/engine/domain/engine_models.dart';

void main() {
  test('engine values use structural equality and stable hash codes', () {
    final first = _values();
    final second = _values();

    expect(first.size, second.size);
    expect(first.metadata, second.metadata);
    expect(first.levels, second.levels);
    expect(first.detected, second.detected);
    expect(first.render, second.render);
    expect(first.progress, second.progress);
    expect(first.hashCodes, second.hashCodes);
  });

  test('engine collection values are defensive and immutable', () {
    final samples = <int>[0, 65535];
    final segments = <TimelineSegment>[_segment()];

    final levels = AnalysisLevels(samples: samples, samplePeriodUs: 20_000);
    final timeline = DetectedTimeline(
      durationUs: 1_000_000,
      segments: segments,
    );
    samples[0] = 10;
    segments.clear();

    expect(levels.samples, [0, 65535]);
    expect(timeline.segments, [_segment()]);
    expect(() => levels.samples.add(1), throwsUnsupportedError);
    expect(() => timeline.segments.clear(), throwsUnsupportedError);
  });

  test('rejects invalid sizes, metadata, samples, timelines, and progress', () {
    expect(() => SizeInt(0, 1080), throwsArgumentError);
    expect(() => _metadata(durationUs: 0), throwsArgumentError);
    expect(() => _metadata(timebaseDenominator: 0), throwsArgumentError);
    expect(
      () => AnalysisLevels(samples: const [-1], samplePeriodUs: 1),
      throwsRangeError,
    );
    expect(
      () => AnalysisLevels(samples: const [65536], samplePeriodUs: 1),
      throwsRangeError,
    );
    expect(
      () => AnalysisLevels(samples: const [], samplePeriodUs: 0),
      throwsArgumentError,
    );
    expect(
      () => DetectedTimeline(durationUs: 500_000, segments: [_segment()]),
      throwsArgumentError,
    );
    expect(
      () => EngineProgress(stage: EngineStage.rendering, percent: -1),
      throwsRangeError,
    );
    expect(
      () => EngineProgress(stage: EngineStage.rendering, percent: 101),
      throwsRangeError,
    );
    expect(
      () => EngineProgress(stage: EngineStage.rendering, percent: double.nan),
      throwsRangeError,
    );
    expect(
      () => EngineProgress(
        stage: EngineStage.rendering,
        eta: const Duration(microseconds: -1),
      ),
      throwsArgumentError,
    );
  });

  test('engine failures expose structured immutable details', () {
    final diagnostics = <String>['line one', 'line two'];
    final failure = EngineContractFailure(
      operation: 'probe',
      reason: EngineContractReason.invalidOutput,
      exitCode: 7,
      diagnostics: diagnostics,
    );
    diagnostics.clear();

    expect(failure.operation, 'probe');
    expect(failure.reason, EngineContractReason.invalidOutput);
    expect(failure.exitCode, 7);
    expect(failure.diagnostics, ['line one', 'line two']);
    expect(() => failure.diagnostics.add('mutate'), throwsUnsupportedError);
    expect(const OperationCancelled(operation: 'render').operation, 'render');
  });

  test('structured failure byte counts reject negative runtime values', () {
    expect(() => DiskFullFailure(requiredBytes: -1), throwsRangeError);
    expect(() => DiskFullFailure(availableBytes: -1), throwsRangeError);
  });
}

({
  SizeInt size,
  MediaMetadata metadata,
  AnalysisLevels levels,
  DetectedTimeline detected,
  RenderRequest render,
  EngineProgress progress,
  List<int> hashCodes,
})
_values() {
  final size = SizeInt(1920, 1080);
  final metadata = _metadata();
  final levels = AnalysisLevels(
    samples: const [0, 32768, 65535],
    samplePeriodUs: 20_000,
  );
  final detected = DetectedTimeline(
    durationUs: 1_000_000,
    segments: [_segment()],
  );
  final render = RenderRequest(
    source: Uri.file('/source/video.mp4'),
    metadata: metadata,
    timeline: EffectiveTimeline.compose(
      durationUs: 1_000_000,
      detected: [_segment()],
      overrides: const [],
    ),
    partialDestination: Uri.file('/exports/video.partial.mp4'),
    preset: RenderPreset.balanced,
  );
  final progress = EngineProgress(
    stage: EngineStage.rendering,
    percent: 42.5,
    eta: const Duration(seconds: 10),
  );
  return (
    size: size,
    metadata: metadata,
    levels: levels,
    detected: detected,
    render: render,
    progress: progress,
    hashCodes: [
      size.hashCode,
      metadata.hashCode,
      levels.hashCode,
      detected.hashCode,
      render.hashCode,
      progress.hashCode,
    ],
  );
}

MediaMetadata _metadata({
  int durationUs = 1_000_000,
  int timebaseDenominator = 30_000,
}) => MediaMetadata(
  durationUs: durationUs,
  timebaseNumerator: 1001,
  timebaseDenominator: timebaseDenominator,
  resolution: SizeInt(1920, 1080),
  videoCodec: 'h264',
  hasAudio: true,
  sampleRate: 48_000,
  audioLayout: 'stereo',
);

TimelineSegment _segment() => TimelineSegment(
  range: SourceTimeRange(0, 1_000_000),
  action: SegmentAction.keep,
  origin: SegmentOrigin.detected,
);
