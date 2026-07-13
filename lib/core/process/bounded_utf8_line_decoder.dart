import 'dart:collection';
import 'dart:convert';

final class BoundedUtf8LineDecoder {
  BoundedUtf8LineDecoder({
    required this.maxLineBytes,
    required this.maxLineCharacters,
    required this.onLine,
  }) {
    if (maxLineBytes < _markerBytes || maxLineCharacters < _markerCharacters) {
      throw ArgumentError(
        'Line caps must be large enough for the truncation marker',
      );
    }
    _decoder = const Utf8Decoder(allowMalformed: true).startChunkedConversion(
      StringConversionSink.fromStringSink(_DecodedStringSink(_addText)),
    );
  }

  static const lineTruncatedMarker = '…[line truncated]';
  static final int _markerBytes = utf8.encode(lineTruncatedMarker).length;
  static final int _markerCharacters = lineTruncatedMarker.runes.length;

  final int maxLineBytes;
  final int maxLineCharacters;
  final void Function(String line) onLine;
  final ListQueue<_RunePiece> _line = ListQueue();
  late final ByteConversionSink _decoder;
  var _lineBytes = 0;
  var _lineCharacters = 0;
  var _lineTruncated = false;
  var _skipLineFeed = false;
  var _closed = false;

  void add(List<int> bytes) {
    if (_closed) throw StateError('Decoder is closed');
    _decoder.add(bytes);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _decoder.close();
    if (_line.isNotEmpty || _lineTruncated) _emitLine();
  }

  void _addText(String text) {
    for (final rune in text.runes) {
      if (_skipLineFeed) {
        _skipLineFeed = false;
        if (rune == 0x0a) continue;
      }
      if (rune == 0x0d) {
        _emitLine();
        _skipLineFeed = true;
        continue;
      }
      if (rune == 0x0a) {
        _emitLine();
        continue;
      }
      if (_lineTruncated) continue;

      final value = String.fromCharCode(rune);
      final byteLength = utf8.encode(value).length;
      if (_lineBytes + byteLength > maxLineBytes ||
          _lineCharacters + 1 > maxLineCharacters) {
        _lineTruncated = true;
        _reserveMarkerSpace();
        continue;
      }
      _line.addLast(_RunePiece(value, byteLength));
      _lineBytes += byteLength;
      _lineCharacters++;
    }
  }

  void _reserveMarkerSpace() {
    while (_line.isNotEmpty &&
        (_lineBytes + _markerBytes > maxLineBytes ||
            _lineCharacters + _markerCharacters > maxLineCharacters)) {
      final removed = _line.removeLast();
      _lineBytes -= removed.byteLength;
      _lineCharacters--;
    }
  }

  void _emitLine() {
    final line = StringBuffer();
    for (final piece in _line) {
      line.write(piece.value);
    }
    if (_lineTruncated) line.write(lineTruncatedMarker);
    onLine(line.toString());
    _line.clear();
    _lineBytes = 0;
    _lineCharacters = 0;
    _lineTruncated = false;
  }
}

final class _RunePiece {
  const _RunePiece(this.value, this.byteLength);

  final String value;
  final int byteLength;
}

final class _DecodedStringSink implements StringSink {
  const _DecodedStringSink(this.onText);

  final void Function(String text) onText;

  @override
  void write(Object? object) => onText('$object');

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      onText(objects.join(separator));

  @override
  void writeCharCode(int charCode) => onText(String.fromCharCode(charCode));

  @override
  void writeln([Object? object = '']) => onText('$object\n');
}
