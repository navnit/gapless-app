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

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AnalysisSettings &&
          method == other.method &&
          thresholdDb == other.thresholdDb &&
          marginBeforeUs == other.marginBeforeUs &&
          marginAfterUs == other.marginAfterUs &&
          inactiveBehavior == other.inactiveBehavior &&
          fastForwardRate == other.fastForwardRate;

  @override
  int get hashCode => Object.hash(
    method,
    thresholdDb,
    marginBeforeUs,
    marginAfterUs,
    inactiveBehavior,
    fastForwardRate,
  );
}
