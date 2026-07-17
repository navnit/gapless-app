import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gapless/core/errors/app_failure.dart';
import 'package:gapless/features/editor/domain/effective_timeline.dart';
import 'package:gapless/features/engine/domain/engine_models.dart';
import 'package:gapless/features/export/application/export_coordinator.dart';
import 'package:path/path.dart' as path;

abstract interface class ExportDestinationPicker {
  Future<Uri?> chooseMp4Destination(Uri? suggested);
}

abstract interface class ExportRevealInFolder {
  Future<void> reveal(Uri file);
}

final class ExportDialog extends StatefulWidget {
  const ExportDialog({
    required this.coordinator,
    required this.source,
    required this.metadata,
    required this.timeline,
    required this.destinationPicker,
    required this.revealInFolder,
    this.initialDestination,
    super.key,
  });

  final ExportCoordinator coordinator;
  final Uri source;
  final MediaMetadata metadata;
  final EffectiveTimeline timeline;
  final ExportDestinationPicker destinationPicker;
  final ExportRevealInFolder revealInFolder;
  final Uri? initialDestination;

  @override
  State<ExportDialog> createState() => _ExportDialogState();
}

final class _ExportDialogState extends State<ExportDialog> {
  late final Uri _source = widget.source;
  late final MediaMetadata _metadata = widget.metadata;
  late final EffectiveTimeline _timeline = EffectiveTimeline.compose(
    durationUs: widget.timeline.durationUs,
    detected: widget.timeline.segments.toList(growable: false),
    overrides: const [],
  );
  late ExportState _state = widget.coordinator.state;
  late Uri? _destination = widget.initialDestination;
  late final StreamSubscription<ExportState> _states;
  RenderPreset _preset = RenderPreset.balanced;
  String? _choiceError;
  var _showChoice = false;
  var _cancelling = false;

  @override
  void initState() {
    super.initState();
    if (_state is ExportComplete || _state is ExportFailed) {
      widget.coordinator.reset();
      _state = widget.coordinator.state;
    }
    _states = widget.coordinator.states.listen((state) {
      if (!mounted) return;
      setState(() {
        _state = state;
        if (state is! ExportFailed) _showChoice = false;
        if (state is! ExportRunning) _cancelling = false;
      });
    });
  }

  @override
  void dispose() {
    unawaited(_states.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: const <ShortcutActivator, Intent>{
      SingleActivator(LogicalKeyboardKey.escape): _DismissExportIntent(),
    },
    child: Actions(
      actions: <Type, Action<Intent>>{
        _DismissExportIntent: CallbackAction<_DismissExportIntent>(
          onInvoke: (_) {
            unawaited(_cancelOrClose());
            return null;
          },
        ),
      },
      child: Focus(
        autofocus: true,
        child: FocusTraversalGroup(
          policy: OrderedTraversalPolicy(),
          child: AlertDialog(
            key: const ValueKey<String>('export.dialog'),
            title: Text(_title),
            content: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 440, maxWidth: 520),
              child: AnimatedSize(
                duration: const Duration(milliseconds: 120),
                alignment: Alignment.topCenter,
                child: _content,
              ),
            ),
            actions: _actions,
          ),
        ),
      ),
    ),
  );

  String get _title {
    if (_showChoice || _state is ExportChoosing) return 'Export MP4';
    if (_state is ExportRunning) return 'Exporting MP4';
    if (_state is ExportComplete) return 'Export complete';
    return 'Export failed';
  }

  Widget get _content {
    if (_showChoice || _state is ExportChoosing) return _chooseContent();
    return switch (_state) {
      final ExportRunning running => _runningContent(running),
      final ExportComplete complete => _completeContent(complete),
      final ExportFailed failed => _failedContent(failed),
      ExportChoosing() => _chooseContent(),
    };
  }

  List<Widget> get _actions {
    if (_showChoice || _state is ExportChoosing) {
      return <Widget>[
        FocusTraversalOrder(
          order: const NumericFocusOrder(4),
          child: TextButton(
            style: _buttonStyle,
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ),
        FocusTraversalOrder(
          order: const NumericFocusOrder(5),
          child: FilledButton(
            style: _buttonStyle,
            onPressed: _destination == null ? null : _start,
            child: const Text('Export'),
          ),
        ),
      ];
    }
    return switch (_state) {
      ExportRunning() => <Widget>[
        FocusTraversalOrder(
          order: const NumericFocusOrder(1),
          child: TextButton(
            style: _buttonStyle,
            onPressed: _cancelling ? null : _cancel,
            child: Text(_cancelling ? 'Cancelling…' : 'Cancel'),
          ),
        ),
      ],
      final ExportComplete complete => <Widget>[
        FocusTraversalOrder(
          order: const NumericFocusOrder(1),
          child: OutlinedButton(
            style: _buttonStyle,
            onPressed: () => _reveal(complete.output),
            child: const Text('Show in Folder'),
          ),
        ),
        FocusTraversalOrder(
          order: const NumericFocusOrder(2),
          child: FilledButton(
            style: _buttonStyle,
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ),
      ],
      ExportFailed() => <Widget>[
        FocusTraversalOrder(
          order: const NumericFocusOrder(1),
          child: OutlinedButton(
            style: _buttonStyle,
            onPressed: _changeDestination,
            child: const Text('Change destination'),
          ),
        ),
        FocusTraversalOrder(
          order: const NumericFocusOrder(2),
          child: FilledButton(
            style: _buttonStyle,
            onPressed: _start,
            child: const Text('Retry'),
          ),
        ),
      ],
      ExportChoosing() => const <Widget>[],
    };
  }

  Widget _chooseContent() => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      Text(
        'Save the edited video as an MP4.',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
      const SizedBox(height: 18),
      const Text(
        'DESTINATION',
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 7),
      DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Text(
            _destination?.toFilePath() ?? 'No destination selected',
            key: const ValueKey<String>('export.destination'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            semanticsLabel: _destination == null
                ? 'No export destination selected'
                : 'Export destination ${_destination!.toFilePath()}',
          ),
        ),
      ),
      const SizedBox(height: 8),
      FocusTraversalOrder(
        order: const NumericFocusOrder(1),
        child: OutlinedButton.icon(
          style: _buttonStyle,
          onPressed: _chooseDestination,
          icon: const Icon(Icons.folder_open, size: 18),
          label: const Text('Choose destination…'),
        ),
      ),
      if (_choiceError case final error?) ...<Widget>[
        const SizedBox(height: 7),
        Text(
          error,
          key: const ValueKey<String>('export.destinationError'),
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ],
      const SizedBox(height: 20),
      const Text(
        'QUALITY',
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 7),
      FocusTraversalOrder(
        order: const NumericFocusOrder(2),
        child: SegmentedButton<RenderPreset>(
          key: const ValueKey<String>('export.quality'),
          showSelectedIcon: false,
          segments: const <ButtonSegment<RenderPreset>>[
            ButtonSegment<RenderPreset>(
              value: RenderPreset.smaller,
              label: Text('Smaller'),
            ),
            ButtonSegment<RenderPreset>(
              value: RenderPreset.balanced,
              label: Text('Balanced'),
            ),
            ButtonSegment<RenderPreset>(
              value: RenderPreset.higherQuality,
              label: Text('Higher quality'),
            ),
          ],
          selected: <RenderPreset>{_preset},
          onSelectionChanged: (selection) {
            setState(() => _preset = selection.single);
          },
          style: const ButtonStyle(
            minimumSize: WidgetStatePropertyAll(Size(112, 40)),
          ),
        ),
      ),
      const SizedBox(height: 7),
      Text(
        _presetDescription,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 12,
        ),
      ),
    ],
  );

  Widget _runningContent(ExportRunning running) {
    final percent = running.percent;
    return Semantics(
      liveRegion: true,
      label: percent == null
          ? _stageLabel(running.stage)
          : '${_stageLabel(running.stage)} ${percent.round()} percent',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            _stageLabel(running.stage),
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 14),
          LinearProgressIndicator(
            value: percent == null ? null : percent / 100,
          ),
          const SizedBox(height: 9),
          Row(
            children: <Widget>[
              Text(percent == null ? 'Working…' : '${percent.round()}%'),
              const Spacer(),
              if (running.eta case final eta?) Text(_etaLabel(eta)),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            'You can cancel safely. Your existing MP4 will not be changed.',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _completeContent(ExportComplete complete) => Semantics(
    liveRegion: true,
    label: 'Export complete',
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Icon(
          Icons.check_circle_outline,
          size: 38,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(height: 12),
        const Text('Your edited MP4 is ready.'),
        const SizedBox(height: 10),
        SelectableText(
          complete.output.toFilePath(),
          key: const ValueKey<String>('export.output'),
        ),
        if (complete.recoveryBackup case final recovery?) ...<Widget>[
          const SizedBox(height: 10),
          _RecoveryCopy(recovery),
        ],
      ],
    ),
  );

  Widget _failedContent(ExportFailed failed) => Semantics(
    liveRegion: true,
    label: 'Export failed',
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(_failureMessage(failed.failure)),
        const SizedBox(height: 10),
        Text(
          failed.recoveryBackup == null
              ? 'Your project is unchanged. Retry or choose another destination.'
              : 'Your project is unchanged. A recovery copy was retained.',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 12,
          ),
        ),
        if (failed.recoveryBackup case final recovery?) ...<Widget>[
          const SizedBox(height: 10),
          _RecoveryCopy(recovery),
        ],
      ],
    ),
  );

  String get _presetDescription => switch (_preset) {
    RenderPreset.smaller => 'Uses less space and exports faster.',
    RenderPreset.balanced => 'A good balance of quality and file size.',
    RenderPreset.higherQuality => 'Keeps more detail with a larger file.',
  };

  Future<void> _chooseDestination() async {
    Uri? chosen;
    try {
      chosen = await widget.destinationPicker.chooseMp4Destination(
        _destination,
      );
    } on Object {
      if (!mounted) return;
      setState(() {
        _choiceError = 'Could not choose an MP4 destination.';
      });
      return;
    }
    final selected = chosen;
    if (!mounted || selected == null) return;
    setState(() {
      if (_isMp4File(selected)) {
        _destination = selected;
        _choiceError = null;
      } else {
        _destination = null;
        _choiceError = 'Choose an MP4 destination.';
      }
    });
  }

  Future<void> _changeDestination() async {
    setState(() {
      _showChoice = true;
      _choiceError = null;
    });
    await _chooseDestination();
  }

  Future<void> _start() async {
    final destination = _destination;
    if (destination == null) return;
    setState(() {
      _showChoice = false;
      _choiceError = null;
    });
    try {
      await widget.coordinator.start(
        ExportRequest(
          source: _source,
          metadata: _metadata,
          timeline: _timeline,
          destination: destination,
          preset: _preset,
        ),
      );
    } on Object {
      if (!mounted) return;
      setState(() {
        _showChoice = true;
        _choiceError = 'Choose an available MP4 destination.';
      });
    }
  }

  Future<void> _cancel() async {
    setState(() => _cancelling = true);
    try {
      await widget.coordinator.cancel();
    } on Object {
      if (!mounted) return;
      setState(() => _cancelling = false);
    }
  }

  Future<void> _cancelOrClose() async {
    if (_state is ExportRunning) {
      await _cancel();
    } else if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _reveal(Uri output) async {
    try {
      await widget.revealInFolder.reveal(output);
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Could not show the exported file.')),
      );
    }
  }
}

final class _RecoveryCopy extends StatelessWidget {
  const _RecoveryCopy(this.file);

  final Uri file;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Padding(
      padding: const EdgeInsets.all(10),
      child: SelectableText(
        'Recovery copy: ${file.toFilePath()}',
        key: const ValueKey<String>('export.recoveryCopy'),
      ),
    ),
  );
}

const ButtonStyle _buttonStyle = ButtonStyle(
  minimumSize: WidgetStatePropertyAll(Size(40, 40)),
);

final class _DismissExportIntent extends Intent {
  const _DismissExportIntent();
}

bool _isMp4File(Uri destination) {
  if (!destination.isScheme('file')) return false;
  try {
    return path.isAbsolute(destination.toFilePath()) &&
        path.extension(destination.toFilePath()).toLowerCase() == '.mp4';
  } on Object {
    return false;
  }
}

String _stageLabel(EngineStage stage) => switch (stage) {
  EngineStage.probing => 'Checking source…',
  EngineStage.analyzing => 'Preparing timeline…',
  EngineStage.buildingTimeline => 'Preparing export…',
  EngineStage.rendering => 'Rendering video…',
  EngineStage.writing => 'Writing MP4…',
};

String _etaLabel(Duration eta) {
  final seconds = eta.inSeconds;
  if (seconds < 60) return 'About $seconds seconds remaining';
  final minutes = (seconds / 60).ceil();
  return 'About $minutes ${minutes == 1 ? 'minute' : 'minutes'} remaining';
}

String _failureMessage(AppFailure failure) => switch (failure) {
  DiskFullFailure() => 'There is not enough free space to finish this export.',
  EngineMissingFailure() || EngineChecksumFailure() =>
    'The bundled video engine is unavailable. Reinstall Gapless and try again.',
  _ =>
    'Gapless could not finish this MP4. Try again or choose another destination.',
};
