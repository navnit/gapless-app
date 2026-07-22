import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

const macosIconSizes = <int>[16, 32, 64, 128, 256, 512, 1024];
const windowsIconSizes = <int>[16, 32, 48, 64, 128, 256];

const _background = Rgba(23, 25, 29, 255);
const _solidAmber = Rgba(227, 166, 59, 255);
const _mutedAmber = Rgba(115, 88, 43, 255);
const _transparent = Rgba(0, 0, 0, 0);
const _pngSignature = <int>[137, 80, 78, 71, 13, 10, 26, 10];
const _samplesPerAxis = 4;

Future<void> main(List<String> arguments) async {
  if (arguments.length > 1) {
    stderr.writeln(
      'Usage: dart run tool/branding/generate_app_icons.dart '
      '[REPOSITORY_ROOT]',
    );
    exitCode = 64;
    return;
  }

  final root = arguments.isEmpty ? Directory.current : Directory(arguments[0]);
  try {
    await writeAppIcons(root);
    for (final path in (await generateAppIconFiles()).keys) {
      stdout.writeln('Updated $path');
    }
  } on FileSystemException catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  }
}

final class Rgba {
  const Rgba(this.red, this.green, this.blue, this.alpha);

  final int red;
  final int green;
  final int blue;
  final int alpha;

  @override
  bool operator ==(Object other) =>
      other is Rgba &&
      red == other.red &&
      green == other.green &&
      blue == other.blue &&
      alpha == other.alpha;

  @override
  int get hashCode => Object.hash(red, green, blue, alpha);

  @override
  String toString() => 'Rgba($red, $green, $blue, $alpha)';
}

final class PngInfo {
  const PngInfo(this.width, this.height, this._rgba);

  final int width;
  final int height;
  final Uint8List _rgba;

  Rgba rgbaAt(int x, int y) {
    if (x < 0 || x >= width || y < 0 || y >= height) {
      throw RangeError('Pixel ($x, $y) is outside ${width}x$height');
    }
    final offset = (y * width + x) * 4;
    return Rgba(
      _rgba[offset],
      _rgba[offset + 1],
      _rgba[offset + 2],
      _rgba[offset + 3],
    );
  }

  bool containsRgb(int red, int green, int blue) {
    for (var offset = 0; offset < _rgba.length; offset += 4) {
      if (_rgba[offset] == red &&
          _rgba[offset + 1] == green &&
          _rgba[offset + 2] == blue &&
          _rgba[offset + 3] != 0) {
        return true;
      }
    }
    return false;
  }
}

final class IcoFrame {
  const IcoFrame(this.size, this.pngBytes);

  final int size;
  final Uint8List pngBytes;
}

Uint8List renderGaplessPng(int size) {
  if (size < 16 || size > 1024) {
    throw ArgumentError.value(size, 'size', 'must be between 16 and 1024');
  }

  final rgba = Uint8List(size * size * 4);
  var outputOffset = 0;
  for (var pixelY = 0; pixelY < size; pixelY++) {
    for (var pixelX = 0; pixelX < size; pixelX++) {
      var alphaSum = 0;
      var redPremultipliedSum = 0;
      var greenPremultipliedSum = 0;
      var bluePremultipliedSum = 0;

      for (var sampleY = 0; sampleY < _samplesPerAxis; sampleY++) {
        for (var sampleX = 0; sampleX < _samplesPerAxis; sampleX++) {
          final x = (pixelX + (sampleX + 0.5) / _samplesPerAxis) / size;
          final y = (pixelY + (sampleY + 0.5) / _samplesPerAxis) / size;
          final color = _sampleArtwork(x, y);
          alphaSum += color.alpha;
          redPremultipliedSum += color.red * color.alpha;
          greenPremultipliedSum += color.green * color.alpha;
          bluePremultipliedSum += color.blue * color.alpha;
        }
      }

      if (alphaSum == 0) {
        rgba[outputOffset++] = 0;
        rgba[outputOffset++] = 0;
        rgba[outputOffset++] = 0;
      } else {
        rgba[outputOffset++] = (redPremultipliedSum / alphaSum).round();
        rgba[outputOffset++] = (greenPremultipliedSum / alphaSum).round();
        rgba[outputOffset++] = (bluePremultipliedSum / alphaSum).round();
      }
      rgba[outputOffset++] = (alphaSum / (_samplesPerAxis * _samplesPerAxis))
          .round();
    }
  }

  return _encodePng(size, size, rgba);
}

Rgba _sampleArtwork(double x, double y) {
  if (!_insideRoundedRect(
    x,
    y,
    left: 0.0625,
    top: 0.0625,
    right: 0.9375,
    bottom: 0.9375,
    radius: 0.21875,
  )) {
    return _transparent;
  }
  if (_insideRoundedRect(
    x,
    y,
    left: 0.3515625,
    top: 0.28125,
    right: 0.4296875,
    bottom: 0.71875,
    radius: 0.0390625,
  )) {
    return _solidAmber;
  }
  if (_insideRoundedRect(
    x,
    y,
    left: 0.5703125,
    top: 0.28125,
    right: 0.6484375,
    bottom: 0.71875,
    radius: 0.0390625,
  )) {
    return _mutedAmber;
  }
  return _background;
}

bool _insideRoundedRect(
  double x,
  double y, {
  required double left,
  required double top,
  required double right,
  required double bottom,
  required double radius,
}) {
  if (x < left || x > right || y < top || y > bottom) return false;
  final dx = math.max(math.max(left + radius - x, 0), x - (right - radius));
  final dy = math.max(math.max(top + radius - y, 0), y - (bottom - radius));
  return dx * dx + dy * dy <= radius * radius;
}

Uint8List _encodePng(int width, int height, Uint8List rgba) {
  if (rgba.length != width * height * 4) {
    throw ArgumentError.value(
      rgba.length,
      'rgba.length',
      'does not match size',
    );
  }

  final scanlines = BytesBuilder(copy: false);
  for (var row = 0; row < height; row++) {
    scanlines.addByte(0);
    final start = row * width * 4;
    scanlines.add(Uint8List.sublistView(rgba, start, start + width * 4));
  }

  final header = ByteData(13)
    ..setUint32(0, width, Endian.big)
    ..setUint32(4, height, Endian.big)
    ..setUint8(8, 8)
    ..setUint8(9, 6)
    ..setUint8(10, 0)
    ..setUint8(11, 0)
    ..setUint8(12, 0);
  final compressed = Uint8List.fromList(
    ZLibEncoder(level: 9).convert(scanlines.takeBytes()),
  );

  return (BytesBuilder(copy: false)
        ..add(_pngSignature)
        ..add(_pngChunk('IHDR', header.buffer.asUint8List()))
        ..add(_pngChunk('IDAT', compressed))
        ..add(_pngChunk('IEND', Uint8List(0))))
      .takeBytes();
}

Uint8List _pngChunk(String type, Uint8List payload) {
  final typeBytes = ascii.encode(type);
  if (typeBytes.length != 4) {
    throw ArgumentError.value(type, 'type', 'must contain four ASCII bytes');
  }
  final checksumInput = Uint8List.fromList(<int>[...typeBytes, ...payload]);
  return (BytesBuilder(copy: false)
        ..add(_uint32BigEndian(payload.length))
        ..add(typeBytes)
        ..add(payload)
        ..add(_uint32BigEndian(_crc32(checksumInput))))
      .takeBytes();
}

PngInfo inspectPng(Uint8List bytes) {
  if (bytes.length < _pngSignature.length ||
      !_bytesEqual(bytes, 0, _pngSignature)) {
    throw const FormatException('Invalid PNG signature');
  }

  int? width;
  int? height;
  final compressed = BytesBuilder(copy: false);
  var offset = _pngSignature.length;
  var foundEnd = false;
  while (offset < bytes.length) {
    if (offset + 12 > bytes.length) {
      throw const FormatException('Truncated PNG chunk header');
    }
    final length = _readUint32(bytes, offset, Endian.big);
    final payloadStart = offset + 8;
    final payloadEnd = payloadStart + length;
    final checksumOffset = payloadEnd;
    if (payloadEnd + 4 > bytes.length) {
      throw const FormatException('Truncated PNG chunk payload');
    }
    final type = ascii.decode(bytes.sublist(offset + 4, offset + 8));
    final expectedChecksum = _readUint32(bytes, checksumOffset, Endian.big);
    final actualChecksum = _crc32(
      Uint8List.sublistView(bytes, offset + 4, payloadEnd),
    );
    if (actualChecksum != expectedChecksum) {
      throw FormatException('Invalid PNG $type checksum');
    }

    if (type == 'IHDR') {
      if (length != 13 || width != null) {
        throw const FormatException('Invalid PNG IHDR');
      }
      width = _readUint32(bytes, payloadStart, Endian.big);
      height = _readUint32(bytes, payloadStart + 4, Endian.big);
      if (width <= 0 || height <= 0) {
        throw const FormatException('Invalid PNG dimensions');
      }
      final settings = bytes.sublist(payloadStart + 8, payloadEnd);
      if (!_listEquals(settings, const <int>[8, 6, 0, 0, 0])) {
        throw const FormatException('Unsupported PNG color format');
      }
    } else if (type == 'IDAT') {
      compressed.add(Uint8List.sublistView(bytes, payloadStart, payloadEnd));
    } else if (type == 'IEND') {
      if (length != 0) throw const FormatException('Invalid PNG IEND');
      foundEnd = true;
      offset = payloadEnd + 4;
      break;
    }
    offset = payloadEnd + 4;
  }

  if (width == null || height == null || !foundEnd || offset != bytes.length) {
    throw const FormatException('Incomplete PNG structure');
  }

  late final Uint8List scanlines;
  try {
    scanlines = Uint8List.fromList(
      ZLibDecoder().convert(compressed.takeBytes()),
    );
  } on FormatException {
    throw const FormatException('Invalid PNG compressed data');
  }
  final rowLength = width * 4;
  if (scanlines.length != height * (rowLength + 1)) {
    throw const FormatException('Invalid PNG scanline length');
  }
  final rgba = Uint8List(width * height * 4);
  for (var row = 0; row < height; row++) {
    final inputOffset = row * (rowLength + 1);
    if (scanlines[inputOffset] != 0) {
      throw const FormatException('Unsupported PNG scanline filter');
    }
    rgba.setRange(
      row * rowLength,
      (row + 1) * rowLength,
      scanlines,
      inputOffset + 1,
    );
  }
  return PngInfo(width, height, rgba);
}

Uint8List encodeWindowsIco(Map<int, Uint8List> pngFrames) {
  final sizes = pngFrames.keys.toList()..sort();
  if (sizes.isEmpty) {
    throw ArgumentError.value(pngFrames, 'pngFrames', 'must not be empty');
  }

  final headerSize = 6 + sizes.length * 16;
  final directory = BytesBuilder(copy: false);
  directory.add(_uint16LittleEndian(0));
  directory.add(_uint16LittleEndian(1));
  directory.add(_uint16LittleEndian(sizes.length));

  var payloadOffset = headerSize;
  for (final size in sizes) {
    if (size < 1 || size > 256) {
      throw ArgumentError.value(size, 'pngFrames key', 'must be 1 through 256');
    }
    final png = pngFrames[size]!;
    final info = inspectPng(png);
    if (info.width != size || info.height != size) {
      throw ArgumentError.value(
        size,
        'pngFrames key',
        'does not match embedded PNG dimensions',
      );
    }
    directory
      ..addByte(size == 256 ? 0 : size)
      ..addByte(size == 256 ? 0 : size)
      ..addByte(0)
      ..addByte(0)
      ..add(_uint16LittleEndian(1))
      ..add(_uint16LittleEndian(32))
      ..add(_uint32LittleEndian(png.length))
      ..add(_uint32LittleEndian(payloadOffset));
    payloadOffset += png.length;
  }

  final result = BytesBuilder(copy: false)..add(directory.takeBytes());
  for (final size in sizes) {
    result.add(pngFrames[size]!);
  }
  return result.takeBytes();
}

List<IcoFrame> inspectIco(Uint8List bytes) {
  if (bytes.length < 6 ||
      _readUint16(bytes, 0, Endian.little) != 0 ||
      _readUint16(bytes, 2, Endian.little) != 1) {
    throw const FormatException('Invalid ICO header');
  }
  final count = _readUint16(bytes, 4, Endian.little);
  if (count == 0 || bytes.length < 6 + count * 16) {
    throw const FormatException('Invalid ICO directory');
  }

  final frames = <IcoFrame>[];
  for (var index = 0; index < count; index++) {
    final entryOffset = 6 + index * 16;
    final width = bytes[entryOffset] == 0 ? 256 : bytes[entryOffset];
    final height = bytes[entryOffset + 1] == 0 ? 256 : bytes[entryOffset + 1];
    if (width != height) {
      throw const FormatException('ICO frame must be square');
    }
    final length = _readUint32(bytes, entryOffset + 8, Endian.little);
    final payloadOffset = _readUint32(bytes, entryOffset + 12, Endian.little);
    if (length == 0 || payloadOffset + length > bytes.length) {
      throw const FormatException('Invalid ICO frame bounds');
    }
    frames.add(
      IcoFrame(
        width,
        Uint8List.sublistView(bytes, payloadOffset, payloadOffset + length),
      ),
    );
  }
  return frames;
}

Future<Map<String, Uint8List>> generateAppIconFiles() async {
  final files = <String, Uint8List>{};
  for (final size in macosIconSizes) {
    files['macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_$size.png'] =
        renderGaplessPng(size);
  }
  files['windows/runner/resources/app_icon.ico'] = encodeWindowsIco(
    <int, Uint8List>{
      for (final size in windowsIconSizes) size: renderGaplessPng(size),
    },
  );
  return files;
}

abstract interface class IconFileSystem {
  const IconFileSystem();

  Future<void> createParent(String path);
  Future<void> delete(String path);
  Future<bool> exists(String path);
  Future<void> rename(String source, String destination);
  Future<void> write(String path, Uint8List bytes);
}

final class IoIconFileSystem implements IconFileSystem {
  const IoIconFileSystem();

  @override
  Future<void> createParent(String path) =>
      File(path).parent.create(recursive: true);

  @override
  Future<void> delete(String path) => File(path).delete();

  @override
  Future<bool> exists(String path) => File(path).exists();

  @override
  Future<void> rename(String source, String destination) async {
    await File(source).rename(destination);
  }

  @override
  Future<void> write(String path, Uint8List bytes) =>
      File(path).writeAsBytes(bytes, flush: true);
}

Future<void> writeAppIcons(
  Directory repositoryRoot, {
  IconFileSystem fileSystem = const IoIconFileSystem(),
}) async {
  final generated = await generateAppIconFiles();
  final replacements = <_FileReplacement>[];
  for (final entry in generated.entries) {
    final destination = File('${repositoryRoot.path}/${entry.key}');
    await fileSystem.createParent(destination.path);
    replacements.add(
      _FileReplacement(
        destination: destination,
        staging: File('${destination.path}.gapless-icon-new'),
        backup: File('${destination.path}.gapless-icon-backup'),
        bytes: entry.value,
      ),
    );
  }

  for (final replacement in replacements) {
    for (final reserved in <File>[replacement.staging, replacement.backup]) {
      if (await fileSystem.exists(reserved.path)) {
        throw FileSystemException(
          'Refusing to overwrite reserved icon update file: ${reserved.path}',
          reserved.path,
        );
      }
    }
  }

  Object? operationError;
  StackTrace? operationStackTrace;
  try {
    for (final replacement in replacements) {
      await fileSystem.write(replacement.staging.path, replacement.bytes);
    }
    for (final replacement in replacements) {
      if (await fileSystem.exists(replacement.destination.path)) {
        await fileSystem.rename(
          replacement.destination.path,
          replacement.backup.path,
        );
        replacement.backedUp = true;
      }
    }
    for (final replacement in replacements) {
      await fileSystem.rename(
        replacement.staging.path,
        replacement.destination.path,
      );
      replacement.installed = true;
    }
  } catch (error, stackTrace) {
    operationError = error;
    operationStackTrace = stackTrace;
  }

  if (operationError != null) {
    Object? rollbackError;
    for (final replacement in replacements.reversed) {
      if (replacement.installed &&
          await fileSystem.exists(replacement.destination.path)) {
        try {
          await fileSystem.delete(replacement.destination.path);
        } catch (error) {
          rollbackError ??= error;
        }
      }
      if (replacement.backedUp &&
          await fileSystem.exists(replacement.backup.path)) {
        try {
          await fileSystem.rename(
            replacement.backup.path,
            replacement.destination.path,
          );
        } catch (error) {
          rollbackError ??= error;
        }
      }
      if (await fileSystem.exists(replacement.staging.path)) {
        try {
          await fileSystem.delete(replacement.staging.path);
        } catch (error) {
          rollbackError ??= error;
        }
      }
    }

    final message = rollbackError == null
        ? 'Unable to update Gapless app icons; original assets restored: '
              '$operationError'
        : 'Unable to update Gapless app icons; rollback was incomplete: '
              '$operationError; rollback error: $rollbackError';
    Error.throwWithStackTrace(
      FileSystemException(message, repositoryRoot.path),
      operationStackTrace ?? StackTrace.current,
    );
  }

  Object? backupCleanupError;
  StackTrace? backupCleanupStackTrace;
  for (final replacement in replacements) {
    if (!replacement.backedUp ||
        !await fileSystem.exists(replacement.backup.path)) {
      continue;
    }
    try {
      await fileSystem.delete(replacement.backup.path);
    } catch (error, stackTrace) {
      backupCleanupError ??= error;
      backupCleanupStackTrace ??= stackTrace;
    }
  }
  if (backupCleanupError != null) {
    Error.throwWithStackTrace(
      FileSystemException(
        'Gapless app icons were installed, but backup cleanup failed: '
        '$backupCleanupError',
        repositoryRoot.path,
      ),
      backupCleanupStackTrace ?? StackTrace.current,
    );
  }
}

final class _FileReplacement {
  _FileReplacement({
    required this.destination,
    required this.staging,
    required this.backup,
    required this.bytes,
  });

  final File destination;
  final File staging;
  final File backup;
  final Uint8List bytes;
  bool backedUp = false;
  bool installed = false;
}

Uint8List _uint16LittleEndian(int value) =>
    (ByteData(2)..setUint16(0, value, Endian.little)).buffer.asUint8List();

Uint8List _uint32LittleEndian(int value) =>
    (ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List();

Uint8List _uint32BigEndian(int value) =>
    (ByteData(4)..setUint32(0, value, Endian.big)).buffer.asUint8List();

int _readUint16(Uint8List bytes, int offset, Endian endian) {
  if (offset < 0 || offset + 2 > bytes.length) {
    throw const FormatException('Binary uint16 is out of bounds');
  }
  return ByteData.sublistView(bytes, offset, offset + 2).getUint16(0, endian);
}

int _readUint32(Uint8List bytes, int offset, Endian endian) {
  if (offset < 0 || offset + 4 > bytes.length) {
    throw const FormatException('Binary uint32 is out of bounds');
  }
  return ByteData.sublistView(bytes, offset, offset + 4).getUint32(0, endian);
}

bool _bytesEqual(Uint8List bytes, int offset, List<int> expected) {
  if (offset < 0 || offset + expected.length > bytes.length) return false;
  for (var index = 0; index < expected.length; index++) {
    if (bytes[offset + index] != expected[index]) return false;
  }
  return true;
}

bool _listEquals(List<int> first, List<int> second) {
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    if (first[index] != second[index]) return false;
  }
  return true;
}

int _crc32(Uint8List bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}
