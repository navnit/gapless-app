import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:gapless/core/errors/app_failure.dart';
import 'package:gapless/features/project/data/project_codec.dart';
import 'package:gapless/features/project/domain/project_document.dart';
import 'package:gapless/features/project/domain/source_reference.dart';
import 'package:path/path.dart' as p;

abstract interface class SourceFingerprinter {
  Future<SourceFingerprint> fingerprint(Uri source);
}

final class SourceFileMetadata {
  const SourceFileMetadata({required this.size, required this.modifiedAtUtc});

  final int size;
  final DateTime modifiedAtUtc;
}

abstract interface class SourceSampleReader {
  Future<SourceFileMetadata> metadata(Uri source);
  Future<List<int>> readRange(Uri source, int offset, int length);
}

final class SampledSourceFingerprinter implements SourceFingerprinter {
  const SampledSourceFingerprinter({
    required this.reader,
    this.sampleSize = 64 * 1024,
  }) : assert(sampleSize > 0);

  final SourceSampleReader reader;
  final int sampleSize;

  @override
  Future<SourceFingerprint> fingerprint(Uri source) async {
    final metadata = await reader.metadata(source);
    if (metadata.size < 0) {
      throw StateError('Source size cannot be negative');
    }

    final blockLength = min(sampleSize, metadata.size);
    final offsets = blockLength == 0
        ? <int>[]
        : <int>{
            0,
            (metadata.size - blockLength) ~/ 2,
            metadata.size - blockLength,
          }.toList();
    offsets.sort();
    final framed = BytesBuilder(copy: false)
      ..add(_int64(metadata.size))
      ..add(_int64(offsets.length));
    for (final offset in offsets) {
      final bytes = await reader.readRange(source, offset, blockLength);
      if (bytes.length != blockLength) {
        throw StateError('Source changed while it was being fingerprinted');
      }
      framed
        ..add(_int64(offset))
        ..add(_int64(bytes.length))
        ..add(bytes);
    }

    return SourceFingerprint(
      size: metadata.size,
      modifiedAtUtc: metadata.modifiedAtUtc.toUtc(),
      sampledSha256: sha256.convert(framed.takeBytes()).toString(),
    );
  }
}

Uint8List _int64(int value) =>
    (ByteData(8)..setInt64(0, value, Endian.big)).buffer.asUint8List();

final class LocalSourceSampleReader implements SourceSampleReader {
  const LocalSourceSampleReader();

  @override
  Future<SourceFileMetadata> metadata(Uri source) async {
    final stat = await File.fromUri(source).stat();
    return SourceFileMetadata(
      size: stat.size,
      modifiedAtUtc: stat.modified.toUtc(),
    );
  }

  @override
  Future<List<int>> readRange(Uri source, int offset, int length) async {
    final handle = await File.fromUri(source).open();
    try {
      await handle.setPosition(offset);
      return handle.read(length);
    } finally {
      await handle.close();
    }
  }
}

abstract interface class ProjectFileSystem {
  Future<bool> createExclusive(Uri file);
  Future<List<int>> readBytes(Uri file);
  Future<void> writeAndFlush(Uri file, List<int> bytes);
  Future<void> rename(Uri from, Uri to);
  Future<void> copy(Uri from, Uri to);
  Future<bool> exists(Uri file);
  Future<void> deleteIfExists(Uri file);
  Future<DateTime> modifiedAtUtc(Uri file);
  Future<void> setModifiedAtUtc(Uri file, DateTime modifiedAtUtc);
}

final class LocalProjectFileSystem implements ProjectFileSystem {
  const LocalProjectFileSystem();

  @override
  Future<bool> createExclusive(Uri file) async {
    final target = File.fromUri(file);
    try {
      await target.create(exclusive: true);
      return true;
    } on FileSystemException {
      if (await target.exists()) return false;
      rethrow;
    }
  }

  @override
  Future<void> copy(Uri from, Uri to) =>
      File.fromUri(from).copy(to.toFilePath());

  @override
  Future<void> deleteIfExists(Uri file) async {
    final target = File.fromUri(file);
    if (await target.exists()) await target.delete();
  }

  @override
  Future<bool> exists(Uri file) => File.fromUri(file).exists();

  @override
  Future<DateTime> modifiedAtUtc(Uri file) async =>
      (await File.fromUri(file).lastModified()).toUtc();

  @override
  Future<void> setModifiedAtUtc(Uri file, DateTime modifiedAtUtc) =>
      File.fromUri(file).setLastModified(modifiedAtUtc.toUtc());

  @override
  Future<List<int>> readBytes(Uri file) => File.fromUri(file).readAsBytes();

  @override
  Future<void> rename(Uri from, Uri to) =>
      File.fromUri(from).rename(to.toFilePath());

  @override
  Future<void> writeAndFlush(Uri file, List<int> bytes) async {
    final handle = await File.fromUri(file).open(mode: FileMode.write);
    try {
      await handle.writeFrom(bytes);
      await handle.flush();
    } finally {
      await handle.close();
    }
  }
}

abstract interface class RandomBytes {
  List<int> nextBytes(int length);
}

final class SecureRandomBytes implements RandomBytes {
  SecureRandomBytes() : _random = Random.secure();

  final Random _random;

  @override
  List<int> nextBytes(int length) =>
      List.generate(length, (_) => _random.nextInt(256), growable: false);
}

abstract interface class ProjectStore {
  Future<ProjectDocument> load(Uri project);
  Future<void> saveAtomic(Uri project, ProjectDocument document);
  Future<RecoveryCandidate?> recoveryFor(Uri project);
}

final class ProjectRepository implements ProjectStore {
  ProjectRepository({
    ProjectFileSystem? fileSystem,
    SourceFingerprinter? fingerprinter,
    RandomBytes? randomBytes,
    ProjectCodec? codec,
  }) : _fileSystem = fileSystem ?? const LocalProjectFileSystem(),
       _fingerprinter =
           fingerprinter ??
           const SampledSourceFingerprinter(reader: LocalSourceSampleReader()),
       _randomBytes = randomBytes ?? SecureRandomBytes(),
       _codec = codec ?? ProjectCodec();

  final ProjectFileSystem _fileSystem;
  final SourceFingerprinter _fingerprinter;
  final RandomBytes _randomBytes;
  final ProjectCodec _codec;

  @override
  Future<ProjectDocument> load(Uri project) async {
    try {
      return _codec.decode(utf8.decode(await _fileSystem.readBytes(project)));
    } on ProjectFormatFailure {
      rethrow;
    } on FormatException catch (error) {
      throw ProjectFormatFailure('Project is not valid UTF-8: $error');
    }
  }

  @override
  Future<void> saveAtomic(Uri project, ProjectDocument document) async {
    Uri? temporary;
    try {
      temporary = await _reserveTemporary(project);
      final previous = _sibling(project, '.previous');
      await _fileSystem.writeAndFlush(
        temporary,
        utf8.encode(_codec.encode(document)),
      );
      if (await _fileSystem.exists(project)) {
        final previousSavedAt = await _fileSystem.modifiedAtUtc(project);
        await _fileSystem.deleteIfExists(previous);
        await _fileSystem.copy(project, previous);
        await _fileSystem.setModifiedAtUtc(previous, previousSavedAt);
      } else {
        await _fileSystem.deleteIfExists(previous);
      }
      await _fileSystem.rename(temporary, project);
    } catch (error) {
      if (temporary != null) await _bestEffortDelete(temporary);
      throw ProjectSaveFailure(project, error);
    }
  }

  Future<Uri?> resolveSource(Uri project, SourceReference source) async {
    final projectDirectory = p.dirname(project.toFilePath());
    final relative = Uri.file(
      p.normalize(p.join(projectDirectory, source.relativePath)),
    );
    final absolute = Uri.file(source.absolutePath);

    for (final candidate in <Uri>{relative, absolute}) {
      try {
        if (!await _fileSystem.exists(candidate)) continue;
        final actual = await _fingerprinter.fingerprint(candidate);
        if (source.fingerprint.matches(actual)) return candidate;
      } on Object {
        // A single stale or unreadable candidate must not block relocation.
      }
    }
    return null;
  }

  Future<bool> matchesSource(Uri candidate, SourceReference source) async {
    if (!await _fileSystem.exists(candidate)) return false;
    return source.fingerprint.matches(
      await _fingerprinter.fingerprint(candidate),
    );
  }

  @override
  Future<RecoveryCandidate?> recoveryFor(Uri project) async {
    final target = await _readRecoveryCandidate(project);
    final previous = await _readRecoveryCandidate(
      _sibling(project, '.previous'),
    );
    if (target == null) return previous;
    if (previous == null) return target;
    return previous.savedAtUtc.isAfter(target.savedAtUtc) ? previous : target;
  }

  Future<RecoveryCandidate?> _readRecoveryCandidate(Uri uri) async {
    try {
      if (!await _fileSystem.exists(uri)) return null;
      return RecoveryCandidate(
        uri,
        await _fileSystem.modifiedAtUtc(uri),
        await load(uri),
      );
    } on Object {
      return null;
    }
  }

  Future<Uri> _reserveTemporary(Uri project) async {
    for (var attempt = 0; attempt < 16; attempt++) {
      final bytes = _randomBytes.nextBytes(16);
      if (bytes.length != 16 || bytes.any((byte) => byte < 0 || byte > 255)) {
        throw StateError('Random source returned invalid temp suffix bytes');
      }
      final suffix = bytes
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();
      final candidate = _sibling(project, '.tmp-$suffix');
      if (await _fileSystem.createExclusive(candidate)) return candidate;
    }
    throw StateError('Could not reserve a unique project temp file');
  }

  Uri _sibling(Uri project, String suffix) =>
      Uri.file('${project.toFilePath()}$suffix');

  Future<void> _bestEffortDelete(Uri file) async {
    try {
      await _fileSystem.deleteIfExists(file);
    } on Object {
      // Preserve the original save error. A stale temp is safe to ignore.
    }
  }
}
