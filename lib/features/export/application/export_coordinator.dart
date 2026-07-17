import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:gapless/core/errors/app_failure.dart';
import 'package:gapless/features/editor/domain/effective_timeline.dart';
import 'package:gapless/features/engine/domain/engine_models.dart';
import 'package:gapless/features/engine/domain/engine_port.dart';
import 'package:path/path.dart' as path;

final class ExportRequest {
  const ExportRequest({
    required this.source,
    required this.metadata,
    required this.timeline,
    required this.destination,
    required this.preset,
  });

  final Uri source;
  final MediaMetadata metadata;
  final EffectiveTimeline timeline;
  final Uri destination;
  final RenderPreset preset;
}

sealed class ExportState {
  const ExportState();
}

final class ExportChoosing extends ExportState {
  const ExportChoosing();
}

final class ExportRunning extends ExportState {
  const ExportRunning(this.stage, this.percent, this.eta);

  final EngineStage stage;
  final double? percent;
  final Duration? eta;
}

final class ExportComplete extends ExportState {
  const ExportComplete(this.output, {this.recoveryBackup});

  final Uri output;
  final Uri? recoveryBackup;
}

final class ExportFailed extends ExportState {
  const ExportFailed(this.failure, {this.recoveryBackup});

  final AppFailure failure;
  final Uri? recoveryBackup;
}

final class ExportFileSystemFailure implements Exception {
  const ExportFileSystemFailure(this.message, {this.recoveryBackup});

  final String message;
  final Uri? recoveryBackup;

  @override
  String toString() => message;
}

final class PromotionCommitResult {
  const PromotionCommitResult({this.recoveryBackup});

  final Uri? recoveryBackup;
}

abstract interface class ExportWorkspace {
  Uri get directory;
  Uri get partial;
  Uri get backup;
}

abstract interface class ExportPromotion {
  Future<PromotionCommitResult> commit();
  Future<void> rollback();
}

abstract interface class ExportFileSystem {
  Future<bool> identifiesSameFile(Uri first, Uri second);
  Future<void> validateDestination(Uri destination);
  Future<ExportWorkspace> createWorkspace({
    required Uri destination,
    required String operationId,
  });
  Future<void> flush(ExportWorkspace workspace);
  Future<void> cleanupWorkspace(ExportWorkspace workspace);

  /// Moves the workspace partial into [destination] while retaining the
  /// previous destination until the transaction is committed or rolled back.
  Future<ExportPromotion> stagePromotion({
    required ExportWorkspace workspace,
    required Uri destination,
  });
}

final class LocalExportFileSystem implements ExportFileSystem {
  const LocalExportFileSystem();

  @override
  Future<bool> identifiesSameFile(Uri first, Uri second) async {
    final firstPath = _pathIdentity(first.toFilePath());
    final secondPath = _pathIdentity(second.toFilePath());
    if (firstPath == secondPath) return true;
    final firstFile = File(first.toFilePath());
    final secondFile = File(second.toFilePath());
    if (!await firstFile.exists() || !await secondFile.exists()) return false;
    try {
      return await FileSystemEntity.identical(firstFile.path, secondFile.path);
    } on FileSystemException {
      return false;
    }
  }

  @override
  Future<void> validateDestination(Uri destination) async {
    final destinationPath = destination.toFilePath();
    final parent = Directory(path.dirname(destinationPath));
    if (!await parent.exists()) {
      throw FileSystemException(
        'The export folder does not exist',
        parent.path,
      );
    }
    final type = await FileSystemEntity.type(
      destinationPath,
      followLinks: true,
    );
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw FileSystemException(
        'The export destination is not a regular file',
        destinationPath,
      );
    }
  }

  @override
  Future<ExportWorkspace> createWorkspace({
    required Uri destination,
    required String operationId,
  }) async {
    final destinationPath = destination.toFilePath();
    final parent = Directory(path.dirname(destinationPath));
    final stem = path.basenameWithoutExtension(destinationPath);
    final safeOperationId = _validatedOperationId(operationId);
    for (var attempt = 0; attempt < 32; attempt++) {
      final directory = await parent.createTemp(
        '.$stem.gapless-$safeOperationId-',
      );
      final workspaceName = path.basename(directory.path);
      final partial = Uri.file(
        path.join(directory.path, '$stem.edited.partial.mp4'),
        windows: Platform.isWindows,
      );
      final backup = Uri.file(
        path.join(parent.path, '$stem.edited.backup-$workspaceName.mp4'),
        windows: Platform.isWindows,
      );
      if (!await File(backup.toFilePath()).exists()) {
        return _LocalExportWorkspace(
          directory: Uri.directory(
            directory.absolute.path,
            windows: Platform.isWindows,
          ),
          partial: partial,
          backup: backup,
        );
      }
      await directory.delete();
    }
    throw FileSystemException(
      'Could not create a unique export workspace',
      parent.path,
    );
  }

  @override
  Future<void> flush(ExportWorkspace workspace) async {
    final owned = _requireLocalWorkspace(workspace);
    final local = File(owned.partial.toFilePath());
    if (!await local.exists()) {
      throw FileSystemException('The rendered partial is missing', local.path);
    }
    final opened = await local.open(mode: FileMode.append);
    try {
      await opened.flush();
    } finally {
      await opened.close();
    }
  }

  @override
  Future<void> cleanupWorkspace(ExportWorkspace workspace) async {
    final owned = _requireLocalWorkspace(workspace);
    if (owned.cleaned) return;
    final partial = File(owned.partial.toFilePath());
    if (await partial.exists()) await partial.delete();
    final directory = Directory(owned.directory.toFilePath());
    if (await directory.exists()) await directory.delete();
    owned.cleaned = true;
  }

  @override
  Future<ExportPromotion> stagePromotion({
    required ExportWorkspace workspace,
    required Uri destination,
  }) async {
    final owned = _requireLocalWorkspace(workspace);
    if (owned.cleaned) {
      throw StateError('A cleaned export workspace cannot be promoted');
    }
    final partial = owned.partial;
    final backup = owned.backup;
    _validateDistinctPromotionPaths(partial, destination, backup);
    final partialFile = File(partial.toFilePath());
    final destinationFile = File(destination.toFilePath());
    final backupFile = File(backup.toFilePath());
    if (await backupFile.exists()) {
      throw ExportFileSystemFailure(
        'Refusing to reuse an existing export backup.',
      );
    }

    final hadPrevious = await destinationFile.exists();
    if (hadPrevious) await destinationFile.rename(backupFile.path);
    try {
      await partialFile.rename(destinationFile.path);
    } on Object catch (stagingError, stagingStack) {
      if (hadPrevious) {
        try {
          final recoveryBackup = await _restoreBackupToMissingDestination(
            backup: backupFile,
            destination: destinationFile,
          );
          if (recoveryBackup != null) {
            throw ExportFileSystemFailure(
              'Previous export restored, but its recovery copy remains.',
              recoveryBackup: recoveryBackup,
            );
          }
        } on ExportFileSystemFailure catch (recoveryError, recoveryStack) {
          if (!await destinationFile.exists()) {
            await _restorePromotedDestination(partialFile, destinationFile);
          }
          Error.throwWithStackTrace(recoveryError, recoveryStack);
        }
      }
      Error.throwWithStackTrace(stagingError, stagingStack);
    }

    return _LocalExportPromotion(
      partial: partialFile,
      destination: destinationFile,
      backup: backupFile,
      hadPrevious: hadPrevious,
    );
  }
}

final class _LocalExportWorkspace implements ExportWorkspace {
  _LocalExportWorkspace({
    required this.directory,
    required this.partial,
    required this.backup,
  });

  @override
  final Uri directory;
  @override
  final Uri partial;
  @override
  final Uri backup;
  var cleaned = false;
}

_LocalExportWorkspace _requireLocalWorkspace(ExportWorkspace workspace) {
  if (workspace is _LocalExportWorkspace) return workspace;
  throw ArgumentError.value(
    workspace,
    'workspace',
    'LocalExportFileSystem requires its own workspace token',
  );
}

final class _LocalExportPromotion implements ExportPromotion {
  _LocalExportPromotion({
    required this.partial,
    required this.destination,
    required this.backup,
    required this.hadPrevious,
  });

  final File partial;
  final File destination;
  final File backup;
  final bool hadPrevious;
  _PromotionStatus _status = _PromotionStatus.staged;
  PromotionCommitResult? _commitResult;

  @override
  Future<PromotionCommitResult> commit() async {
    final previous = _commitResult;
    if (previous != null) return previous;
    if (_status != _PromotionStatus.staged) {
      throw StateError('A rolled-back export cannot be committed');
    }
    _status = _PromotionStatus.committed;
    if (!hadPrevious || !await backup.exists()) {
      return _commitResult = const PromotionCommitResult();
    }
    try {
      await backup.delete();
      return _commitResult = const PromotionCommitResult();
    } on Object {
      return _commitResult = PromotionCommitResult(
        recoveryBackup: Uri.file(backup.absolute.path),
      );
    }
  }

  @override
  Future<void> rollback() async {
    if (_status == _PromotionStatus.rolledBack) return;
    if (_status == _PromotionStatus.committed) {
      throw StateError('A committed export cannot be rolled back');
    }
    if (hadPrevious) {
      await _rollbackWithPrevious();
    } else {
      await _rollbackWithoutPrevious();
    }
    _status = _PromotionStatus.rolledBack;
  }

  Future<void> _rollbackWithPrevious() async {
    final recoveryUri = Uri.file(backup.absolute.path);
    try {
      await destination.rename(partial.path);
    } on Object catch (error) {
      throw ExportFileSystemFailure(
        'Could not move the new export aside during rollback: $error',
        recoveryBackup: recoveryUri,
      );
    }

    Uri? recoveryBackup;
    try {
      recoveryBackup = await _restoreBackupToMissingDestination(
        backup: backup,
        destination: destination,
      );
    } on Object catch (error) {
      await _restorePromotedDestination(partial, destination);
      throw ExportFileSystemFailure(
        'Could not restore the previous export: $error',
        recoveryBackup: recoveryUri,
      );
    }
    try {
      if (await partial.exists()) await partial.delete();
    } on Object catch (error) {
      throw ExportFileSystemFailure(
        'Previous export restored, but the cancelled partial remains: $error',
        recoveryBackup: recoveryBackup,
      );
    }
    if (recoveryBackup != null) {
      throw ExportFileSystemFailure(
        'Previous export restored, but its recovery copy remains.',
        recoveryBackup: recoveryBackup,
      );
    }
  }

  Future<void> _rollbackWithoutPrevious() async {
    try {
      await destination.rename(partial.path);
      await partial.delete();
    } on Object catch (error) {
      throw ExportFileSystemFailure(
        'Could not remove the cancelled promoted export: $error',
      );
    }
  }
}

enum _PromotionStatus { staged, committed, rolledBack }

Future<Uri?> _restoreBackupToMissingDestination({
  required File backup,
  required File destination,
}) async {
  try {
    await backup.rename(destination.path);
    return null;
  } on Object catch (renameError) {
    try {
      await backup.copy(destination.path);
    } on Object catch (copyError) {
      throw ExportFileSystemFailure(
        'Could not restore the previous export after rename and copy failures: '
        '$renameError; $copyError',
        recoveryBackup: Uri.file(backup.absolute.path),
      );
    }
  }

  try {
    await backup.delete();
  } on Object {
    return Uri.file(backup.absolute.path);
  }
  return null;
}

Future<void> _restorePromotedDestination(File partial, File destination) async {
  try {
    await partial.rename(destination.path);
  } on Object {
    try {
      await partial.copy(destination.path);
    } on Object {
      // The caller reports the retained recovery backup; never delete it here.
    }
  }
}

typedef ExportOperationId = String Function();

final class ExportCoordinator {
  ExportCoordinator({
    required this.engine,
    this.fileSystem = const LocalExportFileSystem(),
    ExportOperationId? operationId,
  }) : operationId = operationId ?? _secureOperationId {
    states = Stream<ExportState>.multi((events) {
      events.add(_state);
      final subscription = _stateChanges.stream.listen(
        events.add,
        onError: events.addError,
        onDone: events.close,
      );
      events.onCancel = subscription.cancel;
    }, isBroadcast: true);
  }

  final EnginePort engine;
  final ExportFileSystem fileSystem;
  final ExportOperationId operationId;

  late final Stream<ExportState> states;
  ExportState _state = const ExportChoosing();
  ExportState get state => _state;

  final StreamController<ExportState> _stateChanges =
      StreamController<ExportState>.broadcast(sync: true);
  _ExportRun? _active;
  Future<void>? _disposeFuture;
  var _generation = 0;
  var _disposed = false;

  Future<void> start(ExportRequest request) {
    try {
      _ensureActive();
      _validate(request);
      if (_active != null) throw StateError('An export is already running');
    } on Object catch (error, stack) {
      return Future<void>.error(error, stack);
    }

    final frozen = ExportRequest(
      source: request.source,
      metadata: request.metadata,
      timeline: EffectiveTimeline.compose(
        durationUs: request.timeline.durationUs,
        detected: request.timeline.segments.toList(growable: false),
        overrides: const [],
      ),
      destination: request.destination,
      preset: request.preset,
    );
    final run = _ExportRun(++_generation);
    _active = run;
    _publish(const ExportRunning(EngineStage.buildingTimeline, null, null));
    return _execute(run, frozen);
  }

  Future<void> cancel() {
    final run = _active;
    if (run == null) return Future<void>.value();
    if (run.commitPointReached) {
      return run.postCommitWait ??= _waitForTerminal(run);
    }
    final existing = run.cancellation;
    if (existing != null) return existing;
    run.cancelRequested = true;
    final future = _cancelBeforeCommit(run);
    run.cancellation = future;
    return future;
  }

  /// Returns a reusable idle coordinator to its chooser state.
  ///
  /// A running operation must be cancelled or completed before reset.
  void reset() {
    _ensureActive();
    if (_active != null) throw StateError('Cannot reset a running export');
    if (_state is! ExportChoosing) _publish(const ExportChoosing());
  }

  Future<void> dispose() {
    final existing = _disposeFuture;
    if (existing != null) return existing;
    _disposed = true;
    final future = _dispose();
    _disposeFuture = future;
    return future;
  }

  Future<void> _dispose() async {
    Object? failure;
    StackTrace? failureStack;
    try {
      final run = _active;
      if (run != null) await cancel();
    } on Object catch (error, stack) {
      failure = error;
      failureStack = stack;
    } finally {
      await _stateChanges.close();
    }
    if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
  }

  Future<void> _execute(_ExportRun run, ExportRequest request) async {
    ExportState terminal = const ExportChoosing();
    try {
      if (await fileSystem.identifiesSameFile(
        request.source,
        request.destination,
      )) {
        throw ArgumentError.value(
          request.destination,
          'destination',
          'Export destination must not be the source video',
        );
      }
      await fileSystem.validateDestination(request.destination);
      final workspace = await fileSystem.createWorkspace(
        destination: request.destination,
        operationId: _validatedOperationId(operationId()),
      );
      run.workspace = workspace;
      if (run.cancelRequested) {
        throw const OperationCancelled(operation: 'export');
      }

      final task = engine.render(
        RenderRequest(
          source: request.source,
          metadata: request.metadata,
          timeline: request.timeline,
          partialDestination: workspace.partial,
          preset: request.preset,
        ),
      );
      run.task = task;
      run.progress = task.progress.listen((progress) {
        if (_canPublish(run)) {
          _publish(
            ExportRunning(progress.stage, progress.percent, progress.eta),
          );
        }
      }, onError: (_) {});
      final rendered = await task.result;
      run.engineFinished = true;
      await _cancelProgressWithoutMasking(run);
      if (run.cancelRequested) {
        throw const OperationCancelled(operation: 'export');
      }
      if (rendered != workspace.partial) {
        throw EngineContractFailure(
          operation: 'export',
          reason: EngineContractReason.invalidOutput,
          diagnostics: const ['Engine returned an unowned output path.'],
        );
      }

      await fileSystem.flush(workspace);
      if (run.cancelRequested) {
        throw const OperationCancelled(operation: 'export');
      }
      final promotion = await fileSystem.stagePromotion(
        workspace: workspace,
        destination: request.destination,
      );
      if (run.cancelRequested) {
        try {
          await promotion.rollback();
          terminal = const ExportChoosing();
        } on Object catch (error) {
          final mapped = _mapFailure(error);
          terminal = ExportFailed(
            mapped.failure,
            recoveryBackup: mapped.recoveryBackup,
          );
          run.terminalFailure = mapped.failure;
        }
      } else {
        run.commitPointReached = true;
        final committed = await promotion.commit();
        terminal = ExportComplete(
          request.destination,
          recoveryBackup: committed.recoveryBackup,
        );
      }
    } on Object catch (error) {
      if (run.cancelRequested && error is OperationCancelled) {
        terminal = const ExportChoosing();
      } else {
        final mapped = _mapFailure(error);
        terminal = ExportFailed(
          mapped.failure,
          recoveryBackup: mapped.recoveryBackup,
        );
        run.terminalFailure = mapped.failure;
      }
    } finally {
      run.engineFinished = true;
      await _cancelProgressWithoutMasking(run);
      final workspace = run.workspace;
      if (workspace != null) {
        try {
          await fileSystem.cleanupWorkspace(workspace);
        } on Object catch (cleanupError) {
          final failure = _cleanupFailure(workspace, cleanupError);
          terminal = ExportFailed(
            failure,
            recoveryBackup: _terminalRecoveryBackup(terminal),
          );
          run.terminalFailure = failure;
        }
      }
      final terminalFailure = run.terminalFailure;
      if (terminalFailure != null && terminal is ExportChoosing) {
        terminal = ExportFailed(terminalFailure);
      }
      if (identical(_active, run)) {
        _active = null;
        if (!_disposed) _publish(terminal);
      }
      if (!run.done.isCompleted) run.done.complete();
    }
  }

  Future<void> _cancelBeforeCommit(_ExportRun run) async {
    if (!run.engineFinished) {
      final task = run.task;
      if (task != null) {
        try {
          await task.cancel();
        } on Object catch (error) {
          run.terminalFailure ??= _mapFailure(error).failure;
        }
      }
    }
    await _cancelProgressWithoutMasking(run);
    await _waitForTerminal(run);
  }

  Future<void> _waitForTerminal(_ExportRun run) async {
    await run.done.future;
    final failure = run.terminalFailure;
    if (failure != null) throw failure;
  }

  bool _canPublish(_ExportRun run) =>
      !_disposed &&
      !run.cancelRequested &&
      run.generation == _generation &&
      identical(_active, run);

  Future<void> _cancelProgressWithoutMasking(_ExportRun run) async {
    final progress = run.progress;
    run.progress = null;
    if (progress == null) return;
    try {
      unawaited(progress.cancel().catchError((_) {}));
    } on Object {
      // Engine cancellation remains the quiescence boundary for publication.
    }
  }

  void _publish(ExportState next) {
    _state = next;
    if (!_stateChanges.isClosed) _stateChanges.add(next);
  }

  void _ensureActive() {
    if (_disposed) throw StateError('ExportCoordinator is disposed');
  }
}

final class _ExportRun {
  _ExportRun(this.generation);

  final int generation;
  final done = Completer<void>();
  EngineTask<Uri>? task;
  StreamSubscription<EngineProgress>? progress;
  Future<void>? cancellation;
  Future<void>? postCommitWait;
  AppFailure? terminalFailure;
  ExportWorkspace? workspace;
  var cancelRequested = false;
  var engineFinished = false;
  var commitPointReached = false;
}

void _validate(ExportRequest request) {
  if (!_isAbsoluteLocalFile(request.source)) {
    throw ArgumentError.value(request.source, 'source');
  }
  if (!_isAbsoluteLocalFile(request.destination)) {
    throw ArgumentError.value(request.destination, 'destination');
  }
  if (path.extension(request.destination.toFilePath()).toLowerCase() !=
      '.mp4') {
    throw ArgumentError.value(
      request.destination,
      'destination',
      'Gapless exports MP4 files only',
    );
  }
  if (_pathIdentity(request.source.toFilePath()) ==
      _pathIdentity(request.destination.toFilePath())) {
    throw ArgumentError.value(
      request.destination,
      'destination',
      'Export destination must not be the source video',
    );
  }
  if (request.timeline.durationUs != request.metadata.durationUs) {
    throw ArgumentError.value(request.timeline.durationUs, 'timeline');
  }
}

bool _isAbsoluteLocalFile(Uri uri) {
  if (!uri.isScheme('file') || uri.hasQuery || uri.hasFragment) return false;
  try {
    return path.isAbsolute(uri.toFilePath());
  } on Object {
    return false;
  }
}

String _pathIdentity(String value) {
  final normalized = path.normalize(path.absolute(value));
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}

void _validateDistinctPromotionPaths(Uri partial, Uri destination, Uri backup) {
  final identities = <String>{
    _pathIdentity(partial.toFilePath()),
    _pathIdentity(destination.toFilePath()),
    _pathIdentity(backup.toFilePath()),
  };
  if (identities.length != 3) {
    throw ArgumentError('Export promotion paths must be distinct');
  }
}

({AppFailure failure, Uri? recoveryBackup}) _mapFailure(Object error) {
  if (error is AppFailure) return (failure: error, recoveryBackup: null);
  final recoveryBackup = error is ExportFileSystemFailure
      ? error.recoveryBackup
      : null;
  return (
    failure: EngineContractFailure(
      operation: 'export',
      reason: EngineContractReason.invalidOutput,
      diagnostics: <String>[_boundedMessage(error)],
    ),
    recoveryBackup: recoveryBackup,
  );
}

Uri? _terminalRecoveryBackup(ExportState state) {
  if (state is ExportComplete) return state.recoveryBackup;
  if (state is ExportFailed) return state.recoveryBackup;
  return null;
}

AppFailure _cleanupFailure(ExportWorkspace workspace, Object error) =>
    EngineContractFailure(
      operation: 'export-cleanup',
      reason: EngineContractReason.invalidOutput,
      diagnostics: <String>[
        _boundedMessage(
          'Could not clean export workspace '
          '${workspace.directory.toFilePath()}: $error',
        ),
      ],
    );

String _boundedMessage(Object error) {
  const limit = 240;
  final message = error.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  final safe = message.isEmpty ? 'Export failed unexpectedly.' : message;
  return safe.length <= limit ? safe : safe.substring(0, limit);
}

String _validatedOperationId(String id) {
  final value = id.trim();
  if (value.isEmpty ||
      value.length > 80 ||
      !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value)) {
    throw ArgumentError.value(id, 'operationId');
  }
  return value;
}

String _secureOperationId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}
