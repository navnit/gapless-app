import 'dart:async';

import 'package:gapless/core/errors/app_failure.dart';
import 'package:gapless/features/project/data/project_repository.dart';
import 'package:gapless/features/project/domain/project_document.dart';

sealed class AutosaveStatus {
  const AutosaveStatus();
}

final class AutosaveIdle extends AutosaveStatus {
  const AutosaveIdle();

  @override
  bool operator ==(Object other) => other is AutosaveIdle;

  @override
  int get hashCode => runtimeType.hashCode;
}

final class AutosaveSaving extends AutosaveStatus {
  const AutosaveSaving(this.revision);

  final int revision;

  @override
  bool operator ==(Object other) =>
      other is AutosaveSaving && revision == other.revision;

  @override
  int get hashCode => Object.hash(AutosaveSaving, revision);
}

final class AutosaveSaved extends AutosaveStatus {
  const AutosaveSaved(this.revision);

  final int revision;

  @override
  bool operator ==(Object other) =>
      other is AutosaveSaved && revision == other.revision;

  @override
  int get hashCode => Object.hash(AutosaveSaved, revision);
}

final class AutosaveFailed extends AutosaveStatus {
  const AutosaveFailed(this.revision, this.failure);

  final int revision;
  final AppFailure failure;

  @override
  bool operator ==(Object other) =>
      other is AutosaveFailed &&
      revision == other.revision &&
      failure == other.failure;

  @override
  int get hashCode => Object.hash(AutosaveFailed, revision, failure);
}

abstract interface class AutosaveTimer {
  bool get isActive;
  void cancel();
}

abstract interface class AutosaveClock {
  AutosaveTimer schedule(Duration delay, void Function() callback);
}

final class SystemAutosaveClock implements AutosaveClock {
  const SystemAutosaveClock();

  @override
  AutosaveTimer schedule(Duration delay, void Function() callback) =>
      _SystemAutosaveTimer(Timer(delay, callback));
}

final class _SystemAutosaveTimer implements AutosaveTimer {
  const _SystemAutosaveTimer(this._timer);

  final Timer _timer;

  @override
  bool get isActive => _timer.isActive;

  @override
  void cancel() => _timer.cancel();
}

final class AutosaveController {
  AutosaveController({
    required this.project,
    required this.store,
    required this.delay,
    this.clock = const SystemAutosaveClock(),
  });

  final Uri project;
  final ProjectStore store;
  final Duration delay;
  final AutosaveClock clock;

  ProjectDocument? _document;
  ProjectDocument? get document => _document;

  AutosaveStatus _status = const AutosaveIdle();
  AutosaveStatus get status => _status;

  int _revision = 0;
  AutosaveTimer? _timer;
  Future<void> _tail = Future<void>.value();
  final Map<int, Future<void>> _pending = {};

  void markChanged(ProjectDocument document) {
    _document = document;
    _revision += 1;
    _status = const AutosaveIdle();
    _timer?.cancel();
    _timer = clock.schedule(delay, () {
      _timer = null;
      unawaited(_requestSave(_revision, _document!));
    });
  }

  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    final document = _document;
    if (document == null) return _tail;
    return _requestSave(_revision, document);
  }

  Future<void> _requestSave(int revision, ProjectDocument document) {
    final existing = _pending[revision];
    if (existing != null) return existing;

    final requested = _tail.then((_) => _performSave(revision, document));
    _tail = requested;
    _pending[revision] = requested;
    unawaited(
      requested.whenComplete(() {
        if (identical(_pending[revision], requested)) {
          _pending.remove(revision);
        }
      }),
    );
    return requested;
  }

  Future<void> _performSave(int revision, ProjectDocument document) async {
    if (revision != _revision) return;
    _status = AutosaveSaving(revision);
    try {
      await store.saveAtomic(project, document);
      if (revision == _revision) {
        _status = AutosaveSaved(revision);
      }
    } catch (error) {
      if (revision == _revision) {
        _status = AutosaveFailed(
          revision,
          error is AppFailure ? error : ProjectSaveFailure(project, error),
        );
      }
    }
  }
}
