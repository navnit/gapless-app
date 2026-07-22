import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../../../tool/branding/generate_app_icons.dart';

void main() {
  group('Gapless app icon generator', () {
    test('renders deterministic PNGs at every macOS size', () {
      expect(macosIconSizes, <int>[16, 32, 64, 128, 256, 512, 1024]);

      for (final size in macosIconSizes) {
        final first = renderGaplessPng(size);
        final second = renderGaplessPng(size);

        expect(first, second, reason: '$size px output must be deterministic');
        final info = inspectPng(first);
        expect(info.width, size);
        expect(info.height, size);
        expect(info.rgbaAt(size ~/ 2, size ~/ 2), const Rgba(23, 25, 29, 255));
        expect(
          info.containsRgb(2, 169, 244),
          isFalse,
          reason: 'Flutter cyan must not remain',
        );
      }
    });

    test('uses the approved solid and muted amber bars', () {
      final info = inspectPng(renderGaplessPng(256));

      expect(info.rgbaAt(98, 128), const Rgba(227, 166, 59, 255));
      expect(info.rgbaAt(158, 128), const Rgba(115, 88, 43, 255));
      expect(info.rgbaAt(0, 0).alpha, 0);
    });

    test('encodes every required Windows ICO frame', () {
      expect(windowsIconSizes, <int>[16, 32, 48, 64, 128, 256]);
      final ico = encodeWindowsIco(<int, Uint8List>{
        for (final size in windowsIconSizes) size: renderGaplessPng(size),
      });

      final frames = inspectIco(ico);
      expect(frames.map((frame) => frame.size), windowsIconSizes);
      for (final frame in frames) {
        final info = inspectPng(frame.pngBytes);
        expect(info.width, frame.size);
        expect(info.height, frame.size);
      }
    });

    test('regenerates the exact committed macOS and Windows assets', () async {
      final generated = await generateAppIconFiles();

      for (final entry in generated.entries) {
        expect(
          await File('${Directory.current.path}/${entry.key}').readAsBytes(),
          entry.value,
          reason: '${entry.key} must be regenerated before commit',
        );
      }
    });

    test('platform configurations reference the generated assets', () async {
      final root = Directory.current.path;
      final catalogFile = File(
        '$root/macos/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json',
      );
      final catalog = await catalogFile.readAsString();
      for (final size in macosIconSizes) {
        expect(catalog, contains('app_icon_$size.png'));
      }

      final catalogJson = jsonDecode(catalog) as Map<String, dynamic>;
      final images = catalogJson['images'] as List<dynamic>;
      for (final value in images) {
        final image = value as Map<String, dynamic>;
        final filename = image['filename'] as String;
        final baseSize = int.parse((image['size'] as String).split('x').first);
        final scale = int.parse((image['scale'] as String).replaceAll('x', ''));
        final expectedPixels = baseSize * scale;
        final info = inspectPng(
          await File('${catalogFile.parent.path}/$filename').readAsBytes(),
        );
        expect(info.width, expectedPixels, reason: '$filename catalog width');
        expect(info.height, expectedPixels, reason: '$filename catalog height');
      }

      final runnerResource = await File(
        '$root/windows/runner/Runner.rc',
      ).readAsString();
      expect(
        runnerResource,
        contains(
          r'IDI_APP_ICON            ICON                    "resources\\app_icon.ico"',
        ),
      );
    });

    test(
      'writes a complete generated set to a repository-shaped directory',
      () async {
        final root = await Directory.systemTemp.createTemp('gapless-icons-');
        addTearDown(() => root.delete(recursive: true));

        await writeAppIcons(root);

        for (final path in (await generateAppIconFiles()).keys) {
          expect(File('${root.path}/$path').existsSync(), isTrue);
        }
      },
    );

    test('refuses a staging collision without changing originals', () async {
      final root = await Directory.systemTemp.createTemp('gapless-icons-');
      addTearDown(() => root.delete(recursive: true));
      final firstPath = (await generateAppIconFiles()).keys.first;
      final original = File('${root.path}/$firstPath');
      await original.parent.create(recursive: true);
      await original.writeAsBytes(const <int>[1, 2, 3]);
      await File(
        '${original.path}.gapless-icon-new',
      ).writeAsBytes(const <int>[4]);

      await expectLater(
        writeAppIcons(root),
        throwsA(
          isA<FileSystemException>().having(
            (error) => error.message,
            'message',
            contains('.gapless-icon-new'),
          ),
        ),
      );
      expect(await original.readAsBytes(), const <int>[1, 2, 3]);
    });

    test('staging write failure leaves every original asset intact', () async {
      final root = await Directory.systemTemp.createTemp('gapless-icons-');
      addTearDown(() => root.delete(recursive: true));
      final originals = await _seedOriginalAssets(root);
      var writes = 0;
      final fileSystem = _FaultInjectingIconFileSystem((operation, source, _) {
        if (operation != 'write') return false;
        writes++;
        return writes == 2;
      });

      await expectLater(
        writeAppIcons(root, fileSystem: fileSystem),
        throwsA(
          isA<FileSystemException>().having(
            (error) => error.message,
            'message',
            contains('original assets restored'),
          ),
        ),
      );
      await _expectOriginalAssets(root, originals);
      await _expectNoTransactionFiles(root, originals.keys);
    });

    test('installation failure restores every original asset', () async {
      final root = await Directory.systemTemp.createTemp('gapless-icons-');
      addTearDown(() => root.delete(recursive: true));
      final originals = await _seedOriginalAssets(root);
      var installs = 0;
      final fileSystem = _FaultInjectingIconFileSystem((operation, source, _) {
        if (operation != 'rename' || !source.endsWith('.gapless-icon-new')) {
          return false;
        }
        installs++;
        return installs == 2;
      });

      await expectLater(
        writeAppIcons(root, fileSystem: fileSystem),
        throwsA(
          isA<FileSystemException>().having(
            (error) => error.message,
            'message',
            contains('original assets restored'),
          ),
        ),
      );
      await _expectOriginalAssets(root, originals);
      await _expectNoTransactionFiles(root, originals.keys);
    });

    test('backup cleanup failure keeps every installed icon', () async {
      final root = await Directory.systemTemp.createTemp('gapless-icons-');
      addTearDown(() => root.delete(recursive: true));
      final originals = await _seedOriginalAssets(root);
      final fileSystem = _FaultInjectingIconFileSystem(
        (operation, source, _) =>
            operation == 'delete' && source.endsWith('.gapless-icon-backup'),
      );

      await expectLater(
        writeAppIcons(root, fileSystem: fileSystem),
        throwsA(
          isA<FileSystemException>()
              .having(
                (error) => error.message,
                'message',
                contains('icons were installed'),
              )
              .having(
                (error) => error.message,
                'message',
                contains('backup cleanup failed'),
              )
              .having(
                (error) => error.message,
                'message',
                isNot(contains('original assets restored')),
              ),
        ),
      );

      final generated = await generateAppIconFiles();
      for (final entry in generated.entries) {
        expect(
          await File('${root.path}/${entry.key}').readAsBytes(),
          entry.value,
        );
      }
      expect(originals, isNotEmpty);
    });

    test('rollback failure reports that recovery is incomplete', () async {
      final root = await Directory.systemTemp.createTemp('gapless-icons-');
      addTearDown(() => root.delete(recursive: true));
      await _seedOriginalAssets(root);
      var installs = 0;
      final fileSystem = _FaultInjectingIconFileSystem((operation, source, _) {
        if (operation != 'rename') return false;
        if (source.endsWith('.gapless-icon-new')) {
          installs++;
          return installs == 2;
        }
        return source.endsWith('.gapless-icon-backup');
      });

      await expectLater(
        writeAppIcons(root, fileSystem: fileSystem),
        throwsA(
          isA<FileSystemException>()
              .having(
                (error) => error.message,
                'message',
                contains('rollback was incomplete'),
              )
              .having(
                (error) => error.message,
                'message',
                isNot(contains('original assets restored')),
              ),
        ),
      );
    });
  });
}

Future<Map<String, Uint8List>> _seedOriginalAssets(Directory root) async {
  final originals = <String, Uint8List>{};
  var marker = 1;
  for (final path in (await generateAppIconFiles()).keys) {
    final bytes = Uint8List.fromList(<int>[marker++, 17, 29]);
    final file = File('${root.path}/$path');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    originals[path] = bytes;
  }
  return originals;
}

Future<void> _expectOriginalAssets(
  Directory root,
  Map<String, Uint8List> originals,
) async {
  for (final entry in originals.entries) {
    expect(await File('${root.path}/${entry.key}').readAsBytes(), entry.value);
  }
}

Future<void> _expectNoTransactionFiles(
  Directory root,
  Iterable<String> paths,
) async {
  for (final path in paths) {
    expect(File('${root.path}/$path.gapless-icon-new').existsSync(), isFalse);
    expect(
      File('${root.path}/$path.gapless-icon-backup').existsSync(),
      isFalse,
    );
  }
}

typedef _FailurePredicate =
    bool Function(String operation, String source, String? destination);

final class _FaultInjectingIconFileSystem implements IconFileSystem {
  _FaultInjectingIconFileSystem(this._shouldFail);

  final _FailurePredicate _shouldFail;
  final IconFileSystem _delegate = const IoIconFileSystem();

  Never _failure(String operation, String source) =>
      throw FileSystemException('Injected $operation failure', source);

  @override
  Future<void> createParent(String path) => _delegate.createParent(path);

  @override
  Future<void> delete(String path) {
    if (_shouldFail('delete', path, null)) _failure('delete', path);
    return _delegate.delete(path);
  }

  @override
  Future<bool> exists(String path) => _delegate.exists(path);

  @override
  Future<void> rename(String source, String destination) {
    if (_shouldFail('rename', source, destination)) {
      _failure('rename', source);
    }
    return _delegate.rename(source, destination);
  }

  @override
  Future<void> write(String path, Uint8List bytes) {
    if (_shouldFail('write', path, null)) _failure('write', path);
    return _delegate.write(path, bytes);
  }
}
