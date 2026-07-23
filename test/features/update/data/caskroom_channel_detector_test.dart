import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/features/update/domain/install_channel.dart';
import 'package:gapless/features/update/data/caskroom_channel_detector.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory prefix;
  setUp(() => prefix = Directory.systemTemp.createTempSync('cask_prefix'));
  tearDown(() => prefix.deleteSync(recursive: true));

  test('bundle running under a Caskroom path is homebrew', () async {
    final detector = CaskroomChannelDetector(
      resolvedExecutable: '/opt/homebrew/Caskroom/gapless/0.1.1/Gapless.app/Contents/MacOS/Gapless',
      caskroomPrefixes: const [],
    );
    expect(await detector.detect(), InstallChannel.homebrew);
  });

  test('receipt file present is homebrew', () async {
    final receipt = File(p.join(prefix.path, 'Caskroom', 'gapless', '.metadata', 'INSTALL_RECEIPT.json'));
    receipt.createSync(recursive: true);
    final detector = CaskroomChannelDetector(
      resolvedExecutable: '/Applications/Gapless.app/Contents/MacOS/Gapless',
      caskroomPrefixes: [prefix.path],
    );
    expect(await detector.detect(), InstallChannel.homebrew);
  });

  test('caskroom directory without receipt is homebrew', () async {
    Directory(p.join(prefix.path, 'Caskroom', 'gapless')).createSync(recursive: true);
    final detector = CaskroomChannelDetector(
      resolvedExecutable: '/Applications/Gapless.app/Contents/MacOS/Gapless',
      caskroomPrefixes: [prefix.path],
    );
    expect(await detector.detect(), InstallChannel.homebrew);
  });

  test('no caskroom signal is directDmg', () async {
    final detector = CaskroomChannelDetector(
      resolvedExecutable: '/Applications/Gapless.app/Contents/MacOS/Gapless',
      caskroomPrefixes: [prefix.path],
    );
    expect(await detector.detect(), InstallChannel.directDmg);
  });
}
