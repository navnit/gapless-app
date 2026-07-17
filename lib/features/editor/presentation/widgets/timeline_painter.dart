import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:gapless/features/editor/domain/timeline_segment.dart';
import 'package:gapless/features/editor/presentation/timeline_view_model.dart';

@immutable
final class TimelinePalette {
  const TimelinePalette({
    required this.accent,
    required this.panel,
    required this.raisedPanel,
    required this.border,
    required this.secondaryBorder,
    required this.hatch,
    required this.keptWaveform,
    required this.cutWaveform,
    required this.playhead,
    required this.text,
    required this.mutedText,
    required this.faintText,
  });

  factory TimelinePalette.fromBrightness(Brightness brightness) =>
      brightness == Brightness.dark
      ? const TimelinePalette(
          accent: Color(0xFFE3A63B),
          panel: Color(0xFF1A1C20),
          raisedPanel: Color(0xFF24262C),
          border: Color(0xFF2A2D34),
          secondaryBorder: Color(0xFF3B3F47),
          hatch: Color(0xFF3B3F47),
          keptWaveform: Color(0xFF98A0AC),
          cutWaveform: Color(0xFF3B3F47),
          playhead: Color(0xFFE25C4A),
          text: Color(0xFFECEDEF),
          mutedText: Color(0xFF9BA1AA),
          faintText: Color(0xFF9BA1AA),
        )
      : const TimelinePalette(
          accent: Color(0xFFE3A63B),
          panel: Color(0xFFF5F5F6),
          raisedPanel: Color(0xFFFFFFFF),
          border: Color(0xFFD8DADD),
          secondaryBorder: Color(0xFFC3C6CB),
          hatch: Color(0xFFCFD2D7),
          keptWaveform: Color(0xFF737B88),
          cutWaveform: Color(0xFFCDD0D5),
          playhead: Color(0xFFD4482F),
          text: Color(0xFF1C1E22),
          mutedText: Color(0xFF5D636C),
          faintText: Color(0xFF5D636C),
        );

  final Color accent;
  final Color panel;
  final Color raisedPanel;
  final Color border;
  final Color secondaryBorder;
  final Color hatch;
  final Color keptWaveform;
  final Color cutWaveform;
  final Color playhead;
  final Color text;
  final Color mutedText;
  final Color faintText;

  Color waveformColorFor(SegmentAction action) =>
      action == SegmentAction.keep ? keptWaveform : cutWaveform;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TimelinePalette &&
          accent == other.accent &&
          panel == other.panel &&
          raisedPanel == other.raisedPanel &&
          border == other.border &&
          secondaryBorder == other.secondaryBorder &&
          hatch == other.hatch &&
          keptWaveform == other.keptWaveform &&
          cutWaveform == other.cutWaveform &&
          playhead == other.playhead &&
          text == other.text &&
          mutedText == other.mutedText &&
          faintText == other.faintText;

  @override
  int get hashCode => Object.hash(
    accent,
    panel,
    raisedPanel,
    border,
    secondaryBorder,
    hatch,
    keptWaveform,
    cutWaveform,
    playhead,
    text,
    mutedText,
    faintText,
  );
}

final class TimelinePainter extends CustomPainter {
  const TimelinePainter({required this.model, required this.palette});

  final TimelineViewModel model;
  final TimelinePalette palette;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, Paint()..color = palette.panel);
    _paintWaveform(canvas);
    _paintThreshold(canvas);
    _paintSegments(canvas);
    _paintRuler(canvas);
    _paintPlayhead(canvas);
    canvas.restore();
  }

  void _paintWaveform(Canvas canvas) {
    for (final bar in model.waveformBars) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(bar.rect, const Radius.circular(1)),
        Paint()..color = palette.waveformColorFor(bar.action),
      );
    }
  }

  void _paintThreshold(Canvas canvas) {
    _drawDashedLine(
      canvas,
      Offset(0, model.thresholdY),
      Offset(model.viewportWidth, model.thresholdY),
      Paint()
        ..color = palette.accent.withValues(alpha: 0.55)
        ..strokeWidth = 1,
      dash: 5,
      gap: 4,
    );
  }

  void _paintSegments(Canvas canvas) {
    for (final primitive in model.segments) {
      final rect = primitive.paintRect;
      if (rect.isEmpty) continue;
      final rounded = RRect.fromRectAndRadius(
        rect,
        Radius.circular(primitive.segment.action == SegmentAction.keep ? 4 : 3),
      );
      switch (primitive.segment.action) {
        case SegmentAction.keep:
          canvas.drawRRect(
            rounded,
            Paint()..color = palette.accent.withValues(alpha: 0.16),
          );
          canvas.drawRRect(
            rounded,
            Paint()
              ..color = palette.accent.withValues(alpha: 0.52)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1,
          );
        case SegmentAction.cut:
          canvas.drawRRect(
            rounded,
            Paint()..color = palette.panel.withValues(alpha: 0.75),
          );
          _drawHatch(canvas, rounded, palette.hatch, 45, 6);
          _drawDashedBorder(canvas, rect, palette.secondaryBorder, 1);
        case SegmentAction.fastForward:
          canvas.drawRRect(
            rounded,
            Paint()..color = palette.accent.withValues(alpha: 0.05),
          );
          _drawHatch(
            canvas,
            rounded,
            palette.accent.withValues(alpha: 0.4),
            115,
            8,
          );
          canvas.drawRRect(
            rounded,
            Paint()
              ..color = palette.accent.withValues(alpha: 0.44)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1,
          );
      }
      if (primitive.segment.origin == SegmentOrigin.manual) {
        canvas.drawRRect(
          rounded,
          Paint()
            ..color = palette.accent.withValues(alpha: 0.92)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(rect.left + 3, rect.top + 2, 13, 2),
            const Radius.circular(1),
          ),
          Paint()..color = palette.accent,
        );
      }
    }
  }

  void _paintRuler(Canvas canvas) {
    final tickPaint = Paint()
      ..color = palette.secondaryBorder
      ..strokeWidth = 1;
    for (final tick in model.rulerTicks) {
      canvas.drawLine(
        Offset(tick.x, model.rulerRect.top),
        Offset(tick.x, model.rulerRect.top + 5),
        tickPaint,
      );
      final textPainter = TextPainter(
        text: TextSpan(
          text: tick.label,
          style: TextStyle(
            color: palette.faintText,
            fontSize: 10,
            fontFamily: 'monospace',
            height: 1,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout(maxWidth: 72);
      textPainter.paint(canvas, Offset(tick.x + 4, model.rulerRect.top + 3));
    }
  }

  void _paintPlayhead(Canvas canvas) {
    final playhead = model.playhead;
    if (playhead == null) return;
    canvas.drawRect(playhead.lineRect, Paint()..color = palette.playhead);
    canvas.drawCircle(
      playhead.capCenter,
      playhead.capRadius,
      Paint()..color = palette.playhead,
    );
  }

  @override
  bool shouldRepaint(covariant TimelinePainter oldDelegate) =>
      oldDelegate.model != model || oldDelegate.palette != palette;
}

void _drawHatch(
  Canvas canvas,
  RRect clip,
  Color color,
  double angleDegrees,
  double spacing,
) {
  canvas.save();
  canvas.clipRRect(clip);
  final center = clip.outerRect.center;
  canvas.translate(center.dx, center.dy);
  canvas.rotate(angleDegrees * math.pi / 180);
  final radius = math.sqrt(
    clip.outerRect.width * clip.outerRect.width +
        clip.outerRect.height * clip.outerRect.height,
  );
  final paint = Paint()
    ..color = color
    ..strokeWidth = 2;
  for (var x = -radius; x <= radius; x += spacing) {
    canvas.drawLine(Offset(x, -radius), Offset(x, radius), paint);
  }
  canvas.restore();
}

void _drawDashedBorder(
  Canvas canvas,
  Rect rect,
  Color color,
  double strokeWidth,
) {
  final paint = Paint()
    ..color = color
    ..strokeWidth = strokeWidth
    ..style = PaintingStyle.stroke;
  _drawDashedLine(canvas, rect.topLeft, rect.topRight, paint, dash: 4, gap: 3);
  _drawDashedLine(
    canvas,
    rect.bottomLeft,
    rect.bottomRight,
    paint,
    dash: 4,
    gap: 3,
  );
  _drawDashedLine(
    canvas,
    rect.topLeft,
    rect.bottomLeft,
    paint,
    dash: 4,
    gap: 3,
  );
  _drawDashedLine(
    canvas,
    rect.topRight,
    rect.bottomRight,
    paint,
    dash: 4,
    gap: 3,
  );
}

void _drawDashedLine(
  Canvas canvas,
  Offset start,
  Offset end,
  Paint paint, {
  required double dash,
  required double gap,
}) {
  final delta = end - start;
  final length = delta.distance;
  if (length <= 0) return;
  final direction = delta / length;
  var offset = 0.0;
  while (offset < length) {
    final dashEnd = math.min(length, offset + dash);
    canvas.drawLine(
      start + direction * offset,
      start + direction * dashEnd,
      paint,
    );
    offset += dash + gap;
  }
}
