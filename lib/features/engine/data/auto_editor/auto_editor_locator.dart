import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:gapless/core/errors/app_failure.dart';
import 'package:gapless/core/process/process_runner.dart';
import 'package:gapless/features/engine/data/auto_editor/auto_editor_parsers.dart';
import 'package:path/path.dart' as p;

const autoEditorPinnedVersion = '31.2.0';

/// Resolves and verifies the single bundled Auto-Editor executable.
abstract interface class AutoEditorExecutableLocator {
  Future<String> locate();
}

final class AutoEditorTarget {
  AutoEditorTarget({
    required this.name,
    required this.asset,
    required this.url,
    required this.installedFile,
    required this.sha256,
  }) {
    if (!_targetNames.contains(name)) {
      throw ArgumentError.value(name, 'name');
    }
    if (asset.isEmpty || p.basename(asset) != asset) {
      throw ArgumentError.value(asset, 'asset');
    }
    if (installedFile.isEmpty || p.basename(installedFile) != installedFile) {
      throw ArgumentError.value(installedFile, 'installedFile');
    }
    if (url.scheme != 'https' ||
        url.host != 'github.com' ||
        url.hasPort ||
        url.userInfo.isNotEmpty ||
        url.hasQuery ||
        url.hasFragment ||
        url.path !=
            '/WyattBlue/auto-editor/releases/download/'
                '$autoEditorPinnedVersion/$asset') {
      throw ArgumentError.value(url, 'url');
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) {
      throw ArgumentError.value(sha256, 'sha256');
    }
  }

  final String name;
  final String asset;
  final Uri url;
  final String installedFile;
  final String sha256;
}

final class AutoEditorManifest {
  AutoEditorManifest._({
    required this.engine,
    required this.version,
    required Map<String, AutoEditorTarget> targets,
  }) : targets = Map.unmodifiable(targets);

  factory AutoEditorManifest.parse(String text) {
    try {
      rejectDuplicateJsonKeys(text);
      final root = _object(jsonDecode(text), 'manifest');
      _requireKeys(root, const {'engine', 'version', 'targets'}, 'manifest');
      if (root['engine'] != 'auto-editor' ||
          root['version'] != autoEditorPinnedVersion) {
        throw const FormatException('Unexpected engine or version');
      }
      final targetNodes = _object(root['targets'], 'targets');
      _requireKeys(targetNodes, _targetNames, 'targets');
      final targets = <String, AutoEditorTarget>{};
      for (final name in _targetNames) {
        final node = _object(targetNodes[name], name);
        _requireKeys(node, const {
          'asset',
          'url',
          'installedFile',
          'sha256',
        }, name);
        final target = AutoEditorTarget(
          name: name,
          asset: _string(node['asset'], '$name.asset'),
          url: Uri.parse(_string(node['url'], '$name.url')),
          installedFile: _string(node['installedFile'], '$name.installedFile'),
          sha256: _string(node['sha256'], '$name.sha256'),
        );
        if (!_matchesApprovedTarget(target)) {
          throw FormatException('Unexpected pinned target: $name');
        }
        targets[name] = target;
      }
      return AutoEditorManifest._(
        engine: 'auto-editor',
        version: autoEditorPinnedVersion,
        targets: targets,
      );
    } on FormatException {
      rethrow;
    } on Object catch (error) {
      throw FormatException('Invalid Auto-Editor manifest: $error');
    }
  }

  final String engine;
  final String version;
  final Map<String, AutoEditorTarget> targets;
}

final class AutoEditorLocator implements AutoEditorExecutableLocator {
  AutoEditorLocator({
    required this.manifestPath,
    required this.installRoot,
    required this.processRunner,
    String? target,
  }) : target = target ?? currentAutoEditorTarget() {
    if (!p.isAbsolute(manifestPath)) {
      throw ArgumentError.value(manifestPath, 'manifestPath');
    }
    if (!p.isAbsolute(installRoot)) {
      throw ArgumentError.value(installRoot, 'installRoot');
    }
    if (!_targetNames.contains(this.target)) {
      throw ArgumentError.value(this.target, 'target');
    }
  }

  final String manifestPath;
  final String installRoot;
  final ProcessRunner processRunner;
  final String target;

  @override
  Future<String> locate() async {
    final manifestFile = File(manifestPath);
    if (await FileSystemEntity.type(manifestPath, followLinks: false) !=
        FileSystemEntityType.file) {
      throw EngineMissingFailure(expectedLocation: Uri.file(manifestPath));
    }
    final manifest = AutoEditorManifest.parse(
      await manifestFile.readAsString(),
    );
    final selected = manifest.targets[target];
    if (selected == null) {
      throw EngineMissingFailure(expectedLocation: Uri.file(installRoot));
    }
    return verifyTarget(selected);
  }

  Future<String> verifyTarget(AutoEditorTarget selected) async {
    if (selected.name != target) {
      throw EngineContractFailure(
        operation: 'locate',
        reason: EngineContractReason.invalidOutput,
        diagnostics: const ['Manifest target does not match requested target'],
      );
    }
    final executablePath = p.normalize(
      p.join(installRoot, selected.name, selected.installedFile),
    );
    if (!p.isAbsolute(executablePath) ||
        !p.isWithin(p.normalize(installRoot), executablePath)) {
      throw EngineMissingFailure(expectedLocation: Uri.file(executablePath));
    }
    if (await FileSystemEntity.type(executablePath, followLinks: false) !=
        FileSystemEntityType.file) {
      throw EngineMissingFailure(expectedLocation: Uri.file(executablePath));
    }
    final executable = File(executablePath);
    final stat = await executable.stat();
    if (!selected.name.startsWith('windows-') && stat.mode & 0x49 == 0) {
      throw EngineMissingFailure(expectedLocation: Uri.file(executablePath));
    }

    final actualSha256 = await hashFileSha256(executable);
    if (actualSha256 != selected.sha256) {
      throw EngineChecksumFailure(
        expectedSha256: selected.sha256,
        actualSha256: actualSha256,
      );
    }

    final process = await processRunner.start(
      ProcessRequest(
        executable: executablePath,
        arguments: const ['--version'],
      ),
    );
    final stdoutFuture = _boundedLines(process.stdoutLines);
    final stderrFuture = _boundedLines(process.stderrLines);
    final exitCode = await process.exitCode;
    final stdout = await stdoutFuture;
    final stderr = await stderrFuture;
    final diagnostics = _boundVersionDiagnostics([...stderr, ...stdout]);
    if (exitCode != 0) {
      throw EngineContractFailure(
        operation: 'locate',
        reason: EngineContractReason.unexpectedExit,
        exitCode: exitCode,
        diagnostics: diagnostics,
      );
    }
    if (stdout.join('\n').trim() != autoEditorPinnedVersion) {
      throw EngineContractFailure(
        operation: 'locate',
        reason: EngineContractReason.unsupportedVersion,
        diagnostics: diagnostics,
      );
    }
    return executablePath;
  }
}

Future<String> hashFileSha256(File file) async =>
    (await sha256.bind(file.openRead()).single).toString();

String currentAutoEditorTarget() {
  return switch (Abi.current()) {
    Abi.macosArm64 => 'macos-arm64',
    Abi.macosX64 => 'macos-x64',
    Abi.windowsX64 => 'windows-x64',
    Abi.linuxX64 => 'linux-x64',
    final abi => throw UnsupportedError(
      'Unsupported Auto-Editor platform ABI: $abi',
    ),
  };
}

Future<List<String>> _boundedLines(Stream<String> stream) async {
  final lines = <String>[];
  var characters = 0;
  await for (final raw in stream) {
    if (lines.length == 8 || characters == 1024) continue;
    final line = raw.replaceAll(RegExp(r'[\r\n]+'), ' ');
    final available = 1024 - characters;
    final bounded = line.length <= available
        ? line
        : line.substring(0, available);
    lines.add(bounded);
    characters += bounded.length;
  }
  return lines;
}

List<String> _boundVersionDiagnostics(Iterable<String> lines) {
  final result = <String>[];
  var characters = 0;
  for (final line in lines) {
    if (result.length == 8 || characters == 1024) break;
    final available = 1024 - characters;
    final bounded = line.length <= available
        ? line
        : line.substring(0, available);
    result.add(bounded);
    characters += bounded.length;
  }
  return result;
}

Map<String, dynamic> _object(Object? value, String name) {
  if (value is! Map<String, dynamic>) {
    throw FormatException('Expected $name object');
  }
  return value;
}

String _string(Object? value, String name) {
  if (value is! String || value.isEmpty) {
    throw FormatException('Expected $name string');
  }
  return value;
}

void _requireKeys(Map<String, dynamic> value, Set<String> keys, String name) {
  final actual = value.keys.toSet();
  if (actual.length != keys.length ||
      actual.difference(keys).isNotEmpty ||
      keys.difference(actual).isNotEmpty) {
    throw FormatException('Unexpected $name structure');
  }
}

bool _matchesApprovedTarget(AutoEditorTarget target) {
  final approved = _approvedTargets[target.name];
  return approved != null &&
      target.asset == approved.$1 &&
      target.url.toString() == approved.$2 &&
      target.installedFile == approved.$3 &&
      target.sha256 == approved.$4;
}

const _targetNames = {'macos-arm64', 'macos-x64', 'windows-x64', 'linux-x64'};

const _approvedTargets = <String, (String, String, String, String)>{
  'macos-arm64': (
    'auto-editor-macos-arm64',
    'https://github.com/WyattBlue/auto-editor/releases/download/31.2.0/'
        'auto-editor-macos-arm64',
    'auto-editor',
    '12cad2d0887bf44e6406e13b2cb7f32bd20d7aafb46b495c4b38eea2af590b27',
  ),
  'macos-x64': (
    'auto-editor-macos-x86_64',
    'https://github.com/WyattBlue/auto-editor/releases/download/31.2.0/'
        'auto-editor-macos-x86_64',
    'auto-editor',
    '124db9cbe80b980d527f3d16fb50fed4133064887227aa4d1f0ad5adb3a8e65e',
  ),
  'windows-x64': (
    'auto-editor-windows-x86_64.exe',
    'https://github.com/WyattBlue/auto-editor/releases/download/31.2.0/'
        'auto-editor-windows-x86_64.exe',
    'auto-editor.exe',
    'ab7457f67dc41396841777cc4af625bb6372973af99ba2e43dac416cda07aadc',
  ),
  'linux-x64': (
    'auto-editor-linux-x86_64',
    'https://github.com/WyattBlue/auto-editor/releases/download/31.2.0/'
        'auto-editor-linux-x86_64',
    'auto-editor',
    '4065f5c83210dcad2f53bda8160b7e147b9732ae6e1e9bceb62b0ea256181d6e',
  ),
};
