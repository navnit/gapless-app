import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gapless/features/editor/domain/effective_timeline.dart';
import 'package:gapless/features/editor/domain/timeline_segment.dart';
import 'package:gapless/features/editor/presentation/timeline_view_model.dart';
import 'package:gapless/features/editor/presentation/widgets/timeline_painter.dart';
import 'package:gapless/features/engine/domain/engine_models.dart';

final class TimelineView extends StatefulWidget {
  const TimelineView({
    super.key,
    required this.levels,
    required this.timeline,
    required this.sourcePositionUs,
    required this.thresholdFraction,
    required this.waveformHeight,
    required this.onIntent,
    this.zoom = 1,
    this.scrollPx = 0,
  });

  static const surfaceKey = ValueKey<String>('timeline.surface');

  final AnalysisLevels levels;
  final EffectiveTimeline timeline;
  final int sourcePositionUs;
  final double thresholdFraction;
  final double waveformHeight;
  final ValueChanged<TimelineIntent> onIntent;
  final double zoom;
  final double scrollPx;

  @override
  State<TimelineView> createState() => _TimelineViewState();
}

final class _TimelineViewState extends State<TimelineView> {
  late double _zoom;
  late double _scrollPx;
  var _scrubbing = false;

  @override
  void initState() {
    super.initState();
    _zoom = widget.zoom;
    _scrollPx = widget.scrollPx;
  }

  @override
  void didUpdateWidget(covariant TimelineView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.zoom != oldWidget.zoom) _zoom = widget.zoom;
    if (widget.scrollPx != oldWidget.scrollPx) _scrollPx = widget.scrollPx;
  }

  @override
  Widget build(BuildContext context) {
    final palette = TimelinePalette.fromBrightness(
      Theme.of(context).brightness,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final ownWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final viewportWidth = math.max(1, ownWidth - 32).toDouble();
        final model = TimelineViewModel(
          levels: widget.levels,
          timeline: widget.timeline,
          sourcePositionUs: widget.sourcePositionUs,
          viewportWidth: viewportWidth,
          waveformHeight: widget.waveformHeight,
          zoom: _zoom,
          scrollPx: _scrollPx,
          thresholdFraction: widget.thresholdFraction,
        );
        _zoom = model.zoom;
        _scrollPx = model.scrollPx;

        return Material(
          color: palette.panel,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: palette.border)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _buildHeader(model, palette, ownWidth),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                  child: _buildSurface(model, palette),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader(
    TimelineViewModel model,
    TimelinePalette palette,
    double width,
  ) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
    child: Row(
      children: <Widget>[
        Text(
          'TIMELINE',
          style: TextStyle(
            color: palette.faintText,
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.95,
          ),
        ),
        const Spacer(),
        if (width >= 640) ...<Widget>[
          Text(
            '${_modifierLabel()} + scroll to zoom',
            style: TextStyle(color: palette.faintText, fontSize: 10.5),
          ),
          const SizedBox(width: 10),
        ],
        _ZoomControls(
          palette: palette,
          label: '${(model.zoom * 100).round()}%',
          onZoomOut: () =>
              _applyZoom(model, model.zoom / 1.5, model.viewportWidth / 2),
          onZoomIn: () =>
              _applyZoom(model, model.zoom * 1.5, model.viewportWidth / 2),
          onFit: () => _applyZoom(model, 1, model.viewportWidth / 2),
        ),
      ],
    ),
  );

  Widget _buildSurface(TimelineViewModel model, TimelinePalette palette) {
    final semantics = <Widget>[];
    for (final primitive in model.segments) {
      semantics.add(
        Positioned.fromRect(
          rect: primitive.hitRect,
          child: Semantics(
            container: true,
            button: true,
            label: _segmentSemanticsLabel(primitive.segment),
            onTap: () =>
                widget.onIntent(ToggleSegmentIntent(primitive.segment.range)),
            child: const SizedBox.expand(),
          ),
        ),
      );
    }

    final surface = SizedBox(
      width: model.viewportWidth,
      height: model.surfaceHeight,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: <Widget>[
          CustomPaint(
            key: TimelineView.surfaceKey,
            size: Size(model.viewportWidth, model.surfaceHeight),
            painter: TimelinePainter(model: model, palette: palette),
          ),
          ...semantics,
        ],
      ),
    );

    return MouseRegion(
      cursor: SystemMouseCursors.precise,
      child: Listener(
        onPointerSignal: (event) => _handlePointerSignal(event, model),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) => _handleTap(details.localPosition, model),
          onPanStart: (details) {
            _scrubbing = model.isSeekPosition(details.localPosition);
            if (_scrubbing) _emitSeek(details.localPosition.dx, model);
          },
          onPanUpdate: (details) {
            if (_scrubbing) _emitSeek(details.localPosition.dx, model);
          },
          onPanEnd: (_) => _scrubbing = false,
          onPanCancel: () => _scrubbing = false,
          child: surface,
        ),
      ),
    );
  }

  void _handleTap(Offset position, TimelineViewModel model) {
    final segment = model.segmentAt(position);
    if (segment != null) {
      widget.onIntent(ToggleSegmentIntent(segment.range));
      return;
    }
    if (model.isSeekPosition(position)) {
      _emitSeek(position.dx, model);
    }
  }

  void _emitSeek(double localX, TimelineViewModel model) {
    widget.onIntent(SeekTimelineIntent(model.sourceUsAtX(localX)));
  }

  void _handlePointerSignal(PointerSignalEvent event, TimelineViewModel model) {
    if (event is! PointerScrollEvent) return;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed || keyboard.isMetaPressed) {
      _applyZoom(
        model,
        model.zoom * math.exp(-event.scrollDelta.dy * 0.0022),
        event.localPosition.dx,
      );
      return;
    }

    final delta = event.scrollDelta.dx != 0
        ? event.scrollDelta.dx
        : event.scrollDelta.dy;
    final nextScroll = (model.scrollPx + delta)
        .clamp(0, model.maxScrollPx)
        .toDouble();
    if (nextScroll == model.scrollPx) return;
    setState(() => _scrollPx = nextScroll);
  }

  void _applyZoom(
    TimelineViewModel model,
    double requestedZoom,
    double anchorX,
  ) {
    final viewport = model.zoomAroundAnchor(requestedZoom, anchorX);
    if (viewport.zoom == model.zoom && viewport.scrollPx == model.scrollPx) {
      return;
    }
    setState(() {
      _zoom = viewport.zoom;
      _scrollPx = viewport.scrollPx;
    });
    widget.onIntent(
      SetTimelineZoomIntent(viewport.zoom, viewport.anchorSourceUs),
    );
  }
}

final class _ZoomControls extends StatelessWidget {
  const _ZoomControls({
    required this.palette,
    required this.label,
    required this.onZoomOut,
    required this.onZoomIn,
    required this.onFit,
  });

  final TimelinePalette palette;
  final String label;
  final VoidCallback onZoomOut;
  final VoidCallback onZoomIn;
  final VoidCallback onFit;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: palette.raisedPanel,
      border: Border.all(color: palette.border),
      borderRadius: BorderRadius.circular(7),
    ),
    child: Padding(
      padding: const EdgeInsets.all(2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _HeaderButton(
            tooltip: 'Zoom out',
            width: 24,
            palette: palette,
            onTap: onZoomOut,
            child: const Text('−', textAlign: TextAlign.center),
          ),
          SizedBox(
            width: 44,
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: palette.mutedText,
                fontFamily: 'monospace',
                fontSize: 11,
              ),
            ),
          ),
          _HeaderButton(
            tooltip: 'Zoom in',
            width: 24,
            palette: palette,
            onTap: onZoomIn,
            child: const Text('+', textAlign: TextAlign.center),
          ),
          _HeaderButton(
            tooltip: 'Fit whole timeline',
            width: 38,
            palette: palette,
            onTap: onFit,
            child: const Text(
              'Fit',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    ),
  );
}

final class _HeaderButton extends StatelessWidget {
  const _HeaderButton({
    required this.tooltip,
    required this.width,
    required this.palette,
    required this.onTap,
    required this.child,
  });

  final String tooltip;
  final double width;
  final TimelinePalette palette;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Semantics(
      button: true,
      label: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(5),
        onTap: onTap,
        child: SizedBox(
          width: width,
          height: 20,
          child: DefaultTextStyle(
            style: TextStyle(color: palette.mutedText, fontSize: 13, height: 1),
            child: Center(child: child),
          ),
        ),
      ),
    ),
  );
}

String _modifierLabel() {
  final platform = defaultTargetPlatform;
  return platform == TargetPlatform.macOS ? '⌘' : 'Ctrl';
}

String _segmentSemanticsLabel(TimelineSegment segment) {
  final start = _secondsLabel(segment.range.startUs);
  final end = _secondsLabel(segment.range.endUs);
  final manual = segment.origin == SegmentOrigin.manual ? ', manual edit' : '';
  return switch (segment.action) {
    SegmentAction.cut =>
      'Removed segment, $start to $end seconds$manual, activate to keep',
    SegmentAction.keep =>
      'Kept segment, $start to $end seconds$manual, activate to remove',
    SegmentAction.fastForward =>
      'Fast-forward ${_rateLabel(segment.rate)}× segment, '
          '$start to $end seconds$manual, activate to keep at normal speed',
  };
}

String _secondsLabel(int sourceUs) =>
    (sourceUs / Duration.microsecondsPerSecond).toStringAsFixed(1);

String _rateLabel(double rate) =>
    rate == rate.roundToDouble() ? rate.round().toString() : rate.toString();
