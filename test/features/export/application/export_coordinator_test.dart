import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/core/errors/app_failure.dart';
import 'package:gapless/core/time/source_time_range.dart';
import 'package:gapless/features/editor/domain/analysis_settings.dart';
import 'package:gapless/features/editor/domain/effective_timeline.dart';
import 'package:gapless/features/editor/domain/timeline_segment.dart';
import 'package:gapless/features/engine/domain/engine_models.dart';
import 'package:gapless/features/engine/domain/engine_port.dart';
import 'package:gapless/features/export/application/export_coordinator.dart';
import 'package:path/path.dart' as path;

void main() {
  late _ControlledEngine engine;
  late _MemoryExportFileSystem fileSystem;
  late List<String> operationIds;
  late ExportCoordinator coordinator;

  setUp(() {
    engine = _ControlledEngine();
    fileSystem = _MemoryExportFileSystem();
    operationIds = <String>['first-operation', 'second-operation'];
    coordinator = ExportCoordinator(
      engine: engine,
      fileSystem: fileSystem,
      operationId: () => operationIds.removeAt(0),
    );
  });

  tearDown(() async {
    await coordinator.dispose();
  });

  test(
    'renders an exact frozen timeline and promotes only after success',
    () async {
      final originalTimeline = _timeline(cutStartUs: 600000);
      var callerTimeline = originalTimeline;
      final destination = Uri.file('/exports/interview.mp4');

      final completion = coordinator.start(
        _request(timeline: callerTimeline, destination: destination),
      );
      callerTimeline = _timeline(cutStartUs: 300000);
      await _pump();

      final render = engine.renderCalls.single;
      expect(render.timeline.durationUs, originalTimeline.durationUs);
      expect(render.timeline.segments, originalTimeline.segments);
      expect(render.timeline.segments, isNot(callerTimeline.segments));
      expect(render.partialDestination, isNot(destination));
      expect(
        render.partialDestination.pathSegments.last,
        'interview.edited.partial.mp4',
      );
      expect(
        render.partialDestination.path,
        contains('/.interview.gapless-first-operation/'),
      );
      expect(
        fileSystem.files,
        isNot(contains(render.partialDestination)),
        reason: 'EnginePort.render requires a vacant partial path',
      );
      expect(fileSystem.stages, isEmpty);

      fileSystem.files[render.partialDestination] = 'new export';
      engine.tasks.single.complete(render.partialDestination);
      await completion;

      expect(fileSystem.flushed, <Uri>[render.partialDestination]);
      expect(fileSystem.files[destination], 'new export');
      expect(fileSystem.files, isNot(contains(render.partialDestination)));
      expect(fileSystem.cleanedWorkspaces, hasLength(1));
      expect(coordinator.state, isA<ExportComplete>());
    },
  );

  test(
    'render failure preserves the target and removes only owned files',
    () async {
      final destination = Uri.file('/exports/interview.mp4');
      final unrelated = Uri.file('/exports/interview.partial-existing.mp4');
      fileSystem.files[destination] = 'old export';
      fileSystem.files[unrelated] = 'unrelated';

      final completion = coordinator.start(_request(destination: destination));
      await _pump();
      final partial = engine.renderCalls.single.partialDestination;
      fileSystem.files[partial] = 'incomplete';
      engine.tasks.single.fail(
        EngineContractFailure(
          operation: 'render',
          reason: EngineContractReason.unexpectedExit,
        ),
      );
      await completion;

      expect(fileSystem.files[destination], 'old export');
      expect(fileSystem.files[unrelated], 'unrelated');
      expect(fileSystem.files, isNot(contains(partial)));
      final state = coordinator.state as ExportFailed;
      expect(state.failure, isA<EngineContractFailure>());
    },
  );

  test(
    'cancellation awaits engine quiescence and preserves the target',
    () async {
      final destination = Uri.file('/exports/interview.mp4');
      fileSystem.files[destination] = 'old export';
      final completion = coordinator.start(_request(destination: destination));
      await _pump();
      final task = engine.tasks.single..holdCancellation();
      final partial = engine.renderCalls.single.partialDestination;
      fileSystem.files[partial] = 'incomplete';

      var cancelled = false;
      final cancellation = coordinator.cancel().then((_) => cancelled = true);
      await _pump();
      expect(task.cancelCount, 1);
      expect(cancelled, isFalse);

      task.releaseCancellation();
      await cancellation;
      await completion;

      expect(cancelled, isTrue);
      expect(fileSystem.files[destination], 'old export');
      expect(fileSystem.files, isNot(contains(partial)));
      expect(coordinator.state, isA<ExportChoosing>());
    },
  );

  test('promotion failure rolls back an existing target', () async {
    final destination = Uri.file('/exports/interview.mp4');
    fileSystem.files[destination] = 'old export';
    fileSystem.failStage = true;
    final completion = coordinator.start(_request(destination: destination));
    await _pump();
    final render = engine.renderCalls.single;
    fileSystem.files[render.partialDestination] = 'new export';
    engine.tasks.single.complete(render.partialDestination);

    await completion;

    expect(fileSystem.files[destination], 'old export');
    expect(fileSystem.files, isNot(contains(render.partialDestination)));
    expect(
      fileSystem.files.keys.map((file) => file.path),
      isNot(contains(contains('.backup-'))),
    );
    expect(coordinator.state, isA<ExportFailed>());
  });

  test('cleanup failure preserves a stage recovery backup', () async {
    final destination = Uri.file('/exports/interview.mp4');
    fileSystem
      ..files[destination] = 'old export'
      ..failStageWithRecoveryBackup = true
      ..failWorkspaceCleanup = true;
    final completion = coordinator.start(_request(destination: destination));
    await _pump();
    final render = engine.renderCalls.single;
    fileSystem.files[render.partialDestination] = 'new export';
    engine.tasks.single.complete(render.partialDestination);

    await completion;

    final failed = coordinator.state as ExportFailed;
    expect(
      (failed.failure as EngineContractFailure).operation,
      'export-cleanup',
    );
    expect(failed.recoveryBackup, isNotNull);
    expect(fileSystem.files[failed.recoveryBackup], 'old export');
    expect(fileSystem.files[render.partialDestination], 'new export');
  });

  test('cancel during staged promotion rolls back before commit', () async {
    final destination = Uri.file('/exports/interview.mp4');
    fileSystem
      ..files[destination] = 'old export'
      ..holdStage = true;
    final completion = coordinator.start(_request(destination: destination));
    await _pump();
    final render = engine.renderCalls.single;
    fileSystem.files[render.partialDestination] = 'new export';
    engine.tasks.single.complete(render.partialDestination);
    await fileSystem.stageEntered.future;

    var cancelled = false;
    final cancellation = coordinator.cancel().then((_) => cancelled = true);
    await _pump();
    expect(cancelled, isFalse);
    expect(engine.tasks.single.cancelCount, 0);

    fileSystem.releaseStage();
    await Future.wait<void>(<Future<void>>[completion, cancellation]);
    expect(fileSystem.files[destination], 'old export');
    expect(fileSystem.transactions.single.rollbackCount, 1);
    expect(fileSystem.transactions.single.commitCount, 0);
    expect(coordinator.state, isA<ExportChoosing>());
  });

  test('cancel after the commit point waits for completed export', () async {
    final destination = Uri.file('/exports/interview.mp4');
    fileSystem
      ..files[destination] = 'old export'
      ..holdCommit = true;
    final completion = coordinator.start(_request(destination: destination));
    await _pump();
    final render = engine.renderCalls.single;
    fileSystem.files[render.partialDestination] = 'new export';
    engine.tasks.single.complete(render.partialDestination);
    await fileSystem.commitEntered.future;

    var cancellationReturned = false;
    final cancellation = coordinator.cancel().then(
      (_) => cancellationReturned = true,
    );
    await _pump();
    expect(cancellationReturned, isFalse);
    expect(engine.tasks.single.cancelCount, 0);

    fileSystem.releaseCommit();
    await Future.wait<void>(<Future<void>>[completion, cancellation]);
    expect(fileSystem.files[destination], 'new export');
    expect(coordinator.state, isA<ExportComplete>());
  });

  test(
    'commit failure keeps valid output and reports recovery backup',
    () async {
      final destination = Uri.file('/exports/interview.mp4');
      fileSystem
        ..files[destination] = 'old export'
        ..failCommit = true;
      final completion = coordinator.start(_request(destination: destination));
      await _pump();
      final render = engine.renderCalls.single;
      fileSystem.files[render.partialDestination] = 'new export';
      engine.tasks.single.complete(render.partialDestination);
      await completion;

      final failed = coordinator.state as ExportFailed;
      expect(fileSystem.files[destination], 'new export');
      expect(fileSystem.files[failed.recoveryBackup], 'old export');
      expect(failed.recoveryBackup, isNotNull);
    },
  );

  test(
    'rollback failure is observable and retains a recovery backup',
    () async {
      final destination = Uri.file('/exports/interview.mp4');
      fileSystem
        ..files[destination] = 'old export'
        ..holdStage = true
        ..failRollback = true;
      final completion = coordinator.start(_request(destination: destination));
      await _pump();
      final render = engine.renderCalls.single;
      fileSystem.files[render.partialDestination] = 'new export';
      engine.tasks.single.complete(render.partialDestination);
      await fileSystem.stageEntered.future;

      final cancellation = coordinator.cancel();
      fileSystem.releaseStage();
      await expectLater(cancellation, throwsA(isA<AppFailure>()));
      await completion;

      final failed = coordinator.state as ExportFailed;
      expect(fileSystem.files[destination], 'new export');
      expect(fileSystem.files[failed.recoveryBackup], 'old export');
    },
  );

  test('backup cleanup warning keeps promoted destination valid', () async {
    final destination = Uri.file('/exports/interview.mp4');
    fileSystem
      ..files[destination] = 'old export'
      ..retainBackupOnCommit = true;
    final completion = coordinator.start(_request(destination: destination));
    await _pump();
    final render = engine.renderCalls.single;
    fileSystem.files[render.partialDestination] = 'new export';
    engine.tasks.single.complete(render.partialDestination);
    await completion;

    final complete = coordinator.state as ExportComplete;
    expect(fileSystem.files[destination], 'new export');
    expect(fileSystem.files[complete.recoveryBackup], 'old export');
  });

  test('reset starts a fresh chooser only after a terminal state', () async {
    final completion = coordinator.start(_request());
    await _pump();
    final render = engine.renderCalls.single;
    fileSystem.files[render.partialDestination] = 'new export';
    engine.tasks.single.complete(render.partialDestination);
    await completion;
    expect(coordinator.state, isA<ExportComplete>());

    coordinator.reset();

    expect(coordinator.state, isA<ExportChoosing>());
  });

  test(
    'wrong engine output path fails without deleting unowned output',
    () async {
      final completion = coordinator.start(_request());
      await _pump();
      final owned = engine.renderCalls.single.partialDestination;
      final unowned = Uri.file('/exports/unowned.mp4');
      fileSystem.files[owned] = 'owned partial';
      fileSystem.files[unowned] = 'unowned output';
      engine.tasks.single.complete(unowned);
      await completion;

      expect(coordinator.state, isA<ExportFailed>());
      expect(fileSystem.files, isNot(contains(owned)));
      expect(fileSystem.files[unowned], 'unowned output');
      expect(fileSystem.stages, isEmpty);
    },
  );

  test('cancelled operation cannot overwrite a newer export state', () async {
    final firstCompletion = coordinator.start(
      _request(destination: Uri.file('/exports/first.mp4')),
    );
    await _pump();
    final staleTask = engine.tasks.single;
    await coordinator.cancel();
    await firstCompletion;

    final secondDestination = Uri.file('/exports/second.mp4');
    final secondCompletion = coordinator.start(
      _request(destination: secondDestination),
    );
    await _pump();
    staleTask.emit(EngineProgress(stage: EngineStage.writing, percent: 99));
    final currentTask = engine.tasks.last;
    currentTask.emit(EngineProgress(stage: EngineStage.rendering, percent: 20));
    await _pump();

    final running = coordinator.state as ExportRunning;
    expect(running.stage, EngineStage.rendering);
    expect(running.percent, 20);

    final partial = engine.renderCalls.last.partialDestination;
    fileSystem.files[partial] = 'second export';
    currentTask.complete(partial);
    await secondCompletion;
    expect((coordinator.state as ExportComplete).output, secondDestination);
  });

  test('rejects concurrent start deterministically', () async {
    final first = coordinator.start(_request());
    await _pump();

    await expectLater(
      coordinator.start(
        _request(destination: Uri.file('/exports/another.mp4')),
      ),
      throwsStateError,
    );
    expect(engine.renderCalls, hasLength(1));

    await coordinator.cancel();
    await first;
  });

  test(
    'rejects invalid paths and duration before starting the engine',
    () async {
      final invalidRequests = <ExportRequest>[
        _request(source: Uri.parse('https://example.com/interview.mp4')),
        _request(destination: Uri.parse('https://example.com/export.mp4')),
        _request(destination: Uri(path: 'relative.mp4')),
        _request(destination: Uri.file('/exports/interview.mov')),
        _request(
          metadata: _metadata(durationUs: 900000),
          timeline: _timeline(),
        ),
      ];

      for (final request in invalidRequests) {
        await expectLater(coordinator.start(request), throwsArgumentError);
      }
      expect(engine.renderCalls, isEmpty);
      expect(fileSystem.claimed, isEmpty);
    },
  );

  test(
    'rejects exact and normalized source destinations before engine work',
    () async {
      final source = Uri.file('/videos/interview.mp4');
      final aliases = <Uri>[
        source,
        Uri.file('/videos/nested/../interview.mp4'),
      ];

      for (final destination in aliases) {
        await expectLater(
          coordinator.start(_request(source: source, destination: destination)),
          throwsArgumentError,
        );
      }
      expect(engine.renderCalls, isEmpty);
      expect(fileSystem.claimed, isEmpty);
    },
  );

  test('workspace cleanup never deletes a foreign sibling', () async {
    final completion = coordinator.start(_request());
    await _pump();
    final partial = engine.renderCalls.single.partialDestination;
    final foreign = Uri.file(
      '/exports/interview.edited.partial-first-operation.mp4',
    );
    fileSystem.files[foreign] = 'foreign file created after reservation';
    fileSystem.files[partial] = 'incomplete export';
    engine.tasks.single.fail(StateError('render failed'));

    await completion;

    expect(fileSystem.files[foreign], 'foreign file created after reservation');
    expect(fileSystem.files, isNot(contains(partial)));
    expect(fileSystem.cleanedWorkspaces, hasLength(1));
  });

  test('unavailable destination fails before engine render starts', () async {
    final destination = Uri.file('/read-only/interview.mp4');
    fileSystem.unavailable.add(destination);

    await coordinator.start(_request(destination: destination));

    expect(engine.renderCalls, isEmpty);
    expect(fileSystem.claimed, isEmpty);
    expect(coordinator.state, isA<ExportFailed>());
  });

  test(
    'unknown failures are bounded while AppFailure identity is preserved',
    () async {
      final first = coordinator.start(_request());
      await _pump();
      engine.tasks.single.fail(
        StateError(List<String>.filled(1000, 'x').join()),
      );
      await first;
      final mapped = (coordinator.state as ExportFailed).failure;
      expect(mapped, isA<EngineContractFailure>());
      expect(
        (mapped as EngineContractFailure).diagnostics.single.length,
        lessThanOrEqualTo(240),
      );

      final known = DiskFullFailure(
        destination: Uri.file('/exports/interview.mp4'),
      );
      final second = coordinator.start(_request());
      await _pump();
      engine.tasks.last.fail(known);
      await second;
      expect((coordinator.state as ExportFailed).failure, same(known));
    },
  );

  test('render failure reports an owned-partial cleanup failure', () async {
    final destination = Uri.file('/exports/interview.mp4');
    fileSystem
      ..files[destination] = 'old export'
      ..failWorkspaceCleanup = true;
    final completion = coordinator.start(_request(destination: destination));
    await _pump();
    final partial = engine.renderCalls.single.partialDestination;
    fileSystem.files[partial] = 'incomplete';
    engine.tasks.single.fail(StateError('render failed'));
    await completion;

    final failed = coordinator.state as ExportFailed;
    expect(fileSystem.files[partial], 'incomplete');
    expect(fileSystem.files[destination], 'old export');
    expect(
      (failed.failure as EngineContractFailure).operation,
      'export-cleanup',
    );
  });

  test('cancel throws when its owned partial cannot be removed', () async {
    final completion = coordinator.start(_request());
    await _pump();
    final partial = engine.renderCalls.single.partialDestination;
    fileSystem
      ..files[partial] = 'incomplete'
      ..failWorkspaceCleanup = true;

    await expectLater(coordinator.cancel(), throwsA(isA<AppFailure>()));
    await completion;
    expect(fileSystem.files[partial], 'incomplete');
    expect(coordinator.state, isA<ExportFailed>());
  });

  test('dispose throws when its owned partial cannot be removed', () async {
    final disposeEngine = _ControlledEngine();
    final disposeFiles = _MemoryExportFileSystem();
    final disposable = ExportCoordinator(
      engine: disposeEngine,
      fileSystem: disposeFiles,
      operationId: () => 'dispose-operation',
    );
    final completion = disposable.start(_request());
    await _pump();
    final partial = disposeEngine.renderCalls.single.partialDestination;
    disposeFiles
      ..files[partial] = 'incomplete'
      ..failWorkspaceCleanup = true;

    await expectLater(disposable.dispose(), throwsA(isA<AppFailure>()));
    await completion;
    expect(disposeFiles.files[partial], 'incomplete');
    await expectLater(disposable.start(_request()), throwsStateError);
  });

  test('dispose is idempotent and waits until the task is quiescent', () async {
    final completion = coordinator.start(_request());
    await _pump();
    final task = engine.tasks.single..holdCancellation();

    var disposed = false;
    final first = coordinator.dispose().then((_) => disposed = true);
    final second = coordinator.dispose();
    await _pump();
    expect(task.cancelCount, 1);
    expect(disposed, isFalse);

    task.releaseCancellation();
    await Future.wait<void>(<Future<void>>[first, second, completion]);
    expect(disposed, isTrue);
    expect(task.cancelCount, 1);
    await expectLater(coordinator.start(_request()), throwsStateError);
  });

  test('local filesystem stages and commits a replacement safely', () async {
    final directory = await Directory.systemTemp.createTemp('gapless-export-');
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final destination = File('${directory.path}/interview.mp4');
    await destination.writeAsString('old export');
    const local = LocalExportFileSystem();
    final workspace = await local.createWorkspace(
      destination: _fileUri(destination),
      operationId: 'commit-operation',
    );
    final partial = File.fromUri(workspace.partial);
    final backup = File.fromUri(workspace.backup);
    await partial.writeAsString('new export');

    final promotion = await local.stagePromotion(
      workspace: workspace,
      destination: _fileUri(destination),
    );
    expect(await destination.readAsString(), 'new export');
    expect(await backup.readAsString(), 'old export');

    final result = await promotion.commit();
    expect(result.recoveryBackup, isNull);
    expect(await destination.readAsString(), 'new export');
    expect(await backup.exists(), isFalse);
    await local.cleanupWorkspace(workspace);
    expect(await _workspaceDirectory(workspace).exists(), isFalse);
  });

  test('local filesystem staged rollback restores previous bytes', () async {
    final directory = await Directory.systemTemp.createTemp('gapless-export-');
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final destination = File('${directory.path}/interview.mp4');
    await destination.writeAsString('old export');
    const local = LocalExportFileSystem();
    final workspace = await local.createWorkspace(
      destination: _fileUri(destination),
      operationId: 'rollback-operation',
    );
    final partial = File.fromUri(workspace.partial);
    final backup = File.fromUri(workspace.backup);
    await partial.writeAsString('new export');

    final promotion = await local.stagePromotion(
      workspace: workspace,
      destination: _fileUri(destination),
    );
    await promotion.rollback();

    expect(await destination.readAsString(), 'old export');
    expect(await partial.exists(), isFalse);
    expect(await backup.exists(), isFalse);
    await local.cleanupWorkspace(workspace);
    expect(await _workspaceDirectory(workspace).exists(), isFalse);
  });

  test('local filesystem restores target when initial staging fails', () async {
    final directory = await Directory.systemTemp.createTemp('gapless-export-');
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final destination = File('${directory.path}/interview.mp4');
    await destination.writeAsString('old export');
    const local = LocalExportFileSystem();
    final workspace = await local.createWorkspace(
      destination: _fileUri(destination),
      operationId: 'failed-stage-operation',
    );
    final backup = File.fromUri(workspace.backup);

    await expectLater(
      local.stagePromotion(
        workspace: workspace,
        destination: _fileUri(destination),
      ),
      throwsA(anything),
    );

    expect(await destination.readAsString(), 'old export');
    expect(await backup.exists(), isFalse);
    await local.cleanupWorkspace(workspace);
    expect(await _workspaceDirectory(workspace).exists(), isFalse);
  });

  test(
    'local workspaces are unique, vacant, and clean only their namespace',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'gapless-export-',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final destination = File('${directory.path}/interview.mp4');
      final foreign = File('${directory.path}/foreign.partial.mp4');
      await foreign.writeAsString('foreign');
      const local = LocalExportFileSystem();
      final workspace = await local.createWorkspace(
        destination: _fileUri(destination),
        operationId: 'cleanup-operation',
      );
      final otherWorkspace = await local.createWorkspace(
        destination: _fileUri(destination),
        operationId: 'cleanup-operation',
      );
      final workspaceDirectory = _workspaceDirectory(workspace);
      expect(workspace.directory, isNot(otherWorkspace.directory));
      expect(workspace.backup, isNot(otherWorkspace.backup));
      expect(await File.fromUri(workspace.partial).exists(), isFalse);
      expect(await File.fromUri(otherWorkspace.partial).exists(), isFalse);
      await File.fromUri(workspace.partial).writeAsString('owned partial');

      expect(await workspaceDirectory.exists(), isTrue);
      await local.cleanupWorkspace(workspace);

      expect(await workspaceDirectory.exists(), isFalse);
      expect(await foreign.readAsString(), 'foreign');
      await local.cleanupWorkspace(otherWorkspace);
    },
  );

  test(
    'local cleanup never recursively removes unexpected workspace files',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'gapless-export-',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final destination = File('${directory.path}/interview.mp4');
      const local = LocalExportFileSystem();
      final workspace = await local.createWorkspace(
        destination: _fileUri(destination),
        operationId: 'unexpected-file-operation',
      );
      final workspaceDirectory = _workspaceDirectory(workspace);
      final unexpected = File('${workspaceDirectory.path}/unexpected.tmp');
      await File.fromUri(workspace.partial).writeAsString('owned partial');
      await unexpected.writeAsString('foreign');

      await expectLater(
        local.cleanupWorkspace(workspace),
        throwsA(isA<FileSystemException>()),
      );

      expect(await File.fromUri(workspace.partial).exists(), isFalse);
      expect(await unexpected.readAsString(), 'foreign');
      expect(await workspaceDirectory.exists(), isTrue);
    },
  );

  test('local workspace cleanup is idempotent', () async {
    final directory = await Directory.systemTemp.createTemp('gapless-export-');
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final destination = File('${directory.path}/interview.mp4');
    const local = LocalExportFileSystem();
    final workspace = await local.createWorkspace(
      destination: _fileUri(destination),
      operationId: 'idempotent-operation',
    );

    await local.cleanupWorkspace(workspace);
    await local.cleanupWorkspace(workspace);

    expect(await _workspaceDirectory(workspace).exists(), isFalse);
  });
}

Uri _fileUri(File file) => Uri.file(file.absolute.path);

Directory _workspaceDirectory(ExportWorkspace workspace) =>
    Directory.fromUri(workspace.directory);

ExportRequest _request({
  Uri? source,
  MediaMetadata? metadata,
  EffectiveTimeline? timeline,
  Uri? destination,
  RenderPreset preset = RenderPreset.balanced,
}) => ExportRequest(
  source: source ?? Uri.file('/videos/interview.mp4'),
  metadata: metadata ?? _metadata(),
  timeline: timeline ?? _timeline(),
  destination: destination ?? Uri.file('/exports/interview.mp4'),
  preset: preset,
);

MediaMetadata _metadata({int durationUs = 1000000}) => MediaMetadata(
  durationUs: durationUs,
  timebaseNumerator: 1,
  timebaseDenominator: 30,
  resolution: SizeInt(1920, 1080),
  videoCodec: 'h264',
  hasAudio: true,
  sampleRate: 48000,
  audioLayout: 'stereo',
);

EffectiveTimeline _timeline({int cutStartUs = 600000}) =>
    EffectiveTimeline.compose(
      durationUs: 1000000,
      detected: <TimelineSegment>[
        TimelineSegment(
          range: SourceTimeRange(0, cutStartUs),
          action: SegmentAction.keep,
          origin: SegmentOrigin.detected,
        ),
        TimelineSegment(
          range: SourceTimeRange(cutStartUs, 1000000),
          action: SegmentAction.cut,
          origin: SegmentOrigin.detected,
        ),
      ],
      overrides: const <TimelineSegment>[],
    );

Future<void> _pump() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

final class _ControlledEngine implements EnginePort {
  final renderCalls = <RenderRequest>[];
  final tasks = <_ControlledEngineTask<Uri>>[];

  @override
  EngineTask<Uri> render(RenderRequest request) {
    renderCalls.add(request);
    final task = _ControlledEngineTask<Uri>();
    tasks.add(task);
    return task;
  }

  @override
  EngineTask<DetectedTimeline> detect(Uri source, AnalysisSettings settings) =>
      throw UnimplementedError();

  @override
  EngineTask<AnalysisLevels> levels(Uri source, AnalysisMethod method) =>
      throw UnimplementedError();

  @override
  EngineTask<MediaMetadata> probe(Uri source) => throw UnimplementedError();
}

final class _ControlledEngineTask<T> implements EngineTask<T> {
  final _progress = StreamController<EngineProgress>.broadcast(sync: true);
  final _result = Completer<T>();
  Completer<void>? _cancellationGate;
  var cancelCount = 0;

  @override
  Stream<EngineProgress> get progress => _progress.stream;

  @override
  Future<T> get result => _result.future;

  void emit(EngineProgress progress) => _progress.add(progress);

  void complete(T value) {
    if (!_result.isCompleted) _result.complete(value);
  }

  void fail(Object error) {
    if (!_result.isCompleted) _result.completeError(error);
  }

  void holdCancellation() => _cancellationGate = Completer<void>();

  void releaseCancellation() => _cancellationGate?.complete();

  @override
  Future<void> cancel() async {
    cancelCount += 1;
    await _cancellationGate?.future;
    if (!_result.isCompleted) {
      _result.completeError(const OperationCancelled(operation: 'render'));
    }
  }
}

final class _MemoryExportFileSystem implements ExportFileSystem {
  final files = <Uri, String>{};
  final claimed = <Uri>[];
  final workspaces = <_MemoryWorkspace>[];
  final cleanedWorkspaces = <_MemoryWorkspace>[];
  final flushed = <Uri>[];
  final stages = <({Uri partial, Uri destination, Uri backup})>[];
  final transactions = <_MemoryPromotion>[];
  final unavailable = <Uri>{};
  final stageEntered = Completer<void>();
  final commitEntered = Completer<void>();
  Completer<void>? _stageGate;
  Completer<void>? _commitGate;
  var holdStage = false;
  var holdCommit = false;
  var failStage = false;
  var failStageWithRecoveryBackup = false;
  var failCommit = false;
  var failRollback = false;
  var retainBackupOnCommit = false;
  var failWorkspaceCleanup = false;

  @override
  Future<ExportWorkspace> createWorkspace({
    required Uri destination,
    required String operationId,
  }) async {
    final destinationPath = destination.toFilePath();
    final directoryPath = path.dirname(destinationPath);
    final stem = path.basenameWithoutExtension(destinationPath);
    final workspaceDirectory = Uri.directory(
      path.join(directoryPath, '.$stem.gapless-$operationId'),
    );
    final workspace = _MemoryWorkspace(
      directory: workspaceDirectory,
      partial: Uri.file(
        path.join(workspaceDirectory.toFilePath(), '$stem.edited.partial.mp4'),
      ),
      backup: Uri.file(
        path.join(directoryPath, '$stem.edited.backup-$operationId.mp4'),
      ),
    );
    workspaces.add(workspace);
    claimed.add(workspace.partial);
    return workspace;
  }

  @override
  Future<bool> identifiesSameFile(Uri first, Uri second) async =>
      first == second;

  @override
  Future<void> validateDestination(Uri destination) async {
    if (unavailable.contains(destination)) {
      throw FileSystemException(
        'Destination unavailable',
        destination.toFilePath(),
      );
    }
  }

  @override
  Future<void> cleanupWorkspace(ExportWorkspace workspace) async {
    final owned = workspace as _MemoryWorkspace;
    if (failWorkspaceCleanup) {
      throw FileSystemException(
        'Workspace cleanup failed',
        owned.directory.toFilePath(),
      );
    }
    files.remove(owned.partial);
    if (files.keys.any(owned.contains)) {
      throw FileSystemException(
        'Unexpected workspace contents',
        owned.directory.toFilePath(),
      );
    }
    cleanedWorkspaces.add(owned);
  }

  @override
  Future<void> flush(ExportWorkspace workspace) async {
    if (!files.containsKey(workspace.partial)) {
      throw StateError('missing partial');
    }
    flushed.add(workspace.partial);
  }

  @override
  Future<ExportPromotion> stagePromotion({
    required ExportWorkspace workspace,
    required Uri destination,
  }) async {
    final partial = workspace.partial;
    final backup = workspace.backup;
    stages.add((partial: partial, destination: destination, backup: backup));
    final previous = files[destination];
    if (previous != null) {
      files[backup] = previous;
      files.remove(destination);
    }
    if (failStageWithRecoveryBackup) {
      throw ExportFileSystemFailure(
        'Promotion failed with retained backup',
        recoveryBackup: previous == null ? null : backup,
      );
    }
    if (failStage) {
      if (previous != null) {
        files[destination] = files.remove(backup)!;
      }
      throw FileSystemException('Promotion failed', destination.toFilePath());
    }
    files[destination] = files.remove(partial)!;
    final transaction = _MemoryPromotion(
      owner: this,
      destination: destination,
      backup: backup,
      hadPrevious: previous != null,
    );
    transactions.add(transaction);
    if (holdStage) {
      _stageGate = Completer<void>();
      if (!stageEntered.isCompleted) stageEntered.complete();
      await _stageGate!.future;
    }
    return transaction;
  }

  void releaseStage() => _stageGate?.complete();

  void releaseCommit() => _commitGate?.complete();
}

final class _MemoryWorkspace implements ExportWorkspace {
  const _MemoryWorkspace({
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

  bool contains(Uri file) => file.path.startsWith(directory.path);
}

final class _MemoryPromotion implements ExportPromotion {
  _MemoryPromotion({
    required this.owner,
    required this.destination,
    required this.backup,
    required this.hadPrevious,
  });

  final _MemoryExportFileSystem owner;
  final Uri destination;
  final Uri backup;
  final bool hadPrevious;
  var commitCount = 0;
  var rollbackCount = 0;

  @override
  Future<PromotionCommitResult> commit() async {
    commitCount += 1;
    if (owner.holdCommit) {
      owner._commitGate = Completer<void>();
      if (!owner.commitEntered.isCompleted) owner.commitEntered.complete();
      await owner._commitGate!.future;
    }
    if (owner.failCommit) {
      throw ExportFileSystemFailure(
        'Commit failed',
        recoveryBackup: hadPrevious ? backup : null,
      );
    }
    if (hadPrevious && owner.retainBackupOnCommit) {
      return PromotionCommitResult(recoveryBackup: backup);
    }
    owner.files.remove(backup);
    return const PromotionCommitResult();
  }

  @override
  Future<void> rollback() async {
    rollbackCount += 1;
    if (owner.failRollback) {
      throw ExportFileSystemFailure(
        'Rollback failed',
        recoveryBackup: hadPrevious ? backup : null,
      );
    }
    if (hadPrevious) {
      owner.files[destination] = owner.files.remove(backup)!;
    } else {
      owner.files.remove(destination);
    }
  }
}
