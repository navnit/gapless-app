import 'dart:io';

import 'package:gapless/core/process/io_process_runner.dart';
import 'package:gapless/core/time/source_time_range.dart';
import 'package:gapless/features/editor/domain/effective_timeline.dart';
import 'package:gapless/features/editor/domain/timeline_segment.dart';
import 'package:gapless/features/engine/data/auto_editor/auto_editor_adapter.dart';
import 'package:gapless/features/engine/data/auto_editor/auto_editor_locator.dart';
import 'package:gapless/features/engine/domain/engine_models.dart';
import 'package:path/path.dart' as path;

Uri absoluteSmokeTestFileUri(String argument) => File(argument).absolute.uri;

Future<void> runInstalledSmokeTest(Uri source, Uri output) async {
  final runner = IoProcessRunner();
  final engineRoot = nativeAutoEditorInstallRoot(
    resolvedExecutable: Platform.resolvedExecutable,
  );
  final temporary = await Directory.systemTemp.createTemp('gapless-smoke-');
  try {
    var sequence = 0;
    final engine = AutoEditorAdapter(
      processRunner: runner,
      executableLocator: AutoEditorLocator(
        manifestPath: path.join(engineRoot, 'manifest.json'),
        installRoot: engineRoot,
        processRunner: runner,
      ),
      temporaryPathFactory: (extension) async => Uri.file(
        path.join(temporary.path, 'operation-${sequence++}$extension'),
      ),
    );
    final metadata = await engine.probe(source).result;
    final timeline = EffectiveTimeline.compose(
      durationUs: metadata.durationUs,
      detected: <TimelineSegment>[
        TimelineSegment(
          range: SourceTimeRange(0, metadata.durationUs),
          action: SegmentAction.keep,
          origin: SegmentOrigin.detected,
        ),
      ],
      overrides: const <TimelineSegment>[],
    );
    final partial = Uri.file('${output.toFilePath()}.partial.mp4');
    await engine
        .render(
          RenderRequest(
            source: source,
            metadata: metadata,
            timeline: timeline,
            partialDestination: partial,
            preset: RenderPreset.balanced,
          ),
        )
        .result;
    await File.fromUri(partial).rename(output.toFilePath());
    final rendered = await engine.probe(output).result;
    final frameDurationUs =
        (rendered.timebaseNumerator *
                Duration.microsecondsPerSecond /
                rendered.timebaseDenominator)
            .round();
    if (!rendered.hasAudio ||
        rendered.resolution.width <= 0 ||
        (rendered.durationUs - metadata.durationUs).abs() > frameDurationUs) {
      throw StateError('Installed artifact produced invalid media.');
    }
  } finally {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  }
}
