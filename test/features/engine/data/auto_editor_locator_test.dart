import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/core/errors/app_failure.dart';
import 'package:gapless/core/process/process_runner.dart';
import 'package:gapless/features/engine/data/auto_editor/auto_editor_locator.dart';

void main() {
  group('nativeAutoEditorInstallRoot', () {
    test('uses deterministic native bundle layouts', () {
      expect(
        nativeAutoEditorInstallRoot(
          resolvedExecutable:
              '/Applications/Gapless.app/Contents/MacOS/gapless',
          operatingSystem: 'macos',
        ),
        '/Applications/Gapless.app/Contents/Resources/engine',
      );
      expect(
        nativeAutoEditorInstallRoot(
          resolvedExecutable: r'C:\Program Files\Gapless\gapless.exe',
          operatingSystem: 'windows',
        ),
        r'C:\Program Files\Gapless\engine',
      );
      expect(
        nativeAutoEditorInstallRoot(
          resolvedExecutable: '/opt/Gapless/usr/bin/gapless',
          operatingSystem: 'linux',
        ),
        '/opt/Gapless/usr/lib/gapless/engine',
      );
      expect(
        nativeAutoEditorInstallRoot(
          resolvedExecutable: '/tmp/flutter-bundle/gapless',
          operatingSystem: 'linux',
        ),
        '/tmp/flutter-bundle/lib/gapless/engine',
      );
    });
  });

  test('parses the exact pinned manifest and four approved targets', () {
    final manifest = AutoEditorManifest.parse(
      File('assets/engine/manifest.json').readAsStringSync(),
    );

    expect(manifest.engine, 'auto-editor');
    expect(manifest.version, '31.2.0');
    expect(manifest.targets.keys, {
      'macos-arm64',
      'macos-x64',
      'windows-x64',
      'linux-x64',
    });
    expect(
      manifest.targets['macos-arm64']!.sha256,
      '12cad2d0887bf44e6406e13b2cb7f32bd20d7aafb46b495c4b38eea2af590b27',
    );
    expect(
      manifest.targets['windows-x64']!.url.toString(),
      'https://github.com/WyattBlue/auto-editor/releases/download/31.2.0/'
      'auto-editor-windows-x86_64.exe',
    );
  });

  test('manifest rejects duplicate, missing, unknown, and numeric traps', () {
    final valid = File('assets/engine/manifest.json').readAsStringSync();
    final values = {
      'duplicate': valid.replaceFirst(
        '"engine": "auto-editor",',
        '"engine": "auto-editor", "engine": "auto-editor",',
      ),
      'missing': valid.replaceFirst('"version": "31.2.0",', ''),
      'unknown': valid.replaceFirst(
        '"engine": "auto-editor",',
        '"engine": "auto-editor", "extra": 1,',
      ),
      'boolean digest': valid.replaceFirst(
        '"sha256": "12cad2d0887bf44e6406e13b2cb7f32bd20d7aafb46b495c4b38eea2af590b27"',
        '"sha256": true',
      ),
      'non-finite numeric': valid.replaceFirst(
        '"engine": "auto-editor",',
        '"engine": 1e999,',
      ),
    };

    for (final entry in values.entries) {
      expect(
        () => AutoEditorManifest.parse(entry.value),
        throwsFormatException,
        reason: entry.key,
      );
    }
  });

  test('selects the deterministic target from the native ABI', () {
    final expected = switch (Abi.current()) {
      Abi.macosArm64 => 'macos-arm64',
      Abi.macosX64 => 'macos-x64',
      Abi.windowsX64 => 'windows-x64',
      Abi.linuxX64 => 'linux-x64',
      _ => null,
    };
    if (expected != null) expect(currentAutoEditorTarget(), expected);
  });

  group('installed target verification', () {
    late Directory temp;
    late LocatorProcessRunner runner;
    late AutoEditorLocator locator;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('gapless-locator-test-');
      runner = LocatorProcessRunner(version: '31.2.0');
      locator = AutoEditorLocator(
        manifestPath: '${temp.path}/manifest.json',
        installRoot: temp.path,
        processRunner: runner,
        target: 'windows-x64',
      );
    });

    tearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    test('returns only absolute checksum and version verified path', () async {
      final directory = Directory('${temp.path}/windows-x64')..createSync();
      final executable = File('${directory.path}/auto-editor.exe')
        ..writeAsStringSync('pinned binary bytes');
      final digest = sha256.convert(executable.readAsBytesSync()).toString();

      final result = await locator.verifyTarget(_target(sha256: digest));

      expect(result, executable.path);
      expect(File(result).absolute.path, result);
      expect(runner.requests.single.executable, executable.path);
      expect(runner.requests.single.arguments, ['--version']);
    });

    test(
      'accepts the deterministic direct path used by native bundles',
      () async {
        final executable = File('${temp.path}/auto-editor.exe')
          ..writeAsStringSync('pinned bundle bytes');
        final digest = sha256.convert(executable.readAsBytesSync()).toString();

        final result = await locator.verifyTarget(_target(sha256: digest));

        expect(result, executable.path);
        expect(runner.requests.single.executable, executable.path);
      },
    );

    test('maps missing and checksum mismatches structurally', () async {
      await expectLater(
        locator.verifyTarget(_target(sha256: _zeroDigest)),
        throwsA(isA<EngineMissingFailure>()),
      );

      final directory = Directory('${temp.path}/windows-x64')..createSync();
      File('${directory.path}/auto-editor.exe').writeAsStringSync('wrong');
      await expectLater(
        locator.verifyTarget(_target(sha256: _zeroDigest)),
        throwsA(
          isA<EngineChecksumFailure>()
              .having(
                (failure) => failure.expectedSha256,
                'expected',
                _zeroDigest,
              )
              .having(
                (failure) => failure.actualSha256,
                'actual',
                isNot(_zeroDigest),
              ),
        ),
      );
    });

    test('rejects version drift with bounded structured diagnostics', () async {
      final directory = Directory('${temp.path}/windows-x64')..createSync();
      final executable = File('${directory.path}/auto-editor.exe')
        ..writeAsStringSync('binary');
      final digest = sha256.convert(executable.readAsBytesSync()).toString();
      runner.version = '31.2.1';

      await expectLater(
        locator.verifyTarget(_target(sha256: digest)),
        throwsA(
          isA<EngineContractFailure>()
              .having(
                (failure) => failure.reason,
                'reason',
                EngineContractReason.unsupportedVersion,
              )
              .having(
                (failure) => failure.diagnostics.join().length,
                'diagnostics',
                lessThanOrEqualTo(1024),
              ),
        ),
      );
    });

    test('requires executable permission for POSIX targets', () async {
      if (Platform.isWindows) return;
      final posixLocator = AutoEditorLocator(
        manifestPath: '${temp.path}/manifest.json',
        installRoot: temp.path,
        processRunner: runner,
        target: 'macos-arm64',
      );
      final directory = Directory('${temp.path}/macos-arm64')..createSync();
      final executable = File('${directory.path}/auto-editor')
        ..writeAsStringSync('binary');
      final chmod = await Process.run('/bin/chmod', ['644', executable.path]);
      expect(chmod.exitCode, 0);
      final digest = sha256.convert(executable.readAsBytesSync()).toString();

      await expectLater(
        posixLocator.verifyTarget(
          AutoEditorTarget(
            name: 'macos-arm64',
            asset: 'auto-editor-macos-arm64',
            url: Uri.parse(
              'https://github.com/WyattBlue/auto-editor/releases/download/'
              '31.2.0/auto-editor-macos-arm64',
            ),
            installedFile: 'auto-editor',
            sha256: digest,
          ),
        ),
        throwsA(isA<EngineMissingFailure>()),
      );
      expect(runner.requests, isEmpty);
    });
  });
}

AutoEditorTarget _target({required String sha256}) => AutoEditorTarget(
  name: 'windows-x64',
  asset: 'auto-editor-windows-x86_64.exe',
  url: Uri.https(
    'github.com',
    '/WyattBlue/auto-editor/releases/download/31.2.0/'
        'auto-editor-windows-x86_64.exe',
  ),
  installedFile: 'auto-editor.exe',
  sha256: sha256,
);

const _zeroDigest =
    '0000000000000000000000000000000000000000000000000000000000000000';

final class LocatorProcessRunner implements ProcessRunner {
  LocatorProcessRunner({required this.version});

  String version;
  final requests = <ProcessRequest>[];

  @override
  Future<RunningProcess> start(ProcessRequest request) async {
    requests.add(request);
    return LocatorRunningProcess(version);
  }
}

final class LocatorRunningProcess implements RunningProcess {
  const LocatorRunningProcess(this.version);

  final String version;

  @override
  int get pid => 1;

  @override
  Stream<String> get stdoutLines => Stream.value(version);

  @override
  Stream<String> get stderrLines => const Stream.empty();

  @override
  Future<int> get exitCode async => 0;

  @override
  Future<void> cancel() async {}
}
