import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

const _width = 32;
const _height = 32;
const _framesPerSecond = 10;
const _frameCount = 20;
const _sampleRate = 8000;
const _samplesPerFrame = _sampleRate ~/ _framesPerSecond;
const _frameSize = _width * _height * 3;

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln(
      'Usage: dart run tool/testing/generate_fixture_video.dart OUTPUT.avi',
    );
    exitCode = 64;
    return;
  }
  await generateFixtureVideo(File(arguments.single));
}

/// Writes a deterministic two-second AVI used by native integration tests.
///
/// The source deliberately alternates audible tone and silence while carrying
/// uncompressed RGB video. It needs no system codec or fixture download, and
/// Auto-Editor can therefore exercise probe, analysis, timeline, and render on
/// every native runner.
Future<void> generateFixtureVideo(File destination) async {
  final movie = BytesBuilder(copy: false);
  final index = BytesBuilder(copy: false);
  var movieOffset = 4; // Offset is relative to the LIST payload's `movi` tag.

  for (var frame = 0; frame < _frameCount; frame++) {
    final video = _videoFrame(frame);
    final videoChunk = _chunk('00db', video);
    movie.add(videoChunk);
    index.add(_indexEntry('00db', 0x10, movieOffset, video.length));
    movieOffset += videoChunk.length;

    final audio = _audioFrame(frame);
    final audioChunk = _chunk('01wb', audio);
    movie.add(audioChunk);
    index.add(_indexEntry('01wb', 0, movieOffset, audio.length));
    movieOffset += audioChunk.length;
  }

  final header = _list('hdrl', <Uint8List>[
    _chunk('avih', _aviHeader()),
    _list('strl', <Uint8List>[
      _chunk('strh', _videoStreamHeader()),
      _chunk('strf', _videoFormat()),
    ]),
    _list('strl', <Uint8List>[
      _chunk('strh', _audioStreamHeader()),
      _chunk('strf', _audioFormat()),
    ]),
  ]);
  final bytes = _riff('AVI ', <Uint8List>[
    header,
    _list('movi', <Uint8List>[movie.takeBytes()]),
    _chunk('idx1', index.takeBytes()),
  ]);

  await destination.parent.create(recursive: true);
  final output = await destination.open(mode: FileMode.write);
  try {
    await output.writeFrom(bytes);
    await output.flush();
  } finally {
    await output.close();
  }
}

Uint8List _aviHeader() {
  final writer = _LittleEndianWriter();
  writer
    ..u32(Duration.microsecondsPerSecond ~/ _framesPerSecond)
    ..u32((_frameSize + _samplesPerFrame * 2) * _framesPerSecond)
    ..u32(0)
    ..u32(0x10) // AVIF_HASINDEX
    ..u32(_frameCount)
    ..u32(0)
    ..u32(2)
    ..u32(_frameSize)
    ..u32(_width)
    ..u32(_height)
    ..u32(0)
    ..u32(0)
    ..u32(0)
    ..u32(0);
  return writer.bytes();
}

Uint8List _videoStreamHeader() {
  final writer = _LittleEndianWriter();
  writer
    ..fourCc('vids')
    ..fourCc('DIB ')
    ..u32(0)
    ..u16(0)
    ..u16(0)
    ..u32(0)
    ..u32(1)
    ..u32(_framesPerSecond)
    ..u32(0)
    ..u32(_frameCount)
    ..u32(_frameSize)
    ..u32(0xffffffff)
    ..u32(0)
    ..i16(0)
    ..i16(0)
    ..i16(_width)
    ..i16(_height);
  return writer.bytes();
}

Uint8List _videoFormat() {
  final writer = _LittleEndianWriter();
  writer
    ..u32(40)
    ..i32(_width)
    ..i32(_height)
    ..u16(1)
    ..u16(24)
    ..u32(0) // BI_RGB
    ..u32(_frameSize)
    ..i32(0)
    ..i32(0)
    ..u32(0)
    ..u32(0);
  return writer.bytes();
}

Uint8List _audioStreamHeader() {
  const blockAlign = 2;
  final writer = _LittleEndianWriter();
  writer
    ..fourCc('auds')
    ..u32(0)
    ..u32(0)
    ..u16(0)
    ..u16(0)
    ..u32(0)
    ..u32(blockAlign)
    ..u32(_sampleRate * blockAlign)
    ..u32(0)
    ..u32(_sampleRate * _frameCount ~/ _framesPerSecond)
    ..u32(_samplesPerFrame * blockAlign)
    ..u32(0xffffffff)
    ..u32(blockAlign)
    ..i16(0)
    ..i16(0)
    ..i16(0)
    ..i16(0);
  return writer.bytes();
}

Uint8List _audioFormat() {
  const blockAlign = 2;
  final writer = _LittleEndianWriter();
  writer
    ..u16(1) // WAVE_FORMAT_PCM
    ..u16(1)
    ..u32(_sampleRate)
    ..u32(_sampleRate * blockAlign)
    ..u16(blockAlign)
    ..u16(16);
  return writer.bytes();
}

Uint8List _videoFrame(int frame) {
  final bytes = Uint8List(_frameSize);
  var offset = 0;
  for (var y = 0; y < _height; y++) {
    for (var x = 0; x < _width; x++) {
      bytes[offset++] = (x * 7 + frame * 9) & 0xff; // B
      bytes[offset++] = (y * 7 + frame * 5) & 0xff; // G
      bytes[offset++] = (x * 3 + y * 3 + frame * 11) & 0xff; // R
    }
  }
  return bytes;
}

Uint8List _audioFrame(int frame) {
  final bytes = ByteData(_samplesPerFrame * 2);
  final audible = frame < 6 || (frame >= 11 && frame < 16);
  for (var sample = 0; sample < _samplesPerFrame; sample++) {
    final global = frame * _samplesPerFrame + sample;
    final value = audible
        ? (math.sin(2 * math.pi * 440 * global / _sampleRate) * 12000).round()
        : 0;
    bytes.setInt16(sample * 2, value, Endian.little);
  }
  return bytes.buffer.asUint8List();
}

Uint8List _indexEntry(String id, int flags, int offset, int size) {
  final writer = _LittleEndianWriter();
  writer
    ..fourCc(id)
    ..u32(flags)
    ..u32(offset)
    ..u32(size);
  return writer.bytes();
}

Uint8List _riff(String type, List<Uint8List> children) {
  final payload = _join(<Uint8List>[_ascii(type), ...children]);
  return _sizedContainer('RIFF', payload);
}

Uint8List _list(String type, List<Uint8List> children) {
  final payload = _join(<Uint8List>[_ascii(type), ...children]);
  return _sizedContainer('LIST', payload);
}

Uint8List _chunk(String id, Uint8List payload) => _sizedContainer(id, payload);

Uint8List _sizedContainer(String id, Uint8List payload) {
  final writer = _LittleEndianWriter()
    ..fourCc(id)
    ..u32(payload.length);
  final builder = BytesBuilder(copy: false)
    ..add(writer.bytes())
    ..add(payload);
  if (payload.length.isOdd) builder.addByte(0);
  return builder.takeBytes();
}

Uint8List _join(List<Uint8List> values) {
  final builder = BytesBuilder(copy: false);
  for (final value in values) {
    builder.add(value);
  }
  return builder.takeBytes();
}

Uint8List _ascii(String value) {
  if (value.length != 4) throw ArgumentError.value(value, 'fourCc');
  return Uint8List.fromList(value.codeUnits);
}

final class _LittleEndianWriter {
  final BytesBuilder _builder = BytesBuilder(copy: false);

  void fourCc(String value) => _builder.add(_ascii(value));

  void u16(int value) {
    final data = ByteData(2)..setUint16(0, value, Endian.little);
    _builder.add(data.buffer.asUint8List());
  }

  void i16(int value) {
    final data = ByteData(2)..setInt16(0, value, Endian.little);
    _builder.add(data.buffer.asUint8List());
  }

  void u32(int value) {
    final data = ByteData(4)..setUint32(0, value, Endian.little);
    _builder.add(data.buffer.asUint8List());
  }

  void i32(int value) {
    final data = ByteData(4)..setInt32(0, value, Endian.little);
    _builder.add(data.buffer.asUint8List());
  }

  Uint8List bytes() => _builder.takeBytes();
}
