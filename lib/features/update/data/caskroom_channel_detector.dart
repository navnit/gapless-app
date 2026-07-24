import 'dart:io';

import 'package:gapless/features/update/domain/channel_detector_port.dart';
import 'package:gapless/features/update/domain/install_channel.dart';
import 'package:path/path.dart' as p;

final class CaskroomChannelDetector implements ChannelDetectorPort {
  const CaskroomChannelDetector({
    required this.resolvedExecutable,
    this.caskroomPrefixes = const ['/opt/homebrew', '/usr/local'],
  });

  final String resolvedExecutable;
  final List<String> caskroomPrefixes;

  @override
  Future<InstallChannel> detect() async {
    try {
      if (resolvedExecutable.contains('/Caskroom/')) {
        return InstallChannel.homebrew;
      }
      for (final prefix in caskroomPrefixes) {
        final receipt = File(
          p.join(
            prefix,
            'Caskroom',
            'gapless',
            '.metadata',
            'INSTALL_RECEIPT.json',
          ),
        );
        final directory = Directory(p.join(prefix, 'Caskroom', 'gapless'));
        if (await receipt.exists() || await directory.exists()) {
          return InstallChannel.homebrew;
        }
      }
      return InstallChannel.directDmg;
    } on Object {
      return InstallChannel.unknown;
    }
  }
}
