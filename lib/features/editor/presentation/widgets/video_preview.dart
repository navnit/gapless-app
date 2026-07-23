import 'package:flutter/material.dart';
import 'package:gapless/features/editor/presentation/editor_view_model.dart';
import 'package:gapless/features/project/domain/project_document.dart';
import 'package:media_kit_video/media_kit_video.dart';

final class VideoPreview extends StatelessWidget {
  const VideoPreview({
    required this.state,
    required this.controller,
    required this.onTogglePlayback,
    this.onCopyDiagnostics,
    super.key,
  });

  final EditorState state;
  final VideoController? controller;
  final VoidCallback onTogglePlayback;

  /// When non-null, renders a "Copy diagnostics" action beside the failure
  /// message so the user can capture the redacted engine diagnostics.
  final VoidCallback? onCopyDiagnostics;

  @override
  Widget build(BuildContext context) {
    final edited = state.project?.ui.previewMode != PreviewMode.original;
    final timeline = state.timeline;
    final currentUs = edited && timeline != null
        ? timeline.editedUsForSourceUs(
            state.sourcePositionUs.clamp(0, timeline.durationUs),
          )
        : state.sourcePositionUs;
    final totalUs = edited && timeline != null
        ? timeline.editedDurationUs
        : state.metadata?.durationUs ?? 0;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(
      children: <Widget>[
        Expanded(
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: const Color(0xFF0B0C0E),
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(10),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                if (controller case final videoController?)
                  Video(
                    key: const ValueKey<String>('preview.video'),
                    controller: videoController,
                    controls: NoVideoControls,
                    fit: BoxFit.contain,
                    fill: const Color(0xFF0B0C0E),
                  )
                else
                  Center(
                    child: Icon(
                      Icons.movie_outlined,
                      size: 46,
                      color: Colors.white.withValues(alpha: .24),
                    ),
                  ),
                Positioned(
                  top: 10,
                  right: 10,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: edited
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.surfaceContainer,
                      borderRadius: BorderRadius.circular(5),
                      border: edited
                          ? null
                          : Border.all(color: Theme.of(context).dividerColor),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 3,
                      ),
                      child: Text(
                        edited ? 'EDITED' : 'ORIGINAL',
                        style: TextStyle(
                          color: edited ? const Color(0xFF211903) : muted,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: .75,
                        ),
                      ),
                    ),
                  ),
                ),
                if (state.phase == EditorPhase.analyzing)
                  ColoredBox(
                    color: Colors.black.withValues(alpha: .6),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          const Text(
                            'Analyzing…',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 12),
                          const SizedBox(
                            width: 220,
                            child: LinearProgressIndicator(),
                          ),
                          if (state.message case final message?) ...<Widget>[
                            const SizedBox(height: 10),
                            Text(
                              message,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 11.5,
                              ),
                            ),
                            if (onCopyDiagnostics case final onCopy?) ...<Widget>[
                              const SizedBox(height: 6),
                              TextButton.icon(
                                key: const ValueKey<String>(
                                  'failure.copyDiagnostics',
                                ),
                                onPressed: onCopy,
                                icon: const Icon(Icons.copy, size: 15),
                                label: const Text('Copy diagnostics'),
                                style: TextButton.styleFrom(
                                  foregroundColor: Colors.white,
                                ),
                              ),
                            ],
                          ],
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 40,
          child: Row(
            children: <Widget>[
              Semantics(
                button: true,
                label: state.isPlaying ? 'Pause' : 'Play',
                onTap: onTogglePlayback,
                excludeSemantics: true,
                child: IconButton.filled(
                  key: const ValueKey<String>('preview.playPause'),
                  onPressed: onTogglePlayback,
                  icon: Icon(
                    state.isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    size: 19,
                  ),
                  tooltip: state.isPlaying ? 'Pause' : 'Play',
                  constraints: const BoxConstraints.tightFor(
                    width: 40,
                    height: 40,
                  ),
                  padding: EdgeInsets.zero,
                  style: const ButtonStyle(
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '${_formatTime(currentUs)}  /  ${_formatTime(totalUs)}',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Space to play · playback skips cuts in Edited view',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                  style: TextStyle(color: muted, fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

String _formatTime(int microseconds) {
  final seconds = microseconds ~/ Duration.microsecondsPerSecond;
  final minutes = seconds ~/ 60;
  return '$minutes:${(seconds % 60).toString().padLeft(2, '0')}';
}
