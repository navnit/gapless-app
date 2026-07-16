import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/features/engine/data/auto_editor/auto_editor_output_collector.dart';

void main() {
  test('discard mode retains only bounded streaming diagnostics', () {
    final collector = AutoEditorOutputCollector(retainStdout: false);

    for (var index = 0; index < 100; index++) {
      collector.addStdout('stdout-$index-${'x' * 300}');
    }
    collector.addStderr('fatal engine error');

    expect(collector.stdout, isEmpty);
    expect(collector.diagnostics, contains('fatal engine error'));
    expect(collector.diagnostics, hasLength(lessThanOrEqualTo(40)));
    expect(collector.diagnostics.join().length, lessThanOrEqualTo(8192));
  });

  test('machine-readable mode preserves complete stdout', () {
    final collector = AutoEditorOutputCollector(retainStdout: true);

    collector
      ..addStdout('{')
      ..addStdout('  "version": 3')
      ..addStdout('}');

    expect(collector.stdout, '{\n  "version": 3\n}');
  });
}
