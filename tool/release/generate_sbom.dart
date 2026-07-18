import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import 'validate_release_version.dart';

Future<void> main(List<String> arguments) async {
  final options = _Options.parse(arguments);
  final appVersion = ReleaseVersion.parsePubspec(
    await File('pubspec.yaml').readAsString(),
  );
  final packages = await resolvedPackages(gaplessVersion: appVersion.name);
  final files = <Map<String, Object>>[];
  final relationships = <Map<String, String>>[
    for (final package in packages)
      <String, String>{
        'spdxElementId': 'SPDXRef-DOCUMENT',
        'relationshipType': 'DESCRIBES',
        'relatedSpdxElement': package['SPDXID']! as String,
      },
  ];
  if (options.bundle case final bundle?) {
    final entities = await bundle
        .list(recursive: true, followLinks: false)
        .where((entity) => entity is File)
        .cast<File>()
        .toList();
    entities.sort((left, right) => left.path.compareTo(right.path));
    for (var index = 0; index < entities.length; index++) {
      final file = entities[index];
      if (path.equals(file.path, options.output.path)) continue;
      final id = 'SPDXRef-File-$index';
      files.add(<String, Object>{
        'SPDXID': id,
        'fileName': path.posix.join(
          '.',
          path.relative(file.path, from: bundle.path).replaceAll('\\', '/'),
        ),
        'checksums': <Map<String, String>>[
          <String, String>{
            'algorithm': 'SHA256',
            'checksumValue': (await sha256.bind(file.openRead()).single)
                .toString(),
          },
        ],
        'licenseConcluded': 'NOASSERTION',
        'copyrightText': 'NOASSERTION',
      });
      relationships.add(<String, String>{
        'spdxElementId': 'SPDXRef-Package-gapless',
        'relationshipType': 'CONTAINS',
        'relatedSpdxElement': id,
      });
    }
  }
  final revision = await _revisionIdentity();
  final document = <String, Object>{
    'spdxVersion': 'SPDX-2.3',
    'dataLicense': 'CC0-1.0',
    'SPDXID': 'SPDXRef-DOCUMENT',
    'name':
        'Gapless-${Platform.environment['GITHUB_REF_NAME'] ?? 'local'}-'
        '${options.target ?? 'source'}',
    'documentNamespace': sbomDocumentNamespace(
      revisionSha: revision.sha,
      target: options.target ?? 'source',
      phase: options.phase,
    ),
    'creationInfo': <String, Object>{
      'created': revision.created.toIso8601String(),
      'creators': <String>['Tool: Gapless-generate-sbom'],
    },
    'packages': packages,
    'files': files,
    'relationships': relationships,
  };
  await options.output.parent.create(recursive: true);
  await options.output.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(document)}\n',
    flush: true,
  );
}

String sbomDocumentNamespace({
  required String revisionSha,
  required String target,
  required String phase,
}) {
  if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(revisionSha)) {
    throw const FormatException('SBOM revision must be a full Git SHA.');
  }
  if (!RegExp(r'^[a-z0-9-]+$').hasMatch(target)) {
    throw const FormatException('SBOM target contains invalid characters.');
  }
  if (!RegExp(r'^[a-z0-9-]+$').hasMatch(phase)) {
    throw const FormatException('SBOM phase contains invalid characters.');
  }
  return 'https://gapless.invalid/spdx/$revisionSha/$target/$phase';
}

Future<List<Map<String, Object>>> resolvedPackages({
  required String gaplessVersion,
  File? lockFile,
}) async {
  final lock = await (lockFile ?? File('pubspec.lock')).readAsLines();
  final packages = <Map<String, Object>>[
    <String, Object>{
      'SPDXID': 'SPDXRef-Package-gapless',
      'name': 'Gapless',
      'versionInfo': gaplessVersion,
      'downloadLocation': 'NOASSERTION',
      'filesAnalyzed': false,
      'licenseConcluded': 'GPL-3.0-or-later',
      'licenseDeclared': 'GPL-3.0-or-later',
    },
    <String, Object>{
      'SPDXID': 'SPDXRef-Package-flutter',
      'name': 'Flutter',
      'versionInfo': '3.44.4',
      'downloadLocation': 'https://github.com/flutter/flutter/tree/3.44.4',
      'filesAnalyzed': false,
      'licenseConcluded': 'BSD-3-Clause',
      'licenseDeclared': 'BSD-3-Clause',
    },
  ];
  for (var index = 0; index < lock.length; index++) {
    final match = RegExp(r'^  ([a-zA-Z0-9_]+):$').firstMatch(lock[index]);
    if (match == null) continue;
    String? version;
    for (
      var cursor = index + 1;
      cursor < lock.length && lock[cursor].startsWith('    ');
      cursor++
    ) {
      version ??= RegExp(
        r'^    version: "?([^" ]+)"?$',
      ).firstMatch(lock[cursor])?.group(1);
    }
    if (version == null) continue;
    final name = match.group(1)!;
    packages.add(<String, Object>{
      'SPDXID': 'SPDXRef-Package-$name',
      'name': name,
      'versionInfo': version,
      'downloadLocation': 'https://pub.dev/packages/$name/versions/$version',
      'filesAnalyzed': false,
      'licenseConcluded': 'NOASSERTION',
      'licenseDeclared': 'NOASSERTION',
    });
  }
  packages.add(<String, Object>{
    'SPDXID': 'SPDXRef-Package-auto-editor',
    'name': 'auto-editor',
    'versionInfo': '31.2.0',
    'downloadLocation': 'https://github.com/WyattBlue/auto-editor/tree/31.2.0',
    'filesAnalyzed': false,
    'licenseConcluded': 'Unlicense',
    'licenseDeclared': 'Unlicense',
    'comment': 'The release executable is inventoried by SHA-256 in files.',
  });
  return packages;
}

Future<({String sha, DateTime created})> _revisionIdentity() async {
  final result = await Process.run('git', <String>[
    'show',
    '-s',
    '--format=%H%n%ct',
    'HEAD',
  ]);
  if (result.exitCode != 0) {
    throw StateError('Could not determine the source revision for the SBOM.');
  }
  final lines = (result.stdout as String).trim().split('\n');
  if (lines.length != 2 || !RegExp(r'^[0-9a-f]{40}$').hasMatch(lines.first)) {
    throw const FormatException('Unexpected git revision output.');
  }
  return (
    sha: lines.first,
    created: DateTime.fromMillisecondsSinceEpoch(
      int.parse(lines.last) * Duration.millisecondsPerSecond,
      isUtc: true,
    ),
  );
}

final class _Options {
  const _Options({
    required this.output,
    required this.phase,
    this.bundle,
    this.target,
  });

  final File output;
  final Directory? bundle;
  final String? target;
  final String phase;

  factory _Options.parse(List<String> arguments) {
    if (arguments.isEmpty) {
      return _Options(
        output: File('build/release/sbom.spdx.json'),
        phase: 'source',
      );
    }
    String? output;
    String? bundle;
    String? target;
    String? phase;
    for (var index = 0; index < arguments.length; index += 2) {
      if (index + 1 >= arguments.length) throw const FormatException('args');
      switch (arguments[index]) {
        case '--output':
          output = arguments[index + 1];
        case '--bundle':
          bundle = arguments[index + 1];
        case '--target':
          target = arguments[index + 1];
        case '--phase':
          phase = arguments[index + 1];
        default:
          throw FormatException('Unknown argument: ${arguments[index]}');
      }
    }
    if (output == null || bundle == null || target == null || phase == null) {
      throw const FormatException(
        '--bundle, --output, --target, and --phase are required.',
      );
    }
    return _Options(
      output: File(path.absolute(output)),
      bundle: Directory(path.absolute(bundle)),
      target: target,
      phase: phase,
    );
  }
}
