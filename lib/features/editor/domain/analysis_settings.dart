enum AnalysisMethod { audio, motion }

enum InactiveBehavior { cut, fastForward }

final class AnalysisSettings {
  const AnalysisSettings({
    required this.method,
    required this.thresholdDb,
    required this.marginBeforeUs,
    required this.marginAfterUs,
    required this.inactiveBehavior,
    this.fastForwardRate = 4.0,
  });

  final AnalysisMethod method;
  final double thresholdDb;
  final int marginBeforeUs;
  final int marginAfterUs;
  final InactiveBehavior inactiveBehavior;
  final double fastForwardRate;
}
