import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/core/errors/app_failure.dart';
import 'package:gapless/core/time/source_time_range.dart';
import 'package:gapless/features/editor/domain/analysis_settings.dart';
import 'package:gapless/features/editor/domain/effective_timeline.dart';
import 'package:gapless/features/editor/domain/timeline_segment.dart';
import 'package:gapless/features/engine/domain/engine_models.dart';
import 'package:gapless/features/engine/domain/engine_port.dart';
import 'package:gapless/features/export/application/export_coordinator.dart';
import 'package:gapless/features/export/presentation/export_dialog.dart';
import 'package:path/path.dart' as path;

void main() {
  testWidgets('choose destination transitions through running to complete', (
    tester,
  ) async {
    final harness = _Harness();
    addTearDown(harness.dispose);
    await _showDialog(tester, harness);

    expect(find.text('Export MP4'), findsOneWidget);
    expect(find.text('Balanced'), findsOneWidget);
    expect(find.text('Export'), findsOneWidget);
    await tester.tap(find.text('Choose destination…'));
    await tester.pump();
    expect(find.text('/exports/interview.mp4'), findsOneWidget);

    await tester.tap(find.text('Export'));
    await tester.pump();
    expect(find.text('Preparing export…'), findsOneWidget);

    harness.engine.tasks.single.emit(
      EngineProgress(
        stage: EngineStage.rendering,
        percent: 42,
        eta: const Duration(seconds: 12),
      ),
    );
    await tester.pump();
    expect(find.text('Rendering video…'), findsOneWidget);
    expect(find.text('42%'), findsOneWidget);
    expect(find.text('About 12 seconds remaining'), findsOneWidget);

    final render = harness.engine.renderCalls.single;
    harness.fileSystem.files[render.partialDestination] = 'rendered';
    harness.engine.tasks.single.complete(render.partialDestination);
    await _waitForState<ExportComplete>(tester, harness);
    await tester.pumpAndSettle();
    expect(find.text('Export complete'), findsOneWidget);
    expect(find.text('/exports/interview.mp4'), findsOneWidget);
    expect(find.text('Show in Folder'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
  });

  testWidgets('running without parsed percentage is indeterminate', (
    tester,
  ) async {
    final harness = _Harness();
    addTearDown(harness.dispose);
    await _showDialog(tester, harness);
    await tester.tap(find.text('Choose destination…'));
    await tester.pump();
    await tester.tap(find.text('Export'));
    await tester.pump();

    harness.engine.tasks.single.emit(
      EngineProgress(stage: EngineStage.writing),
    );
    await tester.pump();

    final progress = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(progress.value, isNull);
    expect(find.text('Writing MP4…'), findsOneWidget);

    unawaited(harness.coordinator.cancel());
    await _waitForState<ExportChoosing>(tester, harness);
  });

  testWidgets('running cancellation returns to destination choice', (
    tester,
  ) async {
    final harness = _Harness();
    addTearDown(harness.dispose);
    await _showDialog(tester, harness);
    await tester.tap(find.text('Choose destination…'));
    await tester.pump();
    await tester.tap(find.text('Export'));
    await tester.pump();

    await tester.tap(find.text('Cancel'));
    await _waitForState<ExportChoosing>(tester, harness);
    await tester.pumpAndSettle();

    expect(harness.engine.tasks.single.cancelCount, 1);
    expect(find.text('Export MP4'), findsOneWidget);
    expect(find.text('Export failed'), findsNothing);
    expect(find.text('/exports/interview.mp4'), findsOneWidget);
  });

  testWidgets('failure supports retry and changing destination', (
    tester,
  ) async {
    final harness = _Harness();
    addTearDown(harness.dispose);
    await _showDialog(tester, harness);
    await tester.tap(find.text('Choose destination…'));
    await tester.pump();
    await tester.tap(find.text('Export'));
    await tester.pump();
    harness.engine.tasks.single.fail(
      EngineContractFailure(
        operation: 'render',
        reason: EngineContractReason.unexpectedExit,
      ),
    );
    await _waitForState<ExportFailed>(tester, harness);
    await tester.pumpAndSettle();

    expect(find.text('Export failed'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Change destination'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(harness.engine.renderCalls, hasLength(2));

    harness.engine.tasks.last.fail(
      EngineContractFailure(
        operation: 'render',
        reason: EngineContractReason.unexpectedExit,
      ),
    );
    await _waitForState<ExportFailed>(tester, harness);
    await tester.pumpAndSettle();
    harness.picker.next = Uri.file('/exports/retry.mp4');
    await tester.tap(find.text('Change destination'));
    await tester.pumpAndSettle();
    expect(find.text('/exports/retry.mp4'), findsOneWidget);
    expect(find.text('Export MP4'), findsOneWidget);
  });

  testWidgets('offers and forwards all three beginner presets', (tester) async {
    for (final expectation in <(String, RenderPreset)>[
      ('Smaller', RenderPreset.smaller),
      ('Balanced', RenderPreset.balanced),
      ('Higher quality', RenderPreset.higherQuality),
    ]) {
      final harness = _Harness();
      await _showDialog(tester, harness);
      await tester.tap(find.text('Choose destination…'));
      await tester.pump();
      await tester.tap(find.text(expectation.$1));
      await tester.pump();
      await tester.tap(find.text('Export'));
      await tester.pump();

      expect(harness.engine.renderCalls.single.preset, expectation.$2);
      unawaited(harness.coordinator.cancel());
      await _waitForState<ExportChoosing>(tester, harness);
      await tester.pumpWidget(const SizedBox.shrink());
      await harness.dispose();
    }
  });

  testWidgets('complete phase reveals output and Done closes the dialog', (
    tester,
  ) async {
    final harness = _Harness();
    addTearDown(harness.dispose);
    await _showDialog(tester, harness);
    await tester.tap(find.text('Choose destination…'));
    await tester.pump();
    await tester.tap(find.text('Export'));
    await tester.pump();
    final render = harness.engine.renderCalls.single;
    harness.fileSystem.files[render.partialDestination] = 'rendered';
    harness.engine.tasks.single.complete(render.partialDestination);
    await _waitForState<ExportComplete>(tester, harness);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Show in Folder'));
    await tester.pump();
    expect(harness.revealer.revealed, <Uri>[
      Uri.file('/exports/interview.mp4'),
    ]);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.byType(ExportDialog), findsNothing);
  });

  testWidgets('reopening resets a terminal coordinator to choose', (
    tester,
  ) async {
    final harness = _Harness();
    addTearDown(harness.dispose);
    await _showDialog(tester, harness);
    await tester.tap(find.text('Choose destination…'));
    await tester.pump();
    await tester.tap(find.text('Export'));
    await tester.pump();
    final render = harness.engine.renderCalls.single;
    harness.fileSystem.files[render.partialDestination] = 'rendered';
    harness.engine.tasks.single.complete(render.partialDestination);
    await _waitForState<ExportComplete>(tester, harness);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open export'));
    await tester.pumpAndSettle();

    expect(find.text('Export MP4'), findsOneWidget);
    expect(find.text('Export complete'), findsNothing);
    expect(find.text('No destination selected'), findsOneWidget);
  });

  testWidgets('rejects a non-MP4 picker result without starting export', (
    tester,
  ) async {
    final harness = _Harness()
      ..picker.next = Uri.file('/exports/interview.mov');
    addTearDown(harness.dispose);
    await _showDialog(tester, harness);
    await tester.tap(find.text('Choose destination…'));
    await tester.pump();

    expect(find.text('Choose an MP4 destination.'), findsOneWidget);
    expect(harness.engine.renderCalls, isEmpty);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Export'))
          .onPressed,
      isNull,
    );
  });

  testWidgets('picker errors stay inside the dialog boundary', (tester) async {
    final harness = _Harness()..picker.error = StateError('picker unavailable');
    addTearDown(harness.dispose);
    await _showDialog(tester, harness);

    await tester.tap(find.text('Choose destination…'));
    await tester.pumpAndSettle();

    expect(find.text('Could not choose an MP4 destination.'), findsOneWidget);
    expect(harness.engine.renderCalls, isEmpty);
  });

  testWidgets('cancel cleanup errors are handled for the button', (
    tester,
  ) async {
    final harness = _Harness();
    addTearDown(() async {
      try {
        await harness.dispose();
      } on AppFailure {
        // Expected from this cleanup-failure harness.
      }
    });
    await _showDialog(tester, harness);
    await tester.tap(find.text('Choose destination…'));
    await tester.pump();
    await tester.tap(find.text('Export'));
    await tester.pump();
    final partial = harness.engine.renderCalls.single.partialDestination;
    harness.fileSystem
      ..files[partial] = 'incomplete'
      ..failWorkspaceCleanup = true;

    await tester.tap(find.text('Cancel'));
    await _waitForState<ExportFailed>(tester, harness);
    await tester.pumpAndSettle();

    expect(find.text('Export failed'), findsOneWidget);
  });

  testWidgets('cancel cleanup errors are handled for Escape', (tester) async {
    final harness = _Harness();
    addTearDown(() async {
      try {
        await harness.dispose();
      } on AppFailure {
        // Expected from this cleanup-failure harness.
      }
    });
    await _showDialog(tester, harness);
    await tester.tap(find.text('Choose destination…'));
    await tester.pump();
    await tester.tap(find.text('Export'));
    await tester.pump();
    final partial = harness.engine.renderCalls.single.partialDestination;
    harness.fileSystem
      ..files[partial] = 'incomplete'
      ..failWorkspaceCleanup = true;

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _waitForState<ExportFailed>(tester, harness);
    await tester.pumpAndSettle();

    expect(find.text('Export failed'), findsOneWidget);
  });

  testWidgets('failure shows a concise recovery copy path', (tester) async {
    final harness = _Harness()..fileSystem.failCommit = true;
    addTearDown(harness.dispose);
    await _showDialog(tester, harness);
    await tester.tap(find.text('Choose destination…'));
    await tester.pump();
    await tester.tap(find.text('Export'));
    await tester.pump();
    final render = harness.engine.renderCalls.single;
    harness.fileSystem
      ..files[Uri.file('/exports/interview.mp4')] = 'old export'
      ..files[render.partialDestination] = 'new export';
    harness.engine.tasks.single.complete(render.partialDestination);
    await _waitForState<ExportFailed>(tester, harness);
    await tester.pumpAndSettle();

    expect(find.text('Export failed'), findsOneWidget);
    expect(find.textContaining('Recovery copy:'), findsOneWidget);
    expect(find.textContaining('.backup-'), findsOneWidget);
  });

  testWidgets('complete shows a retained backup cleanup warning', (
    tester,
  ) async {
    final harness = _Harness()..fileSystem.retainBackupOnCommit = true;
    addTearDown(harness.dispose);
    await _showDialog(tester, harness);
    await tester.tap(find.text('Choose destination…'));
    await tester.pump();
    await tester.tap(find.text('Export'));
    await tester.pump();
    final render = harness.engine.renderCalls.single;
    harness.fileSystem
      ..files[Uri.file('/exports/interview.mp4')] = 'old export'
      ..files[render.partialDestination] = 'new export';
    harness.engine.tasks.single.complete(render.partialDestination);
    await _waitForState<ExportComplete>(tester, harness);
    await tester.pumpAndSettle();

    expect(find.text('Export complete'), findsOneWidget);
    expect(find.textContaining('Recovery copy:'), findsOneWidget);
  });
}

Future<void> _waitForState<T extends ExportState>(
  WidgetTester tester,
  _Harness harness,
) async {
  for (var pump = 0; pump < 50; pump++) {
    if (harness.coordinator.state is T) return;
    await tester.pump(const Duration(milliseconds: 1));
  }
  throw TestFailure(
    'Timed out waiting for $T; current state is '
    '${harness.coordinator.state.runtimeType}.',
  );
}

Future<void> _showDialog(WidgetTester tester, _Harness harness) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => FilledButton(
            onPressed: () => showDialog<void>(
              context: context,
              barrierDismissible: false,
              builder: (_) => ExportDialog(
                coordinator: harness.coordinator,
                source: Uri.file('/videos/interview.mp4'),
                metadata: _metadata(),
                timeline: _timeline(),
                destinationPicker: harness.picker,
                revealInFolder: harness.revealer,
              ),
            ),
            child: const Text('Open export'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open export'));
  await tester.pumpAndSettle();
}

final class _Harness {
  _Harness() {
    coordinator = ExportCoordinator(
      engine: engine,
      fileSystem: fileSystem,
      operationId: () => 'operation-${_nextId++}',
    );
  }

  static var _nextId = 0;
  final engine = _DialogEngine();
  final fileSystem = _DialogFileSystem();
  final picker = _Picker();
  final revealer = _Revealer();
  late final ExportCoordinator coordinator;

  Future<void> dispose() => coordinator.dispose();
}

final class _Picker implements ExportDestinationPicker {
  Uri? next = Uri.file('/exports/interview.mp4');
  Object? error;
  final suggestions = <Uri?>[];

  @override
  Future<Uri?> chooseMp4Destination(Uri? suggested) async {
    suggestions.add(suggested);
    if (error case final failure?) throw failure;
    return next;
  }
}

final class _Revealer implements ExportRevealInFolder {
  final revealed = <Uri>[];

  @override
  Future<void> reveal(Uri file) async {
    revealed.add(file);
  }
}

final class _DialogEngine implements EnginePort {
  final renderCalls = <RenderRequest>[];
  final tasks = <_DialogTask>[];

  @override
  EngineTask<Uri> render(RenderRequest request) {
    renderCalls.add(request);
    final task = _DialogTask();
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

final class _DialogTask implements EngineTask<Uri> {
  final _progress = StreamController<EngineProgress>.broadcast(sync: true);
  final _result = Completer<Uri>();
  var cancelCount = 0;

  @override
  Stream<EngineProgress> get progress => _progress.stream;

  @override
  Future<Uri> get result => _result.future;

  void emit(EngineProgress progress) => _progress.add(progress);

  void complete(Uri output) {
    unawaited(_progress.close());
    _result.complete(output);
  }

  void fail(Object error) {
    unawaited(_progress.close());
    _result.completeError(error);
  }

  @override
  Future<void> cancel() async {
    cancelCount += 1;
    unawaited(_progress.close());
    if (!_result.isCompleted) {
      _result.completeError(const OperationCancelled(operation: 'render'));
    }
  }
}

final class _DialogFileSystem implements ExportFileSystem {
  final files = <Uri, String>{};
  var failWorkspaceCleanup = false;
  var failCommit = false;
  var retainBackupOnCommit = false;

  @override
  Future<ExportWorkspace> createWorkspace({
    required Uri destination,
    required String operationId,
  }) async {
    final destinationPath = destination.toFilePath();
    final parent = path.dirname(destinationPath);
    final stem = path.basenameWithoutExtension(destinationPath);
    final directory = Uri.directory(
      path.join(parent, '.$stem.gapless-$operationId'),
    );
    return _DialogWorkspace(
      directory: directory,
      partial: Uri.file(
        path.join(directory.toFilePath(), '$stem.edited.partial.mp4'),
      ),
      backup: Uri.file(
        path.join(parent, '$stem.edited.backup-$operationId.mp4'),
      ),
    );
  }

  @override
  Future<bool> identifiesSameFile(Uri first, Uri second) async {
    return first == second;
  }

  @override
  Future<void> validateDestination(Uri destination) async {}

  @override
  Future<void> cleanupWorkspace(ExportWorkspace workspace) async {
    if (failWorkspaceCleanup) {
      throw StateError('workspace cleanup failed');
    }
    files.remove(workspace.partial);
  }

  @override
  Future<void> flush(ExportWorkspace workspace) async {
    if (!files.containsKey(workspace.partial)) {
      throw StateError('missing partial');
    }
  }

  @override
  Future<ExportPromotion> stagePromotion({
    required ExportWorkspace workspace,
    required Uri destination,
  }) async {
    final partial = workspace.partial;
    final backup = workspace.backup;
    final hadPrevious = files.containsKey(destination);
    if (hadPrevious) files[backup] = files.remove(destination)!;
    files[destination] = files.remove(partial)!;
    return _DialogPromotion(
      owner: this,
      destination: destination,
      backup: backup,
      hadPrevious: hadPrevious,
    );
  }
}

final class _DialogWorkspace implements ExportWorkspace {
  const _DialogWorkspace({
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
}

final class _DialogPromotion implements ExportPromotion {
  const _DialogPromotion({
    required this.owner,
    required this.destination,
    required this.backup,
    required this.hadPrevious,
  });

  final _DialogFileSystem owner;
  final Uri destination;
  final Uri backup;
  final bool hadPrevious;

  @override
  Future<PromotionCommitResult> commit() async {
    if (owner.failCommit) {
      throw ExportFileSystemFailure(
        'commit failed',
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
    if (hadPrevious) {
      owner.files[destination] = owner.files.remove(backup)!;
    } else {
      owner.files.remove(destination);
    }
  }
}

MediaMetadata _metadata() => MediaMetadata(
  durationUs: 1000000,
  timebaseNumerator: 1,
  timebaseDenominator: 30,
  resolution: SizeInt(1920, 1080),
  videoCodec: 'h264',
  hasAudio: true,
  sampleRate: 48000,
  audioLayout: 'stereo',
);

EffectiveTimeline _timeline() => EffectiveTimeline.compose(
  durationUs: 1000000,
  detected: <TimelineSegment>[
    TimelineSegment(
      range: SourceTimeRange(0, 700000),
      action: SegmentAction.keep,
      origin: SegmentOrigin.detected,
    ),
    TimelineSegment(
      range: SourceTimeRange(700000, 1000000),
      action: SegmentAction.cut,
      origin: SegmentOrigin.detected,
    ),
  ],
  overrides: const <TimelineSegment>[],
);
