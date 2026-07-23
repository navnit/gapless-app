import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gapless/features/update/domain/install_channel.dart';
import 'package:gapless/features/update/domain/update_status.dart';
import 'package:gapless/features/update/presentation/update_url.dart';

class UpdateDialog extends StatelessWidget {
  const UpdateDialog({
    required this.status,
    required this.onSkip,
    required this.onClose,
    this.openUrl,
    this.copyText,
    super.key,
  });

  final UpdateAvailable status;
  final VoidCallback onSkip;
  final VoidCallback onClose;
  final Future<void> Function(String url)? openUrl;
  final Future<void> Function(String text)? copyText;

  Future<void> _open(String url) async => (openUrl ?? openExternalUrl)(url);

  Future<void> _copy(String text) async =>
      (copyText ?? (value) => Clipboard.setData(ClipboardData(text: value)))(text);

  @override
  Widget build(BuildContext context) {
    final release = status.release;
    final isBrew = status.channel == InstallChannel.homebrew;
    return AlertDialog(
      title: Text('Gapless ${release.version} is available'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('You have ${status.current}.', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: SingleChildScrollView(child: Text(release.notes)),
            ),
            const SizedBox(height: 16),
            if (isBrew)
              Row(children: [
                Expanded(child: SelectableText(kBrewUpgradeCommand)),
                TextButton(onPressed: () => _copy(kBrewUpgradeCommand), child: const Text('Copy')),
              ])
            else
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                FilledButton(
                  onPressed: () => _open(release.dmgAssetUrl ?? release.htmlUrl),
                  child: const Text('Download'),
                ),
                const SizedBox(height: 6),
                Text(
                  'Drag the new Gapless into Applications and choose Replace.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ]),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => _open(release.htmlUrl), child: const Text('View release')),
        TextButton(onPressed: onSkip, child: const Text('Skip this version')),
        TextButton(onPressed: onClose, child: const Text('Close')),
      ],
    );
  }
}
