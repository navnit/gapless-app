import 'package:flutter/material.dart';
import 'package:gapless/features/editor/presentation/editor_view_model.dart';
import 'package:gapless/features/project/domain/project_document.dart';

final class StudioToolbar extends StatelessWidget {
  const StudioToolbar({
    required this.state,
    required this.onOpenVideo,
    required this.onOpenProject,
    required this.onPreviewModeChanged,
    required this.onExport,
    super.key,
  });

  final EditorState state;
  final VoidCallback onOpenVideo;
  final ValueChanged<Uri?> onOpenProject;
  final ValueChanged<PreviewMode> onPreviewModeChanged;
  final VoidCallback onExport;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).canvasColor,
    child: SizedBox(
      height: 52,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: <Widget>[
            FocusTraversalOrder(
              order: const NumericFocusOrder(1),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  OutlinedButton(
                    key: const ValueKey<String>('toolbar.open'),
                    onPressed: onOpenVideo,
                    child: const Text('Open…'),
                  ),
                  const SizedBox(width: 4),
                  PopupMenuButton<Object>(
                    tooltip: 'Open project or recent project',
                    icon: const Icon(Icons.keyboard_arrow_down, size: 18),
                    onSelected: (value) =>
                        onOpenProject(value is Uri ? value : null),
                    itemBuilder: (context) => <PopupMenuEntry<Object>>[
                      const PopupMenuItem<Object>(
                        value: 'open-project',
                        child: Text('Open Project…'),
                      ),
                      if (state.recentProjects.isNotEmpty)
                        const PopupMenuDivider(),
                      for (final project in state.recentProjects)
                        PopupMenuItem<Object>(
                          value: project,
                          child: Text(
                            project.pathSegments.last,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (state.project case final project?)
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      project.source.relativePath,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (state.metadata case final metadata?)
                      Text(
                        '${metadata.resolution.height}p · '
                        '${(metadata.timebaseDenominator / metadata.timebaseNumerator).toStringAsFixed(2)} fps · '
                        '${_formatTime(metadata.durationUs)}',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 11,
                        ),
                      ),
                  ],
                ),
              )
            else
              const Spacer(),
            const SizedBox(width: 12),
            FocusTraversalOrder(
              order: const NumericFocusOrder(2),
              child: SegmentedButton<PreviewMode>(
                showSelectedIcon: false,
                segments: const <ButtonSegment<PreviewMode>>[
                  ButtonSegment<PreviewMode>(
                    value: PreviewMode.original,
                    label: Text('Original'),
                  ),
                  ButtonSegment<PreviewMode>(
                    value: PreviewMode.edited,
                    label: Text('Edited'),
                  ),
                ],
                selected: <PreviewMode>{
                  state.project?.ui.previewMode ?? PreviewMode.edited,
                },
                onSelectionChanged: (selection) =>
                    onPreviewModeChanged(selection.single),
                style: const ButtonStyle(
                  minimumSize: WidgetStatePropertyAll(Size(74, 40)),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
            const SizedBox(width: 12),
            FocusTraversalOrder(
              order: const NumericFocusOrder(3),
              child: FilledButton(
                key: const ValueKey<String>('toolbar.export'),
                onPressed: state.timeline == null ? null : onExport,
                child: const Text('Export…'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

String _formatTime(int microseconds) {
  final seconds = microseconds ~/ Duration.microsecondsPerSecond;
  final minutes = seconds ~/ 60;
  return '$minutes:${(seconds % 60).toString().padLeft(2, '0')}';
}
