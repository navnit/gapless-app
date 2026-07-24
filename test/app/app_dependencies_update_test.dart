import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/app/app_dependencies.dart';

void main() {
  test('empty dependencies expose no update services', () {
    expect(const AppDependencies.empty().update, isNull);
  });
}
