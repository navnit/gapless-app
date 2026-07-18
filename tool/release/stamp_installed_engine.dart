import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

Future<void> main(List<String> arguments) async {
  if (arguments.length != 4 ||
      arguments[0] != '--bundle' ||
      arguments[2] != '--target') {
    stderr.writeln(
      'Usage: dart run tool/release/stamp_installed_engine.dart '
      '--bundle PATH --target TARGET',
    );
    exitCode = 64;
    return;
  }
  final bundle = Directory(path.absolute(arguments[1]));
  final target = arguments[3];
  final engine = switch (target) {
    'macos-arm64' || 'macos-x64' => Directory(
      path.join(bundle.path, 'Contents', 'Resources', 'engine'),
    ),
    'windows-x64' => Directory(path.join(bundle.path, 'engine')),
    'linux-x64' => Directory(
      path.join(bundle.path, 'lib', 'gapless', 'engine'),
    ),
    _ => throw ArgumentError.value(target, 'target'),
  };
  final manifestFile = File(path.join(engine.path, 'manifest.json'));
  final root = jsonDecode(await manifestFile.readAsString());
  if (root is! Map<String, dynamic>) throw const FormatException('manifest');
  final targets = root['targets'];
  if (targets is! Map<String, dynamic>) throw const FormatException('targets');
  final node = targets[target];
  if (node is! Map<String, dynamic>) throw FormatException('target $target');
  final installedFile = node['installedFile'];
  if (installedFile is! String ||
      path.basename(installedFile) != installedFile) {
    throw const FormatException('installedFile');
  }
  final executable = File(path.join(engine.path, installedFile));
  node['installedSha256'] = (await sha256.bind(executable.openRead()).single)
      .toString();
  await manifestFile.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(root)}\n',
    flush: true,
  );
}
