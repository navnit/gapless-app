import 'dart:math';

final class SourceTimeRange {
  SourceTimeRange(this.startUs, this.endUs) {
    if (startUs < 0 || endUs <= startUs) {
      throw ArgumentError.value([startUs, endUs]);
    }
  }

  final int startUs;
  final int endUs;

  int get durationUs => endUs - startUs;

  SourceTimeRange? intersection(SourceTimeRange other) {
    final start = max(startUs, other.startUs);
    final end = min(endUs, other.endUs);
    return start < end ? SourceTimeRange(start, end) : null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SourceTimeRange &&
          startUs == other.startUs &&
          endUs == other.endUs;

  @override
  int get hashCode => Object.hash(startUs, endUs);

  @override
  String toString() => 'SourceTimeRange($startUs, $endUs)';
}
