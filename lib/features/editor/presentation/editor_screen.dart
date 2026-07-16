import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gapless/features/editor/presentation/editor_view_model.dart';
import 'package:gapless/features/editor/presentation/widgets/settings_sidebar.dart';
import 'package:gapless/features/editor/presentation/widgets/status_bar.dart';
import 'package:gapless/features/editor/presentation/widgets/studio_toolbar.dart';
import 'package:gapless/features/editor/presentation/widgets/timeline_view.dart';
import 'package:gapless/features/editor/presentation/widgets/video_preview.dart';
import 'package:media_kit_video/media_kit_video.dart';

final class EditorScreen extends StatelessWidget {
  const EditorScreen({
    required this.viewModel,
    this.videoController,
    super.key,
  });

  final EditorViewModel viewModel;
  final VideoController? videoController;

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.keyS, control: true): () =>
          unawaited(viewModel.save()),
      const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () =>
          unawaited(viewModel.save()),
      const SingleActivator(
        LogicalKeyboardKey.keyS,
        control: true,
        shift: true,
      ): () =>
          unawaited(viewModel.saveAs()),
      const SingleActivator(
        LogicalKeyboardKey.keyS,
        meta: true,
        shift: true,
      ): () =>
          unawaited(viewModel.saveAs()),
      const SingleActivator(LogicalKeyboardKey.keyZ, control: true): () =>
          unawaited(viewModel.undo()),
      const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): () =>
          unawaited(viewModel.undo()),
      const SingleActivator(
        LogicalKeyboardKey.keyZ,
        control: true,
        shift: true,
      ): () =>
          unawaited(viewModel.redo()),
      const SingleActivator(
        LogicalKeyboardKey.keyZ,
        meta: true,
        shift: true,
      ): () =>
          unawaited(viewModel.redo()),
      const SingleActivator(LogicalKeyboardKey.keyE, control: true): () =>
          unawaited(viewModel.export()),
      const SingleActivator(LogicalKeyboardKey.keyE, meta: true): () =>
          unawaited(viewModel.export()),
      const SingleActivator(LogicalKeyboardKey.space): () {
        if (!_isEditingText()) unawaited(viewModel.togglePlayback());
      },
    },
    child: _RootFocus(
      child: ListenableBuilder(
        listenable: viewModel,
        builder: (context, _) {
          final state = viewModel.state;
          return FocusTraversalGroup(
            policy: OrderedTraversalPolicy(),
            child: Scaffold(
              body: Column(
                children: <Widget>[
                  const _TitleBar(),
                  if (state.phase == EditorPhase.empty)
                    Expanded(
                      child: _EmptyWorkspace(
                        onOpen: () => unawaited(viewModel.openVideo()),
                        onOpenProject: () => unawaited(viewModel.openProject()),
                      ),
                    )
                  else ...<Widget>[
                    StudioToolbar(
                      state: state,
                      onOpenVideo: () => unawaited(viewModel.openVideo()),
                      onOpenProject: (project) =>
                          unawaited(viewModel.openProject(project)),
                      onPreviewModeChanged: (mode) =>
                          unawaited(viewModel.setPreviewMode(mode)),
                      onExport: () => unawaited(viewModel.export()),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          SizedBox(
                            width: state.project?.ui.sidebarWidth ?? 264,
                            child: SettingsSidebar(
                              state: state,
                              onMethodChanged: (method) => unawaited(
                                viewModel.setAnalysisMethod(method),
                              ),
                              onThresholdChanged: (threshold) => unawaited(
                                viewModel.setThresholdDb(threshold),
                              ),
                              onMarginBeforeChanged: (value) => unawaited(
                                viewModel.setMargins(beforeUs: value),
                              ),
                              onMarginAfterChanged: (value) => unawaited(
                                viewModel.setMargins(afterUs: value),
                              ),
                              onInactiveBehaviorChanged: (behavior) =>
                                  unawaited(
                                    viewModel.setInactiveBehavior(behavior),
                                  ),
                              onFastForwardRateChanged: (rate) =>
                                  unawaited(viewModel.setFastForwardRate(rate)),
                              onUseMotion: () =>
                                  unawaited(viewModel.useMotion()),
                            ),
                          ),
                          _SidebarResizeHandle(
                            onDrag: (delta) {
                              final width =
                                  viewModel.state.project?.ui.sidebarWidth ??
                                  264;
                              unawaited(
                                viewModel.setSidebarWidth(width + delta),
                              );
                            },
                          ),
                          Expanded(
                            child: Column(
                              children: <Widget>[
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      16,
                                      16,
                                      16,
                                      0,
                                    ),
                                    child: VideoPreview(
                                      state: state,
                                      controller: videoController,
                                      onTogglePlayback: () =>
                                          unawaited(viewModel.togglePlayback()),
                                    ),
                                  ),
                                ),
                                if (state.levels case final levels?)
                                  if (state.timeline case final timeline?)
                                    Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: <Widget>[
                                        _TimelineResizeHandle(
                                          onDrag: (delta) {
                                            final height =
                                                viewModel
                                                    .state
                                                    .project
                                                    ?.ui
                                                    .waveformHeight ??
                                                52;
                                            unawaited(
                                              viewModel.setWaveformHeight(
                                                height - delta,
                                              ),
                                            );
                                          },
                                        ),
                                        TimelineView(
                                          levels: levels,
                                          timeline: timeline,
                                          sourcePositionUs:
                                              state.sourcePositionUs,
                                          thresholdFraction: math
                                              .pow(
                                                10,
                                                (state
                                                            .project
                                                            ?.settings
                                                            .thresholdDb ??
                                                        -19) /
                                                    20,
                                              )
                                              .toDouble(),
                                          waveformHeight:
                                              state
                                                  .project
                                                  ?.ui
                                                  .waveformHeight ??
                                              52,
                                          zoom:
                                              state.project?.ui.timelineZoom ??
                                              1,
                                          onIntent: (intent) => unawaited(
                                            viewModel.handleTimelineIntent(
                                              intent,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                StatusBar(
                                  state: state,
                                  onRetry: () =>
                                      unawaited(viewModel.retrySave()),
                                  onSaveAs: () => unawaited(viewModel.saveAs()),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    ),
  );
}

final class _RootFocus extends StatefulWidget {
  const _RootFocus({required this.child});

  final Widget child;

  @override
  State<_RootFocus> createState() => _RootFocusState();
}

final class _RootFocusState extends State<_RootFocus> {
  final _focusNode = FocusNode(debugLabel: 'Gapless editor shortcuts');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onTap: _focusNode.requestFocus,
    child: Focus(focusNode: _focusNode, autofocus: true, child: widget.child),
  );
}

bool _isEditingText() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  return context.widget is EditableText ||
      context.findAncestorWidgetOfExactType<EditableText>() != null;
}

final class _EmptyWorkspace extends StatelessWidget {
  const _EmptyWorkspace({required this.onOpen, required this.onOpenProject});

  final VoidCallback onOpen;
  final VoidCallback onOpenProject;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const Icon(Icons.video_file_outlined, size: 40),
        const SizedBox(height: 14),
        Text(
          'Drop a video here',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 6),
        const Text('Gapless keeps everything local on this computer.'),
        const SizedBox(height: 18),
        FilledButton(onPressed: onOpen, child: const Text('Open Video')),
        const SizedBox(height: 4),
        TextButton(
          onPressed: onOpenProject,
          child: const Text('Open Project…'),
        ),
      ],
    ),
  );
}

final class _TitleBar extends StatelessWidget {
  const _TitleBar();

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).canvasColor,
    child: SizedBox(
      height: 42,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: 5,
                  height: 16,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 3),
                Container(
                  width: 5,
                  height: 16,
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: .45),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 10),
            const Text(
              'Gapless',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            ),
            const Spacer(),
            Icon(Icons.remove, size: 15, color: Theme.of(context).hintColor),
            const SizedBox(width: 14),
            Icon(
              Icons.crop_square,
              size: 13,
              color: Theme.of(context).hintColor,
            ),
            const SizedBox(width: 14),
            Icon(Icons.close, size: 14, color: Theme.of(context).hintColor),
          ],
        ),
      ),
    ),
  );
}

final class _SidebarResizeHandle extends StatelessWidget {
  const _SidebarResizeHandle({required this.onDrag});

  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.resizeColumn,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: (details) => onDrag(details.delta.dx),
      child: SizedBox(
        width: 7,
        child: Center(
          child: Container(width: 1, color: Theme.of(context).dividerColor),
        ),
      ),
    ),
  );
}

final class _TimelineResizeHandle extends StatelessWidget {
  const _TimelineResizeHandle({required this.onDrag});

  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.resizeRow,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: (details) => onDrag(details.delta.dy),
      child: SizedBox(
        height: 9,
        child: Center(
          child: Container(
            width: 44,
            height: 3,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.outlineVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    ),
  );
}
