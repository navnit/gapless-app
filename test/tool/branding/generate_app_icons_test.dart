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
      final catalog = await File(
        '$root/macos/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json',
      ).readAsString();
      for (final size in macosIconSizes) {
        expect(catalog, contains('app_icon_$size.png'));
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
  });
}
