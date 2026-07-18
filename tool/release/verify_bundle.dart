import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

final class BundleVerificationReport {
  const BundleVerificationReport({
    required this.engineVersion,
    required this.engineTarget,
    required this.engineChecksumMatches,
    required this.hasGplSourceOffer,
    required this.hasThirdPartyNotices,
    required this.hasSbom,
    required this.problems,
  });

  final String engineVersion;
  final String engineTarget;
  final bool engineChecksumMatches;
  final bool hasGplSourceOffer;
  final bool hasThirdPartyNotices;
  final bool hasSbom;
  final List<String> problems;

  bool get isValid => problems.isEmpty;
}

final class BundleVerifier {
  const BundleVerifier();

  Future<BundleVerificationReport> verify(
    Directory bundleRoot, {
    required String target,
  }) async {
    final layout = _BundleLayout.detect(bundleRoot);
    final problems = <String>[];
    final manifestFile = File(path.join(layout.engine.path, 'manifest.json'));
    if (!await manifestFile.exists()) {
      throw FormatException('Engine manifest is missing: ${manifestFile.path}');
    }
    final manifest = _ReleaseManifest.parse(await manifestFile.readAsString());
    final selected = manifest.targets[target];
    if (selected == null) {
      throw FormatException('Manifest target is missing: $target');
    }
    final executable = File(path.join(layout.engine.path, selected.file));
    final executableExists = await executable.exists();
    final checksumMatches =
        executableExists &&
        (await sha256.bind(executable.openRead()).single).toString() ==
            selected.sha256;
    if (!executableExists) {
      problems.add('Bundled engine executable is missing.');
    }
    if (!checksumMatches) {
      problems.add('Engine checksum does not match manifest.');
    }
    final noticesFile = File(
      path.join(layout.compliance.path, 'THIRD_PARTY_NOTICES.md'),
    );
    final sourceOfferFile = File(
      path.join(layout.compliance.path, 'SOURCE_OFFER.md'),
    );
    final sbomFile = File(path.join(layout.compliance.path, 'sbom.spdx.json'));
    final notices = await _isNonempty(noticesFile);
    final sourceOffer = await _isNonempty(sourceOfferFile);
    final sbom = await _validSpdxSbom(sbomFile);
    if (!notices) problems.add('Third-party notices are missing.');
    if (!sourceOffer) problems.add('GPL source offer is missing.');
    if (!sbom) problems.add('SPDX SBOM is missing.');
    return BundleVerificationReport(
      engineVersion: manifest.version,
      engineTarget: target,
      engineChecksumMatches: checksumMatches,
      hasGplSourceOffer: sourceOffer,
      hasThirdPartyNotices: notices,
      hasSbom: sbom,
      problems: List<String>.unmodifiable(problems),
    );
  }
}

Future<bool> _isNonempty(File file) async =>
    await file.exists() && await file.length() > 0;

Future<bool> _validSpdxSbom(File file) async {
  if (!await _isNonempty(file)) return false;
  try {
    final root = jsonDecode(await file.readAsString());
    if (root is! Map<String, dynamic> || root['spdxVersion'] != 'SPDX-2.3') {
      return false;
    }
    final packages = root['packages'];
    final files = root['files'];
    if (packages is! List<dynamic> ||
        files is! List<dynamic> ||
        files.isEmpty) {
      return false;
    }
    final names = packages
        .whereType<Map<String, dynamic>>()
        .map((node) => node['name'])
        .whereType<String>()
        .toSet();
    if (!names.containsAll(<String>{
      'Gapless',
      'Flutter',
      'auto-editor',
      'media_kit_libs_video',
    })) {
      return false;
    }
    return files.whereType<Map<String, dynamic>>().every((node) {
      final checksums = node['checksums'];
      return node['fileName'] is String &&
          checksums is List<dynamic> &&
          checksums.whereType<Map<String, dynamic>>().any(
            (checksum) =>
                checksum['algorithm'] == 'SHA256' &&
                checksum['checksumValue'] is String,
          );
    });
  } on Object {
    return false;
  }
}

Future<void> main(List<String> arguments) async {
  if (arguments.length != 4 ||
      arguments[0] != '--bundle' ||
      arguments[2] != '--target') {
    stderr.writeln(
      'Usage: dart run tool/release/verify_bundle.dart '
      '--bundle PATH --target TARGET',
    );
    exitCode = 64;
    return;
  }
  try {
    final report = await const BundleVerifier().verify(
      Directory(path.absolute(arguments[1])),
      target: arguments[3],
    );
    if (!report.isValid) {
      for (final problem in report.problems) {
        stderr.writeln('error: $problem');
      }
      exitCode = 1;
      return;
    }
    stdout.writeln(
      'Verified Auto-Editor ${report.engineVersion} '
      '(${report.engineTarget}) and release compliance files.',
    );
  } on Object catch (error) {
    stderr.writeln('error: $error');
    exitCode = 1;
  }
}

final class _BundleLayout {
  const _BundleLayout(this.engine, this.compliance);

  final Directory engine;
  final Directory compliance;

  static _BundleLayout detect(Directory root) {
    if (root.path.toLowerCase().endsWith('.app')) {
      final resources = Directory(
        path.join(root.path, 'Contents', 'Resources'),
      );
      return _BundleLayout(
        Directory(path.join(resources.path, 'engine')),
        Directory(path.join(resources.path, 'compliance')),
      );
    }
    final linuxEngine = Directory(
      path.join(root.path, 'lib', 'gapless', 'engine'),
    );
    if (linuxEngine.existsSync()) {
      return _BundleLayout(
        linuxEngine,
        Directory(path.join(root.path, 'lib', 'gapless', 'compliance')),
      );
    }
    return _BundleLayout(
      Directory(path.join(root.path, 'engine')),
      Directory(path.join(root.path, 'compliance')),
    );
  }
}

final class _ReleaseManifest {
  const _ReleaseManifest(this.version, this.targets);

  final String version;
  final Map<String, _ReleaseTarget> targets;

  factory _ReleaseManifest.parse(String text) {
    final root = jsonDecode(text);
    if (root is! Map<String, dynamic> || root['engine'] != 'auto-editor') {
      throw const FormatException('Invalid Auto-Editor manifest.');
    }
    final version = root['version'];
    final nodes = root['targets'];
    if (version is! String || nodes is! Map<String, dynamic>) {
      throw const FormatException('Invalid Auto-Editor manifest fields.');
    }
    final targets = <String, _ReleaseTarget>{};
    for (final entry in nodes.entries) {
      final node = entry.value;
      if (node is! Map<String, dynamic>) continue;
      final file = node['installedFile'];
      final checksum = node['installedSha256'] ?? node['sha256'];
      if (file is String &&
          path.basename(file) == file &&
          checksum is String &&
          RegExp(r'^[0-9a-f]{64}$').hasMatch(checksum)) {
        targets[entry.key] = _ReleaseTarget(file, checksum);
      }
    }
    if (targets.isEmpty) {
      throw const FormatException('Manifest has no targets.');
    }
    return _ReleaseManifest(version, Map.unmodifiable(targets));
  }
}

final class _ReleaseTarget {
  const _ReleaseTarget(this.file, this.sha256);
  final String file;
  final String sha256;
}
