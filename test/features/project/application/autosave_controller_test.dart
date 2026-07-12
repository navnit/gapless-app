import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/core/errors/app_failure.dart';
import 'package:gapless/features/project/application/autosave_controller.dart';
import 'package:gapless/features/project/data/project_codec.dart';
import 'package:gapless/features/project/data/project_repository.dart';
import 'package:gapless/features/project/domain/project_document.dart';

void main() {
  late Uri path;
  late ProjectDocument first;
  late ProjectDocument second;
  late FakeAutosaveClock clock;

  setUp(() {
    path = Uri.file('/projects/edit.gapless');
    first = ProjectCodec().decode(_fixtureJson);
    second = ProjectDocument(
      schemaVersion: first.schemaVersion,
      appVersion: '0.2.0',
      source: first.source,
      settings: first.settings,
      detectedSegments: first.detectedSegments,
      manualOverrides: first.manualOverrides,
      ui: first.ui,
    );
    clock = FakeAutosaveClock();
  });

  test('debounces changes with a deterministic clock', () async {
    final store = RecordingProjectStore();
    final controller = _controller(path, store, clock);

    controller.markChanged(first);
    clock.elapse(const Duration(milliseconds: 999));
    await _pumpAsync();
    expect(store.saved, isEmpty);

    controller.markChanged(second);
    clock.elapse(const Duration(milliseconds: 999));
    await _pumpAsync();
    expect(store.saved, isEmpty);

    clock.elapse(const Duration(milliseconds: 1));
    await _pumpAsync();
    expect(store.saved, [second]);
    expect(controller.status, isA<AutosaveSaved>());
    expect((controller.status as AutosaveSaved).revision, 2);
  });

  test('flush bypasses the debounce and waits for persistence', () async {
    final store = RecordingProjectStore();
    final controller = _controller(path, store, clock);
    controller.markChanged(first);

    await controller.flush();

    expect(store.saved, [first]);
    expect(clock.activeTimerCount, 0);
    expect(controller.status, const AutosaveSaved(1));
  });

  test('only the current revision can become saved during a race', () async {
    final store = ControlledProjectStore();
    final controller = _controller(path, store, clock);

    controller.markChanged(first);
    clock.elapse(const Duration(seconds: 1));
    await _pumpAsync();
    expect(store.started, [first]);

    controller.markChanged(second);
    clock.elapse(const Duration(seconds: 1));
    store.completeNext();
    await _pumpAsync();

    expect(controller.status, isNot(const AutosaveSaved(1)));
    expect(store.started, [first, second]);

    store.completeNext();
    await _pumpAsync();
    expect(controller.status, const AutosaveSaved(2));
  });

  test(
    'save failure keeps the in-memory document and exposes failure',
    () async {
      final failure = ProjectSaveFailure(path, StateError('disk full'));
      final store = RecordingProjectStore(failure: failure);
      final controller = _controller(path, store, clock);
      controller.markChanged(first);

      await controller.flush();

      expect(controller.document, first);
      expect(
        controller.status,
        isA<AutosaveFailed>()
            .having((status) => status.revision, 'revision', 1)
            .having((status) => status.failure, 'failure', same(failure)),
      );
    },
  );

  test('source-list mutation cannot change pending autosave content', () async {
    final detected = first.detectedSegments.toList();
    final overrides = first.manualOverrides.toList();
    final document = ProjectDocument(
      schemaVersion: first.schemaVersion,
      appVersion: first.appVersion,
      source: first.source,
      settings: first.settings,
      detectedSegments: detected,
      manualOverrides: overrides,
      ui: first.ui,
    );
    final store = RecordingProjectStore();
    final controller = _controller(path, store, clock);
    controller.markChanged(document);

    detected.clear();
    overrides.clear();
    await controller.flush();

    expect(store.saved.single, first);
  });

  test('newer change can save after an earlier failure', () async {
    final store = ControlledProjectStore();
    final controller = _controller(path, store, clock);
    controller.markChanged(first);
    final firstFlush = controller.flush();
    await _pumpAsync();
    store.failNext(ProjectSaveFailure(path, StateError('disk full')));
    await firstFlush;
    expect(controller.status, isA<AutosaveFailed>());

    controller.markChanged(second);
    final secondFlush = controller.flush();
    await _pumpAsync();
    store.completeNext();
    await secondFlush;

    expect(controller.document, second);
    expect(controller.status, const AutosaveSaved(2));
  });

  test('stale failure completion cannot overwrite newer revision', () async {
    final store = ControlledProjectStore();
    final controller = _controller(path, store, clock);
    controller.markChanged(first);
    clock.elapse(const Duration(seconds: 1));
    await _pumpAsync();

    controller.markChanged(second);
    clock.elapse(const Duration(seconds: 1));
    store.failNext(ProjectSaveFailure(path, StateError('old failure')));
    await _pumpAsync();

    expect(controller.status, isNot(isA<AutosaveFailed>()));
    expect(store.started, [first, second]);
    store.completeNext();
    await _pumpAsync();
    expect(controller.status, const AutosaveSaved(2));
  });

  test('flush queues the current revision behind an older write', () async {
    final store = ControlledProjectStore();
    final controller = _controller(path, store, clock);
    controller.markChanged(first);
    clock.elapse(const Duration(seconds: 1));
    await _pumpAsync();
    controller.markChanged(second);

    final flushed = controller.flush();
    store.completeNext();
    await _pumpAsync();
    expect(store.started, [first, second]);
    store.completeNext();
    await flushed;

    expect(controller.status, const AutosaveSaved(2));
  });

  test('dispose cancels debounce and rejects subsequent work', () async {
    final store = RecordingProjectStore();
    final controller = _controller(path, store, clock);
    controller.markChanged(first);

    await controller.dispose();
    clock.elapse(const Duration(seconds: 1));
    await _pumpAsync();

    expect(store.saved, isEmpty);
    expect(clock.activeTimerCount, 0);
    expect(controller.status, const AutosaveDisposed());
    expect(() => controller.markChanged(second), throwsStateError);
    expect(() => controller.flush(), throwsStateError);
  });

  test(
    'dispose awaits in-flight save without post-dispose status changes',
    () async {
      final store = ControlledProjectStore();
      final controller = _controller(path, store, clock);
      controller.markChanged(first);
      final flush = controller.flush();
      await _pumpAsync();

      final dispose = controller.dispose();
      expect(controller.status, const AutosaveDisposed());
      store.completeNext();
      await flush;
      await dispose;

      expect(controller.status, const AutosaveDisposed());
      expect(store.started, [first]);
    },
  );
}

AutosaveController _controller(
  Uri path,
  ProjectStore store,
  AutosaveClock clock,
) => AutosaveController(
  project: path,
  store: store,
  delay: const Duration(seconds: 1),
  clock: clock,
);

Future<void> _pumpAsync() async {
  await Future<void>.value();
  await Future<void>.value();
  await Future<void>.value();
}

final class FakeAutosaveClock implements AutosaveClock {
  Duration _elapsed = Duration.zero;
  final List<_FakeTimer> _timers = [];

  int get activeTimerCount => _timers.where((timer) => timer.isActive).length;

  void elapse(Duration duration) {
    _elapsed += duration;
    final due = _timers
        .where((timer) => timer.isActive && timer.due <= _elapsed)
        .toList();
    for (final timer in due) {
      timer.fire();
    }
  }

  @override
  AutosaveTimer schedule(Duration delay, void Function() callback) {
    final timer = _FakeTimer(_elapsed + delay, callback);
    _timers.add(timer);
    return timer;
  }
}

final class _FakeTimer implements AutosaveTimer {
  _FakeTimer(this.due, this._callback);

  final Duration due;
  final void Function() _callback;
  bool _active = true;

  @override
  bool get isActive => _active;

  @override
  void cancel() => _active = false;

  void fire() {
    if (!_active) return;
    _active = false;
    _callback();
  }
}

class RecordingProjectStore implements ProjectStore {
  RecordingProjectStore({this.failure});

  final AppFailure? failure;
  final List<ProjectDocument> saved = [];

  @override
  Future<ProjectDocument> load(Uri project) => throw UnimplementedError();

  @override
  Future<RecoveryCandidate?> recoveryFor(Uri project) async => null;

  @override
  Future<void> saveAtomic(Uri project, ProjectDocument document) async {
    saved.add(document);
    if (failure case final failure?) throw failure;
  }
}

final class ControlledProjectStore implements ProjectStore {
  final List<ProjectDocument> started = [];
  final List<Completer<void>> _pending = [];

  void completeNext() => _pending.removeAt(0).complete();
  void failNext(Object error) => _pending.removeAt(0).completeError(error);

  @override
  Future<ProjectDocument> load(Uri project) => throw UnimplementedError();

  @override
  Future<RecoveryCandidate?> recoveryFor(Uri project) async => null;

  @override
  Future<void> saveAtomic(Uri project, ProjectDocument document) {
    started.add(document);
    final completer = Completer<void>();
    _pending.add(completer);
    return completer.future;
  }
}

const _fixtureJson = '''
{"schemaVersion":1,"appVersion":"0.1.0","source":{"relativePath":"media/interview.mp4","absolutePath":"/original/interview.mp4","size":10,"modifiedAt":"2026-07-11T00:00:00.000Z","fingerprint":"sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"},"settings":{"method":"audio","thresholdDb":-19.0,"marginBeforeUs":200000,"marginAfterUs":200000,"inactiveAction":"cut","fastForwardRate":4.0},"detectedSegments":[{"startUs":0,"endUs":1000000,"action":"keep","rate":1.0}],"manualOverrides":[],"ui":{"previewMode":"edited","timelineZoom":1.0,"sidebarWidth":264.0,"waveformHeight":52.0}}
''';
