import 'package:flutter/material.dart';
import 'package:gapless/features/update/domain/update_status.dart';

class UpdateBanner extends StatelessWidget {
  const UpdateBanner({
    required this.status,
    required this.onView,
    required this.onSkip,
    required this.onDismiss,
    super.key,
  });

  final UpdateAvailable status;
  final VoidCallback onView;
  final VoidCallback onSkip;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(children: [
          const Icon(Icons.arrow_circle_up, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text('Gapless ${status.release.version} is available')),
          TextButton(onPressed: onView, child: const Text('View')),
          TextButton(onPressed: onSkip, child: const Text('Skip this version')),
          IconButton(onPressed: onDismiss, icon: const Icon(Icons.close, size: 16), tooltip: 'Remind me later'),
        ]),
      ),
    );
  }
}
