import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../../tool/testing/generate_fixture_video.dart';

void main() {
  test(
    'generates a deterministic indexed AVI with video and PCM audio',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'gapless-fixture-video-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final first = File('${directory.path}/first.avi');
      final second = File('${directory.path}/second.avi');

      await generateFixtureVideo(first);
      await generateFixtureVideo(second);

      final bytes = await first.readAsBytes();
      expect(bytes, await second.readAsBytes());
      expect(ascii.decode(bytes.sublist(0, 4)), 'RIFF');
      expect(ascii.decode(bytes.sublist(8, 12)), 'AVI ');
      expect(_containsAscii(bytes, 'vids'), isTrue);
      expect(_containsAscii(bytes, 'auds'), isTrue);
      expect(_containsAscii(bytes, 'movi'), isTrue);
      expect(_containsAscii(bytes, 'idx1'), isTrue);
      expect(bytes.length, greaterThan(90 * 1024));
      expect(bytes.length, lessThan(140 * 1024));
    },
  );
}

bool _containsAscii(List<int> bytes, String value) {
  final needle = ascii.encode(value);
  for (var offset = 0; offset <= bytes.length - needle.length; offset++) {
    var matches = true;
    for (var index = 0; index < needle.length; index++) {
      if (bytes[offset + index] != needle[index]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}
