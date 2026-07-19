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
  });
}
