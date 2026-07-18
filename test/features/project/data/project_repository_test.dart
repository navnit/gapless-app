import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/core/errors/app_failure.dart';
import 'package:gapless/features/project/data/project_codec.dart';
import 'package:gapless/features/project/data/project_repository.dart';
import 'package:gapless/features/project/domain/project_document.dart';
import 'package:gapless/features/project/domain/source_reference.dart';

void main() {
  late ProjectDocument oldProject;
  late ProjectDocument newProject;
  late Uri path;

  setUp(() {
    final codec = ProjectCodec();
    oldProject = codec.decode(_fixtureJson);
    newProject = codec.decode(
      _fixtureJson.replaceFirst('"appVersion":"0.1.0"', '"appVersion":"0.2.0"'),
    );
    path = Uri.file('/projects/edit.gapless');
  });

  test('local source reader completes a range read before closing', () async {
    final directory = await Directory.systemTemp.createTemp(
      'gapless-source-reader-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/source.bin');
    await source.writeAsBytes(List<int>.generate(32, (index) => index));

    const reader = LocalSourceSampleReader();

    expect(await reader.readRange(source.uri, 7, 5), <int>[7, 8, 9, 10, 11]);
  });

  group('ProjectRepository atomic persistence', () {
    test('failed promotion leaves the previous project readable', () async {
      final fs = FakeProjectFileSystem(failOnPromote: true);
      final repository = _repository(fs);
      fs.seed(path, utf8.encode(ProjectCodec().encode(oldProject)));

      await expectLater(
        repository.saveAtomic(path, newProject),
        throwsA(isA<ProjectSaveFailure>()),
      );

      expect(await repository.load(path), oldProject);
    });

    test('retains exactly one previous valid revision', () async {
      final fs = FakeProjectFileSystem();
      final repository = _repository(fs);
      fs.seed(path, utf8.encode(ProjectCodec().encode(oldProject)));

      await repository.saveAtomic(path, newProject);

      expect(
        ProjectCodec().decode(utf8.decode(fs.bytes(_previous(path)))),
        oldProject,
      );
      expect(fs.uris.where((uri) => uri.path.contains('.previous')).toList(), [
        _previous(path),
      ]);
    });

    test('uses a 32-character hexadecimal random temporary suffix', () async {
      final fs = FakeProjectFileSystem();
      final repository = _repository(fs);

      await repository.saveAtomic(path, oldProject);

      final temporary = fs.written.single;
      expect(
        temporary.path,
        '/projects/edit.gapless.tmp-000102030405060708090a0b0c0d0e0f',
      );
      expect(RegExp(r'\.tmp-[0-9a-f]{32}$').hasMatch(temporary.path), isTrue);
    });

    test('wraps random temp-name generation failures', () async {
      final fs = FakeProjectFileSystem();
      final repository = _repository(fs, randomBytes: ThrowingRandomBytes());

      await expectLater(
        repository.saveAtomic(path, oldProject),
        throwsA(
          isA<ProjectSaveFailure>().having(
            (failure) => failure.cause,
            'cause',
            isA<StateError>(),
          ),
        ),
      );
    });

    test('reserves a unique temp name and retries collisions', () async {
      final fs = FakeProjectFileSystem();
      final collided = Uri.file(
        '/projects/edit.gapless.tmp-000102030405060708090a0b0c0d0e0f',
      );
      fs.seed(collided, [99]);
      final repository = _repository(fs, randomBytes: SequenceRandomBytes());

      await repository.saveAtomic(path, oldProject);

      expect(fs.bytes(collided), [99]);
      expect(fs.exclusiveReservations, [
        collided,
        Uri.file('/projects/edit.gapless.tmp-101112131415161718191a1b1c1d1e1f'),
      ]);
      expect(
        fs.written.single.path,
        '/projects/edit.gapless.tmp-101112131415161718191a1b1c1d1e1f',
      );
    });

    test('deletes a stale previous when target does not exist', () async {
      final fs = FakeProjectFileSystem();
      fs.seed(_previous(path), utf8.encode(ProjectCodec().encode(newProject)));

      await _repository(fs).saveAtomic(path, oldProject);

      expect(await fs.exists(_previous(path)), isFalse);
      expect(await _repository(fs).load(path), oldProject);
    });

    test('preserves original revision time when copying previous', () async {
      final originalTime = DateTime.utc(2026, 1, 1);
      final fs = FakeProjectFileSystem(copiedAtUtc: DateTime.utc(2026, 1, 10));
      fs.seed(
        path,
        utf8.encode(ProjectCodec().encode(oldProject)),
        modifiedAtUtc: originalTime,
      );

      await _repository(fs).saveAtomic(path, newProject);

      expect(await fs.modifiedAtUtc(_previous(path)), originalTime);
      expect((await _repository(fs).recoveryFor(path))?.uri, path);
    });

    test('recovery selects the newest readable revision', () async {
      final fs = FakeProjectFileSystem();
      final repository = _repository(fs);
      fs.seed(
        path,
        utf8.encode(ProjectCodec().encode(oldProject)),
        modifiedAtUtc: DateTime.utc(2026, 1, 1),
      );
      fs.seed(
        _previous(path),
        utf8.encode(ProjectCodec().encode(newProject)),
        modifiedAtUtc: DateTime.utc(2026, 1, 2),
      );

      final recovery = await repository.recoveryFor(path);

      expect(recovery?.uri, _previous(path));
      expect(recovery?.document, newProject);
      expect(recovery?.savedAtUtc, DateTime.utc(2026, 1, 2));
    });

    test('recovery skips a newer malformed revision', () async {
      final fs = FakeProjectFileSystem();
      final repository = _repository(fs);
      fs.seed(
        path,
        utf8.encode(ProjectCodec().encode(oldProject)),
        modifiedAtUtc: DateTime.utc(2026, 1, 1),
      );
      fs.seed(
        _previous(path),
        utf8.encode('{'),
        modifiedAtUtc: DateTime.utc(2026, 1, 2),
      );

      expect((await repository.recoveryFor(path))?.uri, path);
    });

    test('recovery deterministically prefers target on equal times', () async {
      final fs = FakeProjectFileSystem();
      final sameTime = DateTime.utc(2026, 1, 1);
      fs.seed(
        path,
        utf8.encode(ProjectCodec().encode(newProject)),
        modifiedAtUtc: sameTime,
      );
      fs.seed(
        _previous(path),
        utf8.encode(ProjectCodec().encode(oldProject)),
        modifiedAtUtc: sameTime,
      );

      final recovery = await _repository(fs).recoveryFor(path);

      expect(recovery?.uri, path);
      expect(recovery?.document, newProject);
    });
  });

  group('ProjectRepository source resolution', () {
    test(
      'tries the project-relative source before the absolute fallback',
      () async {
        final fs = FakeProjectFileSystem();
        final relative = Uri.file('/projects/media/interview.mp4');
        final absolute = Uri.file('/original/interview.mp4');
        fs.seed(relative, [1]);
        fs.seed(absolute, [2]);
        final fingerprinter = FakeFingerprinter({
          relative: _sameFingerprint(oldProject, modifiedDay: 12),
          absolute: _sameFingerprint(oldProject, modifiedDay: 13),
        });
        final reference = SourceReference(
          relativePath: 'media/interview.mp4',
          absolutePath: absolute.toFilePath(),
          fingerprint: oldProject.source.fingerprint,
        );

        final resolved = await _repository(
          fs,
          fingerprinter: fingerprinter,
        ).resolveSource(path, reference);

        expect(resolved, relative);
        expect(fingerprinter.calls, [relative]);
      },
    );

    test('falls back to the absolute source after relative mismatch', () async {
      final fs = FakeProjectFileSystem();
      final relative = Uri.file('/projects/media/interview.mp4');
      final absolute = Uri.file('/original/interview.mp4');
      fs.seed(relative, [1]);
      fs.seed(absolute, [2]);
      final fingerprinter = FakeFingerprinter({
        relative: SourceFingerprint(
          size: 99,
          modifiedAtUtc: _epoch,
          sampledSha256: 'bad',
        ),
        absolute: _sameFingerprint(oldProject, modifiedDay: 14),
      });
      final reference = SourceReference(
        relativePath: 'media/interview.mp4',
        absolutePath: absolute.toFilePath(),
        fingerprint: oldProject.source.fingerprint,
      );

      final resolved = await _repository(
        fs,
        fingerprinter: fingerprinter,
      ).resolveSource(path, reference);

      expect(resolved, absolute);
      expect(fingerprinter.calls, [relative, absolute]);
    });

    test('rejects both paths when sampled identity mismatches', () async {
      final fs = FakeProjectFileSystem();
      final relative = Uri.file('/projects/media/interview.mp4');
      final absolute = Uri.file('/original/interview.mp4');
      fs.seed(relative, [1]);
      fs.seed(absolute, [2]);
      final mismatch = SourceFingerprint(
        size: oldProject.source.fingerprint.size,
        modifiedAtUtc: oldProject.source.fingerprint.modifiedAtUtc,
        sampledSha256: 'f' * 64,
      );
      final reference = SourceReference(
        relativePath: 'media/interview.mp4',
        absolutePath: absolute.toFilePath(),
        fingerprint: oldProject.source.fingerprint,
      );

      final resolved = await _repository(
        fs,
        fingerprinter: FakeFingerprinter({
          relative: mismatch,
          absolute: mismatch,
        }),
      ).resolveSource(path, reference);

      expect(resolved, isNull);
    });

    test(
      'candidate-local fingerprint error still tries absolute path',
      () async {
        final fs = FakeProjectFileSystem();
        final relative = Uri.file('/projects/media/interview.mp4');
        final absolute = Uri.file('/original/interview.mp4');
        fs.seed(relative, [1]);
        fs.seed(absolute, [2]);
        final fingerprinter = FakeFingerprinter({
          relative: StateError('relative file disappeared'),
          absolute: _sameFingerprint(oldProject, modifiedDay: 14),
        });

        final resolved = await _repository(
          fs,
          fingerprinter: fingerprinter,
        ).resolveSource(path, oldProject.source);

        expect(resolved, absolute);
        expect(fingerprinter.calls, [relative, absolute]);
      },
    );

    test('candidate-local exists error still tries absolute path', () async {
      final relative = Uri.file('/projects/media/interview.mp4');
      final absolute = Uri.file('/original/interview.mp4');
      final fs = FakeProjectFileSystem(
        existsFailures: {relative: StateError('relative stat failed')},
      );
      fs.seed(absolute, [2]);
      final fingerprinter = FakeFingerprinter({
        absolute: _sameFingerprint(oldProject, modifiedDay: 14),
      });

      final resolved = await _repository(
        fs,
        fingerprinter: fingerprinter,
      ).resolveSource(path, oldProject.source);

      expect(resolved, absolute);
      expect(fingerprinter.calls, [absolute]);
    });

    test('size and sampled SHA identity ignores mtime-only changes', () {
      final stored = oldProject.source.fingerprint;
      final copied = _sameFingerprint(oldProject, modifiedDay: 31);

      expect(stored.modifiedAtUtc, isNot(copied.modifiedAtUtc));
      expect(stored.matches(copied), isTrue);
    });
  });

  group('SampledSourceFingerprinter', () {
    test('reads bounded blocks from the beginning, middle, and end', () async {
      final reader = FakeSourceSampleReader(
        size: 1000,
        modifiedAtUtc: DateTime.utc(2026, 1, 1),
      );
      final fingerprinter = SampledSourceFingerprinter(
        reader: reader,
        sampleSize: 100,
      );

      final result = await fingerprinter.fingerprint(Uri.file('/large.mp4'));

      expect(reader.reads, [(0, 100), (450, 100), (900, 100)]);
      expect(reader.reads.fold<int>(0, (sum, read) => sum + read.$2), 300);
      expect(result.size, 1000);
      expect(result.sampledSha256, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test(
      'uses stable framed digests for empty through large sources',
      () async {
        final cases = <(int, List<(int, int)>, String)>[
          (
            0,
            const [],
            '374708fff7719dd5979ec875d56cd2286f6d3cf7ec317a3b25632aab28ec37bb',
          ),
          (
            3,
            const [(0, 3)],
            'b5ba34507d93f976355e681f92dd9f9aca2d28f1184a01afd02dde23a58a9cbe',
          ),
          (
            6,
            const [(0, 4), (1, 4), (2, 4)],
            'a55da341f8a482bcee618ecbf6a141ce878d0747fc2d34501a9e794f50309706',
          ),
          (
            12,
            const [(0, 4), (4, 4), (8, 4)],
            '2490f4e3b59dea45ea414ff442168e9ad89a40a15c72a390636c50a91bd66416',
          ),
        ];

        for (final (size, reads, digest) in cases) {
          final reader = FakeSourceSampleReader(
            size: size,
            modifiedAtUtc: DateTime.utc(2026, 1, 1),
          );

          final result = await SampledSourceFingerprinter(
            reader: reader,
            sampleSize: 4,
          ).fingerprint(Uri.file('/source-$size.mp4'));

          expect(reader.reads, reads, reason: 'sample reads for size $size');
          expect(result.sampledSha256, digest, reason: 'digest for size $size');
        }
      },
    );
  });
}

ProjectRepository _repository(
  FakeProjectFileSystem fs, {
  SourceFingerprinter? fingerprinter,
  RandomBytes? randomBytes,
}) => ProjectRepository(
  fileSystem: fs,
  fingerprinter: fingerprinter ?? FakeFingerprinter(const {}),
  randomBytes: randomBytes ?? FixedRandomBytes(),
);

SourceFingerprint _sameFingerprint(
  ProjectDocument project, {
  required int modifiedDay,
}) => SourceFingerprint(
  size: project.source.fingerprint.size,
  modifiedAtUtc: DateTime.utc(2026, 7, modifiedDay),
  sampledSha256: project.source.fingerprint.sampledSha256,
);

Uri _previous(Uri project) => Uri.file('${project.toFilePath()}.previous');

final _epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

final class FixedRandomBytes implements RandomBytes {
  @override
  List<int> nextBytes(int length) => List.generate(length, (index) => index);
}

final class ThrowingRandomBytes implements RandomBytes {
  @override
  List<int> nextBytes(int length) => throw StateError('random unavailable');
}

final class SequenceRandomBytes implements RandomBytes {
  var _call = 0;

  @override
  List<int> nextBytes(int length) {
    final start = _call++ * length;
    return List.generate(length, (index) => start + index);
  }
}

final class FakeFingerprinter implements SourceFingerprinter {
  FakeFingerprinter(this.results);

  final Map<Uri, Object> results;
  final List<Uri> calls = [];

  @override
  Future<SourceFingerprint> fingerprint(Uri source) async {
    calls.add(source);
    final result = results[source]!;
    if (result is SourceFingerprint) return result;
    throw result;
  }
}

final class FakeSourceSampleReader implements SourceSampleReader {
  FakeSourceSampleReader({required this.size, required this.modifiedAtUtc});

  final int size;
  final DateTime modifiedAtUtc;
  final List<(int, int)> reads = [];

  @override
  Future<SourceFileMetadata> metadata(Uri source) async =>
      SourceFileMetadata(size: size, modifiedAtUtc: modifiedAtUtc);

  @override
  Future<List<int>> readRange(Uri source, int offset, int length) async {
    reads.add((offset, length));
    return List.generate(length, (index) => (offset + index) & 0xff);
  }
}

final class FakeProjectFileSystem implements ProjectFileSystem {
  FakeProjectFileSystem({
    this.failOnPromote = false,
    this.copiedAtUtc,
    this.existsFailures = const {},
  });

  final bool failOnPromote;
  final DateTime? copiedAtUtc;
  final Map<Uri, Object> existsFailures;
  final Map<Uri, Uint8List> _files = {};
  final Map<Uri, DateTime> _modified = {};
  final List<Uri> written = [];
  final List<Uri> exclusiveReservations = [];

  Iterable<Uri> get uris => _files.keys;
  List<int> bytes(Uri uri) => _files[uri]!;

  void seed(Uri uri, List<int> bytes, {DateTime? modifiedAtUtc}) {
    _files[uri] = Uint8List.fromList(bytes);
    _modified[uri] = modifiedAtUtc ?? _epoch;
  }

  @override
  Future<void> copy(Uri from, Uri to) async {
    seed(to, _files[from]!, modifiedAtUtc: copiedAtUtc ?? _modified[from]);
  }

  @override
  Future<bool> createExclusive(Uri file) async {
    exclusiveReservations.add(file);
    if (_files.containsKey(file)) return false;
    seed(file, const []);
    return true;
  }

  @override
  Future<void> deleteIfExists(Uri file) async {
    _files.remove(file);
    _modified.remove(file);
  }

  @override
  Future<bool> exists(Uri file) async {
    final failure = existsFailures[file];
    if (failure != null) throw failure;
    return _files.containsKey(file);
  }

  @override
  Future<DateTime> modifiedAtUtc(Uri file) async => _modified[file]!;

  @override
  Future<void> setModifiedAtUtc(Uri file, DateTime modifiedAtUtc) async {
    _modified[file] = modifiedAtUtc;
  }

  @override
  Future<List<int>> readBytes(Uri file) async => bytes(file);

  @override
  Future<void> rename(Uri from, Uri to) async {
    if (failOnPromote && to == pathForFailure) {
      throw StateError('injected promotion failure');
    }
    final bytes = _files.remove(from)!;
    final modified = _modified.remove(from)!;
    seed(to, bytes, modifiedAtUtc: modified);
  }

  Uri get pathForFailure => Uri.file('/projects/edit.gapless');

  @override
  Future<void> writeAndFlush(Uri file, List<int> bytes) async {
    written.add(file);
    seed(file, bytes, modifiedAtUtc: DateTime.utc(2026, 1, 3));
  }
}

const _fixtureJson = '''
{"schemaVersion":1,"appVersion":"0.1.0","source":{"relativePath":"media/interview.mp4","absolutePath":"/original/interview.mp4","size":10,"modifiedAt":"2026-07-11T00:00:00.000Z","fingerprint":"sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"},"settings":{"method":"audio","thresholdDb":-19.0,"marginBeforeUs":200000,"marginAfterUs":200000,"inactiveAction":"cut","fastForwardRate":4.0},"detectedSegments":[{"startUs":0,"endUs":1000000,"action":"keep","rate":1.0}],"manualOverrides":[],"ui":{"previewMode":"edited","timelineZoom":1.0,"sidebarWidth":264.0,"waveformHeight":52.0}}
''';
