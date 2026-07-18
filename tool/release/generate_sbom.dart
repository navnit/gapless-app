import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

Future<void> main(List<String> arguments) async {
  final options = _Options.parse(arguments);
  final packages = await _resolvedPackages();
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
    'name': 'Gapless-${Platform.environment['GITHUB_REF_NAME'] ?? 'local'}',
    'documentNamespace': 'https://gapless.invalid/spdx/${revision.sha}',
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

Future<List<Map<String, Object>>> _resolvedPackages() async {
  final lock = await File('pubspec.lock').readAsLines();
  final packages = <Map<String, Object>>[
    <String, Object>{
      'SPDXID': 'SPDXRef-Package-gapless',
      'name': 'Gapless',
      'versionInfo': '1.0.0',
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
  const _Options({required this.output, this.bundle});

  final File output;
  final Directory? bundle;

  factory _Options.parse(List<String> arguments) {
    if (arguments.isEmpty) {
      return _Options(output: File('build/release/sbom.spdx.json'));
    }
    String? output;
    String? bundle;
    for (var index = 0; index < arguments.length; index += 2) {
      if (index + 1 >= arguments.length) throw const FormatException('args');
      switch (arguments[index]) {
        case '--output':
          output = arguments[index + 1];
        case '--bundle':
          bundle = arguments[index + 1];
        default:
          throw FormatException('Unknown argument: ${arguments[index]}');
      }
    }
    if (output == null || bundle == null) {
      throw const FormatException('--bundle and --output are required.');
    }
    return _Options(
      output: File(path.absolute(output)),
      bundle: Directory(path.absolute(bundle)),
    );
  }
}
