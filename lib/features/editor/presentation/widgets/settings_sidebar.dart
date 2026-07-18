import 'package:flutter/material.dart';
import 'package:gapless/features/editor/domain/analysis_settings.dart';
import 'package:gapless/features/editor/presentation/editor_view_model.dart';

final class SettingsSidebar extends StatelessWidget {
  const SettingsSidebar({
    required this.state,
    required this.onMethodChanged,
    required this.onThresholdChanged,
    required this.onMarginBeforeChanged,
    required this.onMarginAfterChanged,
    required this.onInactiveBehaviorChanged,
    required this.onFastForwardRateChanged,
    required this.onUseMotion,
    super.key,
  });

  final EditorState state;
  final ValueChanged<AnalysisMethod> onMethodChanged;
  final ValueChanged<double> onThresholdChanged;
  final ValueChanged<int> onMarginBeforeChanged;
  final ValueChanged<int> onMarginAfterChanged;
  final ValueChanged<InactiveBehavior> onInactiveBehaviorChanged;
  final ValueChanged<double> onFastForwardRateChanged;
  final VoidCallback onUseMotion;

  @override
  Widget build(BuildContext context) {
    final project = state.project;
    if (project == null) return const SizedBox.shrink();
    final settings = project.settings;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Material(
      color: Theme.of(context).canvasColor,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const _SectionLabel('EDIT BY'),
            const SizedBox(height: 8),
            SegmentedButton<AnalysisMethod>(
              showSelectedIcon: false,
              segments: const <ButtonSegment<AnalysisMethod>>[
                ButtonSegment<AnalysisMethod>(
                  value: AnalysisMethod.audio,
                  label: Text('Audio'),
                ),
                ButtonSegment<AnalysisMethod>(
                  value: AnalysisMethod.motion,
                  label: Text('Motion'),
                ),
              ],
              selected: <AnalysisMethod>{settings.method},
              onSelectionChanged: (selection) =>
                  onMethodChanged(selection.single),
              style: _segmentedStyle,
            ),
            if (state.audioUnavailable) ...<Widget>[
              const SizedBox(height: 8),
              const Text(
                'This video has no audio track.',
                style: TextStyle(fontSize: 11.5),
              ),
              const SizedBox(height: 6),
              OutlinedButton(
                onPressed: onUseMotion,
                child: const Text('Use Motion'),
              ),
            ],
            const SizedBox(height: 18),
            _ThresholdSetting(
              value: settings.thresholdDb.clamp(-40, -6),
              onCommitted: onThresholdChanged,
            ),
            Text(
              'Anything quieter than this gets cut. Changes update the timeline automatically.',
              style: TextStyle(color: muted, fontSize: 11, height: 1.35),
            ),
            if (state.manualOverridesCleared) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                'Manual timeline choices cleared.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 18),
            const _SectionLabel('MARGIN'),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: _MarginStepper(
                    label: 'Before',
                    valueUs: settings.marginBeforeUs,
                    onChanged: onMarginBeforeChanged,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _MarginStepper(
                    label: 'After',
                    valueUs: settings.marginAfterUs,
                    onChanged: onMarginAfterChanged,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Silence kept around every cut, so edits breathe.',
              style: TextStyle(color: muted, fontSize: 11, height: 1.35),
            ),
            const SizedBox(height: 18),
            const _SectionLabel('SILENCE'),
            const SizedBox(height: 8),
            SegmentedButton<InactiveBehavior>(
              showSelectedIcon: false,
              segments: const <ButtonSegment<InactiveBehavior>>[
                ButtonSegment<InactiveBehavior>(
                  value: InactiveBehavior.cut,
                  label: Text('Cut out'),
                ),
                ButtonSegment<InactiveBehavior>(
                  value: InactiveBehavior.fastForward,
                  label: Text('Fast-forward'),
                ),
              ],
              selected: <InactiveBehavior>{settings.inactiveBehavior},
              onSelectionChanged: (selection) =>
                  onInactiveBehaviorChanged(selection.single),
              style: _segmentedStyle,
            ),
            if (settings.inactiveBehavior ==
                InactiveBehavior.fastForward) ...<Widget>[
              const SizedBox(height: 9),
              _FastForwardSpeedField(
                key: const ValueKey<String>('fastForward.speed'),
                value: settings.fastForwardRate,
                onChanged: onFastForwardRateChanged,
              ),
            ],
            const SizedBox(height: 7),
            Text(
              settings.inactiveBehavior == InactiveBehavior.cut
                  ? 'Silence is removed from the video entirely.'
                  : 'Silence plays faster instead of disappearing.',
              style: TextStyle(color: muted, fontSize: 11, height: 1.35),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Divider(height: 1),
            ),
            const ExpansionTile(
              tilePadding: EdgeInsets.zero,
              minTileHeight: 36,
              title: Text(
                'Advanced',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
              ),
              children: <Widget>[
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Advanced engine controls will arrive after the beginner workflow is complete.',
                    style: TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Tip: click any hatched cut in the timeline to keep it.',
              style: TextStyle(color: muted, fontSize: 11, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

final class _FastForwardSpeedField extends StatefulWidget {
  const _FastForwardSpeedField({
    required this.value,
    required this.onChanged,
    super.key,
  });

  final double value;
  final ValueChanged<double> onChanged;

  @override
  State<_FastForwardSpeedField> createState() => _FastForwardSpeedFieldState();
}

final class _FastForwardSpeedFieldState extends State<_FastForwardSpeedField> {
  late final TextEditingController _controller = TextEditingController(
    text: _compactNumber(widget.value),
  );

  @override
  void didUpdateWidget(_FastForwardSpeedField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      _controller.value = TextEditingValue(
        text: _compactNumber(widget.value),
        selection: TextSelection.collapsed(
          offset: _compactNumber(widget.value).length,
        ),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextFormField(
    controller: _controller,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    onFieldSubmitted: (value) {
      final parsed = double.tryParse(value);
      if (parsed != null) widget.onChanged(parsed);
    },
    decoration: const InputDecoration(
      labelText: 'Speed',
      suffixText: '×',
      isDense: true,
      border: OutlineInputBorder(),
    ),
  );
}

const _segmentedStyle = ButtonStyle(
  minimumSize: WidgetStatePropertyAll(Size(64, 30)),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  visualDensity: VisualDensity.compact,
);

final class _MarginStepper extends StatelessWidget {
  const _MarginStepper({
    required this.label,
    required this.valueUs,
    required this.onChanged,
  });

  final String label;
  final int valueUs;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Text(
        label,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 11,
        ),
      ),
      const SizedBox(height: 4),
      Container(
        height: 30,
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).colorScheme.outline),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Row(
          children: <Widget>[
            _StepButton(
              tooltip: 'Decrease $label margin',
              label: '−',
              onPressed: () =>
                  onChanged((valueUs - 100000).clamp(0, 2000000).toInt()),
            ),
            Expanded(
              child: Text(
                '${(valueUs / Duration.microsecondsPerSecond).toStringAsFixed(1)}s',
                textAlign: TextAlign.center,
                maxLines: 1,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
              ),
            ),
            _StepButton(
              tooltip: 'Increase $label margin',
              label: '+',
              onPressed: () =>
                  onChanged((valueUs + 100000).clamp(0, 2000000).toInt()),
            ),
          ],
        ),
      ),
    ],
  );
}

final class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.tooltip,
    required this.label,
    required this.onPressed,
  });

  final String tooltip;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: InkWell(
      onTap: onPressed,
      child: SizedBox(
        width: 28,
        height: 28,
        child: Center(child: Text(label, style: const TextStyle(fontSize: 14))),
      ),
    ),
  );
}

final class _ThresholdSetting extends StatefulWidget {
  const _ThresholdSetting({required this.value, required this.onCommitted});

  final double value;
  final ValueChanged<double> onCommitted;

  @override
  State<_ThresholdSetting> createState() => _ThresholdSettingState();
}

final class _ThresholdSettingState extends State<_ThresholdSetting> {
  double? _dragValue;

  double get _value => _dragValue ?? widget.value;

  @override
  Widget build(BuildContext context) => Column(
    children: <Widget>[
      Row(
        children: <Widget>[
          const _SectionLabel('THRESHOLD'),
          const Spacer(),
          Text(
            '${_value.round()} dB',
            style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              fontFamily: 'monospace',
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
      Slider(
        key: const ValueKey<String>('settings.threshold'),
        value: _value,
        min: -40,
        max: -6,
        divisions: 34,
        onChangeStart: (value) => setState(() => _dragValue = value),
        onChanged: (value) => setState(() => _dragValue = value),
        onChangeEnd: (value) {
          setState(() => _dragValue = null);
          widget.onCommitted(value);
        },
      ),
    ],
  );
}

final class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      fontSize: 10.5,
      fontWeight: FontWeight.w700,
      letterSpacing: .95,
    ),
  );
}

String _compactNumber(double value) => value == value.roundToDouble()
    ? value.round().toString()
    : value.toStringAsFixed(2);
