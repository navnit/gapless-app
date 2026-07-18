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
          'parentSecret': Platform.environment['GAPLESS_PARENT_SECRET'],
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
    case 'long-line':
      stdout.add(List<int>.filled(int.parse(arguments[1]), 0x61));
    case 'replay-then-live':
      final preCount = int.parse(arguments[1]);
      final release = File(arguments[2]);
      final ready = File(arguments[3]);
      for (var index = 0; index < preCount; index++) {
        stdout.writeln('pre-$index');
      }
      await stdout.flush();
      ready.writeAsStringSync('ready', flush: true);
      while (!release.existsSync()) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      stdout
        ..writeln('live-0')
        ..writeln('live-1');
    case 'split-bytes':
      stdout.add([0x41, 0xe2]);
      await stdout.flush();
      stdout.add([0x82]);
      await stdout.flush();
      stdout.add([0xac, 0x0d]);
      await stdout.flush();
      stdout.add([0x0a, 0x42, 0x0a, 0x43]);
    case 'wait':
      stdout.writeln('READY');
      await stdout.flush();
      await _waitForever();
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
    case 'orphan-child':
      final child = await _startReadyChild();
      File(arguments[1]).writeAsStringSync('${child.pid}', flush: true);
      stdout.writeln('READY');
      await stdout.flush();
      final release = File(arguments[2]);
      while (!release.existsSync()) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      exit(0);
    case 'orphan-grandchild':
      final parent = await Process.start(Platform.resolvedExecutable, [
        Platform.script.toFilePath(),
        'spawn-child-and-exit',
        arguments[1],
      ], runInShell: false);
      if (await parent.exitCode != 0) {
        throw StateError('Intermediate parent failed');
      }
      stdout.writeln('READY');
      await stdout.flush();
      await _waitForever();
    case 'spawn-child-and-exit':
      final child = await _startReadyChild();
      File(arguments[1]).writeAsStringSync('${child.pid}', flush: true);
      exit(0);
    case 'exit-with-child':
      final child = await _startReadyChild();
      File(arguments[1]).writeAsStringSync('${child.pid}', flush: true);
      stdout.writeln('READY');
      await stdout.flush();
      exit(0);
    case 'spawn-child-on-term':
      final childPidFile = File(arguments[1]);
      var spawned = false;
      ProcessSignal.sigterm.watch().listen((_) async {
        if (spawned) return;
        spawned = true;
        final child = await Process.start(Platform.resolvedExecutable, [
          Platform.script.toFilePath(),
          'wait',
        ], runInShell: false);
        childPidFile.writeAsStringSync('${child.pid}', flush: true);
      });
      stdout.writeln('READY');
      await stdout.flush();
      await Completer<void>().future;
    case 'ignore-term-tree':
      final child = await Process.start(Platform.resolvedExecutable, [
        Platform.script.toFilePath(),
        'ignore-term',
      ], runInShell: false);
      await child.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first;
      File(arguments[1]).writeAsStringSync('${child.pid}', flush: true);
      ProcessSignal.sigterm.watch().listen((_) {});
      stdout.writeln('READY');
      await stdout.flush();
      await _waitForever();
    case 'ignore-term':
      ProcessSignal.sigterm.watch().listen((_) {});
      stdout.writeln('READY');
      await stdout.flush();
      await _waitForever();
    default:
      throw ArgumentError.value(arguments.first, 'mode');
  }
}

Future<void> _waitForever() async {
  final keepAlive = Timer.periodic(const Duration(hours: 1), (_) {});
  try {
    await Completer<void>().future;
  } finally {
    keepAlive.cancel();
  }
}

Future<Process> _startReadyChild() async {
  final child = await Process.start(Platform.resolvedExecutable, [
    Platform.script.toFilePath(),
    'wait',
  ], runInShell: false);
  await child.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .first;
  return child;
}
