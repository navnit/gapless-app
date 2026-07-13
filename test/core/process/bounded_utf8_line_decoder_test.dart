import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/core/process/bounded_utf8_line_decoder.dart';

void main() {
  test('preserves multibyte characters split across input chunks', () {
    final lines = <String>[];
    final decoder = BoundedUtf8LineDecoder(
      maxLineBytes: 64,
      maxLineCharacters: 64,
      onLine: lines.add,
    );

    decoder
      ..add([0x41, 0xe2])
      ..add([0x82])
      ..add([0xac, 0x0a])
      ..close();

    expect(lines, ['A€']);
  });

  test('handles CRLF and emits a final unterminated line', () {
    final lines = <String>[];
    final decoder = BoundedUtf8LineDecoder(
      maxLineBytes: 64,
      maxLineCharacters: 64,
      onLine: lines.add,
    );

    decoder
      ..add([0x66, 0x69, 0x72, 0x73, 0x74, 0x0d])
      ..add([0x0a, 0x73, 0x65, 0x63, 0x6f, 0x6e, 0x64])
      ..close();

    expect(lines, ['first', 'second']);
  });

  test('replaces malformed UTF-8 without exceeding line caps', () {
    final lines = <String>[];
    final decoder = BoundedUtf8LineDecoder(
      maxLineBytes: 32,
      maxLineCharacters: 32,
      onLine: lines.add,
    );

    decoder
      ..add([0x61, 0x80, 0x62, 0x0a])
      ..close();

    expect(lines, ['a\u{FFFD}b']);
  });
}
