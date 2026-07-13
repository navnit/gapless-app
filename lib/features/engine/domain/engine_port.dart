import 'package:gapless/features/editor/domain/analysis_settings.dart';
import 'package:gapless/features/engine/domain/engine_models.dart';

abstract interface class EngineTask<T> {
  Stream<EngineProgress> get progress;
  Future<T> get result;
  Future<void> cancel();
}

abstract interface class EnginePort {
  EngineTask<MediaMetadata> probe(Uri source);
  EngineTask<AnalysisLevels> levels(Uri source, AnalysisMethod method);
  EngineTask<DetectedTimeline> detect(Uri source, AnalysisSettings settings);
  EngineTask<Uri> render(RenderRequest request);
}
