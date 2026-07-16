import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gapless/features/editor/domain/analysis_settings.dart';
import 'package:gapless/features/editor/domain/timeline_segment.dart';
import 'package:gapless/features/editor/presentation/editor_view_model.dart';

final class StatusBar extends StatelessWidget {
  const StatusBar({
    required this.state,
    required this.onRetry,
    required this.onSaveAs,
    super.key,
  });

  final EditorState state;
  final VoidCallback onRetry;
  final VoidCallback onSaveAs;

  @override
  Widget build(BuildContext context) {
    final timeline = state.timeline;
    final settings = state.project?.settings;
    final cutCount =
        timeline?.segments
            .where((segment) => segment.action != SegmentAction.keep)
            .length ??
        0;
    final sourceDuration = state.metadata?.durationUs ?? 0;
    final editedDuration = timeline?.editedDurationUs ?? sourceDuration;
    final cli = _command(state);
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: Theme.of(context).dividerColor),
          ),
        ),
        child: Row(
          children: <Widget>[
            Text.rich(
              TextSpan(
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 11.5,
                ),
                children: <InlineSpan>[
                  TextSpan(
                    text:
                        '$cutCount '
                        '${settings?.inactiveBehavior == InactiveBehavior.fastForward ? 'fast-forwards' : 'cuts'}',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  TextSpan(text: ' · ${_formatTime(sourceDuration)} → '),
                  TextSpan(
                    text: _formatTime(editedDuration),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                cli,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontFamily: 'monospace',
                  fontSize: 10.5,
                ),
              ),
            ),
            const SizedBox(width: 6),
            TextButton(
              onPressed: cli.isEmpty
                  ? null
                  : () => Clipboard.setData(ClipboardData(text: cli)),
              style: const ButtonStyle(
                minimumSize: WidgetStatePropertyAll(Size(42, 26)),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('Copy'),
            ),
            const SizedBox(width: 8),
            _SaveStatus(
              status: state.saveStatus,
              onRetry: onRetry,
              onSaveAs: onSaveAs,
            ),
          ],
        ),
      ),
    );
  }
}

final class _SaveStatus extends StatelessWidget {
  const _SaveStatus({
    required this.status,
    required this.onRetry,
    required this.onSaveAs,
  });

  final EditorSaveStatus status;
  final VoidCallback onRetry;
  final VoidCallback onSaveAs;

  @override
  Widget build(BuildContext context) {
    if (status == EditorSaveStatus.failed) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Text('Saving failed', style: TextStyle(fontSize: 11.5)),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
          TextButton(onPressed: onSaveAs, child: const Text('Save As…')),
        ],
      );
    }
    return Text(switch (status) {
      EditorSaveStatus.idle => '',
      EditorSaveStatus.saving => 'Saving…',
      EditorSaveStatus.saved => 'Saved',
      EditorSaveStatus.failed => throw StateError('Handled above'),
    }, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600));
  }
}

String _command(EditorState state) {
  final project = state.project;
  if (project == null) return '';
  final settings = project.settings;
  final method = settings.method == AnalysisMethod.audio ? 'audio' : 'motion';
  final before = settings.marginBeforeUs / Duration.microsecondsPerSecond;
  final after = settings.marginAfterUs / Duration.microsecondsPerSecond;
  final fastForward = settings.inactiveBehavior == InactiveBehavior.fastForward
      ? ' --when-inactive speed:${_number(settings.fastForwardRate)}'
      : '';
  return 'auto-editor ${project.source.relativePath} '
      '--edit $method:${_number(settings.thresholdDb)}dB '
      '--margin ${_number(before)}s,${_number(after)}s$fastForward';
}

String _number(double value) => value == value.roundToDouble()
    ? value.round().toString()
    : value.toStringAsFixed(1);

String _formatTime(int microseconds) {
  final seconds = microseconds ~/ Duration.microsecondsPerSecond;
  final minutes = seconds ~/ 60;
  return '$minutes:${(seconds % 60).toString().padLeft(2, '0')}';
}
