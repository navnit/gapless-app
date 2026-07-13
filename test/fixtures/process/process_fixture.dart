import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  switch (arguments.first) {
    case 'bytes':
      stdout.add(utf8.encode('café\n'));
      stdout.add([0x62, 0x61, 0x64, 0x80, 0x62, 0x79, 0x74, 0x65, 0x0a]);
      stderr.add(utf8.encode('σφάλμα\n'));
      stderr.add([0x65, 0x72, 0x72, 0xff, 0x6f, 0x72, 0x0a]);
    case 'context':
      final output = File(arguments[1]);
      output.writeAsStringSync(
        jsonEncode({
          'workingDirectory': Directory.current.path,
          'environment': Platform.environment['GAPLESS_TEST_VALUE'],
        }),
        flush: true,
      );
    case 'fail':
      stdout.writeln('before failure');
      stderr.writeln('structured diagnostic');
      await stdout.flush();
      await stderr.flush();
      exitCode = int.parse(arguments[1]);
    case 'lines':
      for (var index = 0; index < int.parse(arguments[1]); index++) {
        stdout.writeln('stdout-$index');
        stderr.writeln('stderr-$index');
      }
    case 'wait':
      stdout.writeln('READY');
      await stdout.flush();
      await Completer<void>().future;
    case 'tree':
      final child = await Process.start(Platform.resolvedExecutable, [
        Platform.script.toFilePath(),
        'wait',
      ], runInShell: false);
      await child.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first;
      File(arguments[1]).writeAsStringSync('${child.pid}', flush: true);
      stdout.writeln('READY');
      await stdout.flush();
      await Completer<void>().future;
    default:
      throw ArgumentError.value(arguments.first, 'mode');
  }
}
