import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/core/time/source_time_range.dart';

void main() {
  group('SourceTimeRange', () {
    test('rejects inverted, empty, and negative ranges', () {
      expect(() => SourceTimeRange(10, 9), throwsArgumentError);
      expect(() => SourceTimeRange(10, 10), throwsArgumentError);
      expect(() => SourceTimeRange(-1, 10), throwsArgumentError);
    });

    test('reports duration and clips overlaps with an intersection', () {
      final range = SourceTimeRange(0, 10);

      expect(range.durationUs, 10);
      expect(
        range.intersection(SourceTimeRange(8, 15)),
        SourceTimeRange(8, 10),
      );
    });

    test('returns no intersection for adjacent ranges', () {
      expect(
        SourceTimeRange(0, 10).intersection(SourceTimeRange(10, 15)),
        isNull,
      );
    });

    test('has value equality and matching hash codes', () {
      const startUs = 1;
      const endUs = 5;
      final first = SourceTimeRange(startUs, endUs);
      final second = SourceTimeRange(startUs, endUs);

      expect(first, second);
      expect(first.hashCode, second.hashCode);
      expect(first, isNot(SourceTimeRange(startUs, endUs + 1)));
    });
  });
}
