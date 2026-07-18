import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import '../../../tool/release/generate_sbom.dart';
import '../../../tool/release/verify_bundle.dart';

void main() {
  test(
    'release bundle contains exact executable and compliance files',
    () async {
      final root = await Directory.systemTemp.createTemp('gapless-bundle-');
      addTearDown(() => root.delete(recursive: true));
      final engine = File(path.join(root.path, 'engine', 'auto-editor.exe'));
      await engine.parent.create(recursive: true);
      await engine.writeAsBytes(<int>[1, 2, 3, 4]);
      final checksum = sha256.convert(await engine.readAsBytes()).toString();
      await File(path.join(engine.parent.path, 'manifest.json')).writeAsString(
        jsonEncode(<String, Object>{
          'engine': 'auto-editor',
          'version': '31.2.0',
          'targets': <String, Object>{
            'windows-x64': <String, Object>{
              'installedFile': 'auto-editor.exe',
              'sha256': checksum,
            },
          },
        }),
      );
      final compliance = Directory(path.join(root.path, 'compliance'));
      await compliance.create();
      await File(
        path.join(compliance.path, 'THIRD_PARTY_NOTICES.md'),
      ).writeAsString('Auto-Editor and dependency notices');
      await File(
        path.join(compliance.path, 'SOURCE_OFFER.md'),
      ).writeAsString('Corresponding source for GPL components');
      await File(path.join(compliance.path, 'sbom.spdx.json')).writeAsString(
        jsonEncode(<String, Object>{
          'spdxVersion': 'SPDX-2.3',
          'packages': <Map<String, String>>[
            for (final name in <String>[
              'Gapless',
              'Flutter',
              'auto-editor',
              'media_kit_libs_video',
            ])
              <String, String>{'name': name},
          ],
          'files': <Map<String, Object>>[
            <String, Object>{
              'fileName': './gapless.exe',
              'checksums': <Map<String, String>>[
                <String, String>{
                  'algorithm': 'SHA256',
                  'checksumValue': checksum,
                },
              ],
            },
          ],
        }),
      );

      final report = await BundleVerifier().verify(root, target: 'windows-x64');

      expect(report.engineVersion, '31.2.0');
      expect(report.engineTarget, 'windows-x64');
      expect(report.engineChecksumMatches, isTrue);
      expect(report.hasGplSourceOffer, isTrue);
      expect(report.hasThirdPartyNotices, isTrue);
      expect(report.hasSbom, isTrue);
      expect(report.isValid, isTrue);
    },
  );

  test('checksum and missing compliance failures are reported', () async {
    final root = await Directory.systemTemp.createTemp('gapless-bundle-');
    addTearDown(() => root.delete(recursive: true));
    final engine = File(path.join(root.path, 'engine', 'auto-editor.exe'));
    await engine.parent.create(recursive: true);
    await engine.writeAsBytes(<int>[9]);
    await File(path.join(engine.parent.path, 'manifest.json')).writeAsString(
      jsonEncode(<String, Object>{
        'engine': 'auto-editor',
        'version': '31.2.0',
        'targets': <String, Object>{
          'windows-x64': <String, Object>{
            'installedFile': 'auto-editor.exe',
            'sha256': List<String>.filled(64, '0').join(),
          },
        },
      }),
    );

    final report = await BundleVerifier().verify(root, target: 'windows-x64');

    expect(report.isValid, isFalse);
    expect(
      report.problems,
      contains('Engine checksum does not match manifest.'),
    );
    expect(report.problems, contains('Third-party notices are missing.'));
  });

  test('SBOM uses the supplied Gapless application version', () async {
    final temp = await Directory.systemTemp.createTemp('gapless-sbom-');
    addTearDown(() => temp.delete(recursive: true));
    final lock = File(path.join(temp.path, 'pubspec.lock'));
    await lock.writeAsString('''
packages:
  path:
    dependency: transitive
    description:
      name: path
    source: hosted
    version: "1.9.1"
''');

    final packages = await resolvedPackages(
      gaplessVersion: '0.1.0',
      lockFile: lock,
    );
    final gapless = packages.singleWhere((node) => node['name'] == 'Gapless');

    expect(gapless['versionInfo'], '0.1.0');
  });
}
