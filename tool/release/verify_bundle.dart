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
    File? sbomFile,
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
    final selectedSbom =
        sbomFile ?? File(path.join(layout.compliance.path, 'sbom.spdx.json'));
    final notices = await _isNonempty(noticesFile);
    final sourceOffer = await _isNonempty(sourceOfferFile);
    final sbomVerification = await _verifySpdxSbom(
      selectedSbom,
      bundleRoot: sbomFile == null ? null : bundleRoot,
      target: target,
    );
    final sbom = sbomVerification.isValid;
    if (!notices) problems.add('Third-party notices are missing.');
    if (!sourceOffer) problems.add('GPL source offer is missing.');
    if (!sbomVerification.hasValidShape) {
      problems.add('SPDX SBOM is missing.');
    } else if (!sbomVerification.hasExactCoverage) {
      problems.add('SPDX SBOM does not match bundle files.');
    } else if (!sbomVerification.checksumsMatch) {
      problems.add('SPDX SBOM SHA-256 does not match bundle files.');
    }
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

Future<_SbomVerification> _verifySpdxSbom(
  File file, {
  required Directory? bundleRoot,
  required String target,
}) async {
  if (!await _isNonempty(file)) return _SbomVerification.invalid;
  try {
    final root = jsonDecode(await file.readAsString());
    if (root is! Map<String, dynamic> || root['spdxVersion'] != 'SPDX-2.3') {
      return _SbomVerification.invalid;
    }
    final packages = root['packages'];
    final files = root['files'];
    if (packages is! List<dynamic> ||
        files is! List<dynamic> ||
        files.isEmpty) {
      return _SbomVerification.invalid;
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
      return _SbomVerification.invalid;
    }
    final spdxFiles = files.whereType<Map<String, dynamic>>().toList();
    final validFiles =
        spdxFiles.length == files.length &&
        spdxFiles.every((node) {
          final checksums = node['checksums'];
          return node['fileName'] is String &&
              checksums is List<dynamic> &&
              checksums.whereType<Map<String, dynamic>>().any(
                (checksum) =>
                    checksum['algorithm'] == 'SHA256' &&
                    checksum['checksumValue'] is String &&
                    RegExp(
                      r'^[0-9a-f]{64}$',
                    ).hasMatch(checksum['checksumValue']! as String),
              );
        });
    if (!validFiles) return _SbomVerification.invalid;
    if (bundleRoot == null) return _SbomVerification.shapeOnly;

    final namespace = root['documentNamespace'];
    if (namespace is! String ||
        !RegExp(
          '^https://gapless\\.invalid/spdx/[0-9a-f]{40}/'
          '${RegExp.escape(target)}/post-sign-external\$',
        ).hasMatch(namespace)) {
      return _SbomVerification.invalid;
    }

    final actualFiles = await bundleRoot
        .list(recursive: true, followLinks: false)
        .where((entity) => entity is File)
        .cast<File>()
        .toList();
    final actualByName = <String, File>{
      for (final actual in actualFiles)
        path.posix.join(
          '.',
          path
              .relative(actual.path, from: bundleRoot.path)
              .replaceAll('\\', '/'),
        ): actual,
    };
    final expectedChecksums = <String, String>{};
    var validNames = true;
    for (final node in spdxFiles) {
      final name = node['fileName']! as String;
      final relativeName = name.startsWith('./') ? name.substring(2) : '';
      if (relativeName.isEmpty ||
          name.contains('\\') ||
          path.posix.isAbsolute(relativeName) ||
          path.posix.normalize(relativeName) != relativeName ||
          expectedChecksums.containsKey(name)) {
        validNames = false;
        continue;
      }
      final checksums = node['checksums']! as List<dynamic>;
      final checksum = checksums.whereType<Map<String, dynamic>>().firstWhere(
        (candidate) => candidate['algorithm'] == 'SHA256',
      );
      expectedChecksums[name] = checksum['checksumValue']! as String;
    }
    final hasExactCoverage =
        validNames &&
        expectedChecksums.length == actualByName.length &&
        expectedChecksums.keys.toSet().containsAll(actualByName.keys) &&
        actualByName.keys.toSet().containsAll(expectedChecksums.keys);
    if (!hasExactCoverage) {
      return const _SbomVerification(
        hasValidShape: true,
        hasExactCoverage: false,
        checksumsMatch: false,
      );
    }
    for (final entry in actualByName.entries) {
      final actualChecksum = (await sha256.bind(entry.value.openRead()).single)
          .toString();
      if (actualChecksum != expectedChecksums[entry.key]) {
        return const _SbomVerification(
          hasValidShape: true,
          hasExactCoverage: true,
          checksumsMatch: false,
        );
      }
    }
    return _SbomVerification.valid;
  } on Object {
    return _SbomVerification.invalid;
  }
}

final class _SbomVerification {
  const _SbomVerification({
    required this.hasValidShape,
    required this.hasExactCoverage,
    required this.checksumsMatch,
  });

  static const invalid = _SbomVerification(
    hasValidShape: false,
    hasExactCoverage: false,
    checksumsMatch: false,
  );
  static const shapeOnly = _SbomVerification(
    hasValidShape: true,
    hasExactCoverage: true,
    checksumsMatch: true,
  );
  static const valid = shapeOnly;

  final bool hasValidShape;
  final bool hasExactCoverage;
  final bool checksumsMatch;

  bool get isValid => hasValidShape && hasExactCoverage && checksumsMatch;
}

Future<void> main(List<String> arguments) async {
  if ((arguments.length != 4 && arguments.length != 6) ||
      arguments[0] != '--bundle' ||
      arguments[2] != '--target' ||
      (arguments.length == 6 && arguments[4] != '--sbom')) {
    stderr.writeln(
      'Usage: dart run tool/release/verify_bundle.dart '
      '--bundle PATH --target TARGET [--sbom PATH]',
    );
    exitCode = 64;
    return;
  }
  try {
    final report = await const BundleVerifier().verify(
      Directory(path.absolute(arguments[1])),
      target: arguments[3],
      sbomFile: arguments.length == 6
          ? File(path.absolute(arguments[5]))
          : null,
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
