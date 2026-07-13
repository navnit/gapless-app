import 'package:collection/collection.dart';
import 'package:gapless/features/editor/domain/effective_timeline.dart';
import 'package:gapless/features/editor/domain/timeline_segment.dart';

final class SizeInt {
  SizeInt(this.width, this.height) {
    if (width <= 0) throw RangeError.value(width, 'width');
    if (height <= 0) throw RangeError.value(height, 'height');
  }

  final int width;
  final int height;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SizeInt && width == other.width && height == other.height;

  @override
  int get hashCode => Object.hash(width, height);
}

final class MediaMetadata {
  MediaMetadata({
    required this.durationUs,
    required this.timebaseNumerator,
    required this.timebaseDenominator,
    required this.resolution,
    required this.videoCodec,
    required this.hasAudio,
    required this.sampleRate,
    required this.audioLayout,
  }) {
    if (durationUs <= 0) throw RangeError.value(durationUs, 'durationUs');
    if (timebaseNumerator <= 0) {
      throw RangeError.value(timebaseNumerator, 'timebaseNumerator');
    }
    if (timebaseDenominator <= 0) {
      throw RangeError.value(timebaseDenominator, 'timebaseDenominator');
    }
    if (videoCodec.trim().isEmpty) {
      throw ArgumentError.value(videoCodec, 'videoCodec');
    }
    if (hasAudio) {
      if (sampleRate <= 0) throw RangeError.value(sampleRate, 'sampleRate');
      if (audioLayout.trim().isEmpty) {
        throw ArgumentError.value(audioLayout, 'audioLayout');
      }
    } else if (sampleRate != 0 || audioLayout.isNotEmpty) {
      throw ArgumentError(
        'Media without audio must use sampleRate 0 and an empty audioLayout',
      );
    }
  }

  final int durationUs;
  final int timebaseNumerator;
  final int timebaseDenominator;
  final SizeInt resolution;
  final String videoCodec;
  final bool hasAudio;
  final int sampleRate;
  final String audioLayout;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MediaMetadata &&
          durationUs == other.durationUs &&
          timebaseNumerator == other.timebaseNumerator &&
          timebaseDenominator == other.timebaseDenominator &&
          resolution == other.resolution &&
          videoCodec == other.videoCodec &&
          hasAudio == other.hasAudio &&
          sampleRate == other.sampleRate &&
          audioLayout == other.audioLayout;

  @override
  int get hashCode => Object.hash(
    durationUs,
    timebaseNumerator,
    timebaseDenominator,
    resolution,
    videoCodec,
    hasAudio,
    sampleRate,
    audioLayout,
  );
}

final class AnalysisLevels {
  AnalysisLevels({required List<int> samples, required this.samplePeriodUs})
    : samples = List.unmodifiable(_validateSamples(samples)) {
    if (samplePeriodUs <= 0) {
      throw ArgumentError.value(samplePeriodUs, 'samplePeriodUs');
    }
  }

  final List<int> samples;
  final int samplePeriodUs;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AnalysisLevels &&
          samplePeriodUs == other.samplePeriodUs &&
          const ListEquality<int>().equals(samples, other.samples);

  @override
  int get hashCode =>
      Object.hash(const ListEquality<int>().hash(samples), samplePeriodUs);
}

final class DetectedTimeline {
  DetectedTimeline({
    required this.durationUs,
    required List<TimelineSegment> segments,
  }) : segments = List.unmodifiable(_validateSegments(durationUs, segments));

  final int durationUs;
  final List<TimelineSegment> segments;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DetectedTimeline &&
          durationUs == other.durationUs &&
          const ListEquality<TimelineSegment>().equals(
            segments,
            other.segments,
          );

  @override
  int get hashCode => Object.hash(
    durationUs,
    const ListEquality<TimelineSegment>().hash(segments),
  );
}

enum RenderPreset { smaller, balanced, higherQuality }

final class RenderRequest {
  RenderRequest({
    required this.source,
    required this.metadata,
    required this.timeline,
    required this.partialDestination,
    required this.preset,
  }) {
    if (!source.isScheme('file')) {
      throw ArgumentError.value(source, 'source');
    }
    if (!partialDestination.isScheme('file')) {
      throw ArgumentError.value(partialDestination, 'partialDestination');
    }
    if (timeline.durationUs != metadata.durationUs) {
      throw ArgumentError.value(timeline.durationUs, 'timeline');
    }
  }

  final Uri source;
  final MediaMetadata metadata;
  final EffectiveTimeline timeline;
  final Uri partialDestination;
  final RenderPreset preset;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RenderRequest &&
          source == other.source &&
          metadata == other.metadata &&
          _timelinesEqual(timeline, other.timeline) &&
          partialDestination == other.partialDestination &&
          preset == other.preset;

  @override
  int get hashCode => Object.hash(
    source,
    metadata,
    timeline.durationUs,
    const ListEquality<TimelineSegment>().hash(timeline.segments),
    partialDestination,
    preset,
  );
}

enum EngineStage { probing, analyzing, buildingTimeline, rendering, writing }

final class EngineProgress {
  EngineProgress({required this.stage, this.percent, this.eta}) {
    final percent = this.percent;
    if (percent != null &&
        (!percent.isFinite || percent < 0 || percent > 100)) {
      throw RangeError.range(percent, 0, 100, 'percent');
    }
    if (eta?.isNegative ?? false) {
      throw ArgumentError.value(eta, 'eta');
    }
  }

  final EngineStage stage;
  final double? percent;
  final Duration? eta;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EngineProgress &&
          stage == other.stage &&
          percent == other.percent &&
          eta == other.eta;

  @override
  int get hashCode => Object.hash(stage, percent, eta);
}

List<int> _validateSamples(List<int> samples) {
  for (final sample in samples) {
    if (sample < 0 || sample > 65535) {
      throw RangeError.range(sample, 0, 65535, 'samples');
    }
  }
  return samples;
}

List<TimelineSegment> _validateSegments(
  int durationUs,
  List<TimelineSegment> segments,
) {
  if (durationUs <= 0) throw ArgumentError.value(durationUs, 'durationUs');
  var previousEndUs = 0;
  for (final segment in segments) {
    if (segment.range.endUs > durationUs ||
        segment.range.startUs < previousEndUs) {
      throw ArgumentError.value(segment, 'segments');
    }
    previousEndUs = segment.range.endUs;
  }
  return segments;
}

bool _timelinesEqual(EffectiveTimeline first, EffectiveTimeline second) =>
    first.durationUs == second.durationUs &&
    const ListEquality<TimelineSegment>().equals(
      first.segments,
      second.segments,
    );
