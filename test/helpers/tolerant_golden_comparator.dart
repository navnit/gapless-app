import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

const double goldenPixelTolerance = 0.0001;

void installTolerantGoldenComparator() {
  final current = goldenFileComparator;
  if (current is! LocalFileComparator) return;
  goldenFileComparator = _TolerantGoldenFileComparator(
    current.basedir.resolve('golden_comparator_anchor.dart'),
    precisionTolerance: goldenPixelTolerance,
  );
}

final class _TolerantGoldenFileComparator extends LocalFileComparator {
  _TolerantGoldenFileComparator(
    super.testFile, {
    required double precisionTolerance,
  }) : assert(
         precisionTolerance >= 0 && precisionTolerance <= 1,
         'precisionTolerance must be between 0 and 1',
       ),
       _precisionTolerance = precisionTolerance;

  final double _precisionTolerance;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final result = await GoldenFileComparator.compareLists(
      imageBytes,
      await getGoldenBytes(golden),
    );
    if (result.passed || result.diffPercent <= _precisionTolerance) {
      result.dispose();
      return true;
    }

    final error = await generateFailureOutput(result, golden, basedir);
    result.dispose();
    throw FlutterError(error);
  }
}
