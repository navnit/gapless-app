import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const macosReleaseSecrets = <String>[
    'MACOS_P12_BASE64',
    'MACOS_P12_PASSWORD',
    'MACOS_KEYCHAIN_PASSWORD',
    'MACOS_NOTARY_KEY_BASE64',
    'MACOS_NOTARY_KEY_ID',
    'MACOS_NOTARY_ISSUER',
    'MACOS_SIGN_IDENTITY',
  ];
  late File workflowFile;
  var workflow = '';

  setUpAll(() {
    workflowFile = File('.github/workflows/release-macos.yml');
    if (workflowFile.existsSync()) {
      workflow = workflowFile.readAsStringSync();
    }
  });

  test('has separate manual candidate and tag entry points', () {
    expect(workflowFile.existsSync(), isTrue);
    expect(workflow, contains('workflow_dispatch:'));
    expect(workflow, contains("default: '0.1.0'"));
    expect(workflow, contains("tags: ['v*']"));
    expect(
      workflow,
      contains(
        "github.event_name == 'push' && "
        "startsWith(github.ref, 'refs/tags/v')",
      ),
    );
  });

  test('releases only the two supported macOS architectures', () {
    final build = workflow.substring(
      workflow.indexOf('  build:'),
      workflow.indexOf('\n  publish:'),
    );

    expect(workflow, contains('target: macos-arm64'));
    expect(workflow, contains('os: macos-14'));
    expect(workflow, contains('target: macos-x64'));
    expect(workflow, contains('os: macos-15-intel'));
    for (final forbidden in <String>[
      'windows-x64',
      'windows-2025',
      'linux-x64',
      'ubuntu-24.04',
      'flutter build windows',
      'flutter build linux',
    ]) {
      expect(build, isNot(contains(forbidden)), reason: forbidden);
    }
    expect(File('.github/workflows/release.yml').existsSync(), isFalse);
  });

  test('validates version before engine and signing work', () {
    final validation = workflow.indexOf('validate_release_version.dart');
    expect(validation, greaterThanOrEqualTo(0));
    expect(validation, lessThan(workflow.indexOf('fetch_engine.dart')));
    expect(
      validation,
      lessThan(
        workflow.indexOf('Import Apple signing and notarization credentials'),
      ),
    );
    expect(
      workflow,
      contains(
        r'Gapless-${{ steps.version.outputs.value }}-'
        r'${{ matrix.target }}.dmg',
      ),
    );
  });

  test('keeps hostile manual version input out of the shell program', () {
    const hostileVersion = "0.1.0'; touch /tmp/pwned; echo '";
    expect(hostileVersion, contains("'"));
    expect(workflow, contains(r'DISPATCH_VERSION: ${{ inputs.version }}'));
    expect(workflow, contains(r'release_version="$DISPATCH_VERSION"'));

    final versionStep = workflow.substring(
      workflow.indexOf('      - name: Resolve and validate release version'),
      workflow.indexOf(
        '      - name: Validate signing and notarization secrets',
      ),
    );
    expect(
      versionStep,
      isNot(contains("release_version='\${{ inputs.version }}'")),
    );
    expect(
      versionStep.substring(versionStep.indexOf('        run: |')),
      isNot(contains(r'${{ inputs.version }}')),
    );
  });

  test('signs only main dispatches or tags at the fetched main commit', () {
    final refValidation = workflow.indexOf(
      '      - name: Require reviewed main revision',
    );
    final secretValidation = workflow.indexOf(
      '      - name: Validate signing and notarization secrets',
    );

    expect(refValidation, greaterThanOrEqualTo(0));
    expect(refValidation, lessThan(secretValidation));
    expect(workflow, contains(r'[ "$GITHUB_REF" = refs/heads/main ]'));
    expect(
      workflow,
      contains('git fetch --no-tags origin main:refs/remotes/origin/main'),
    );
    expect(
      workflow,
      contains(r'main_sha=$(git rev-parse origin/main^{commit})'),
    );
    expect(
      workflow,
      contains(r'release_sha=$(git rev-parse "$GITHUB_SHA^{commit}")'),
    );
    expect(workflow, contains(r'[ "$release_sha" = "$main_sha" ]'));
  });

  test('protects every credential-bearing build with macos-release', () {
    final buildHeader = workflow.substring(
      workflow.indexOf('  build:'),
      workflow.indexOf('    steps:'),
    );

    expect(buildHeader, contains('environment:'));
    expect(buildHeader, contains('name: macos-release'));
    expect(
      workflow.substring(workflow.indexOf('  publish:')),
      contains('name: macos-release'),
    );
  });

  test('requires installed-artifact proof before upload', () {
    for (final required in <String>[
      ...macosReleaseSecrets,
      'notarytool store-credentials',
      'package_dmg.sh',
      'spctl --assess --type execute',
      '--smoke-test',
      'verify_bundle.dart',
      'integration_test/editor_workflow_test.dart',
      'integration_test/recovery_workflow_test.dart',
      'actions/upload-artifact',
    ]) {
      expect(workflow, contains(required), reason: required);
    }
  });

  test('generates and verifies each public SBOM from the final signed app', () {
    final package = workflow.indexOf('packaging/macos/package_dmg.sh');
    final finalSbom = workflow.indexOf(
      '      - name: Generate and verify final signed-app SBOM',
    );
    final smoke = workflow.indexOf(
      '      - name: Smoke test installed macOS DMG',
    );

    expect(finalSbom, greaterThan(package));
    expect(finalSbom, lessThan(smoke));
    expect(
      workflow,
      contains(
        'Contents/Resources/compliance/sbom.spdx.json '
        r'--target "${{ matrix.target }}" '
        '--phase pre-sign-embedded',
      ),
    );
    expect(
      workflow,
      contains(
        r'--output "build/sbom-${{ matrix.target }}.spdx.json" '
        r'--target "${{ matrix.target }}" '
        '--phase post-sign-external',
      ),
    );
    expect(
      workflow,
      contains(
        r'--bundle build/macos/Build/Products/Release/Gapless.app '
        r'--target "${{ matrix.target }}" '
        r'--sbom "build/sbom-${{ matrix.target }}.spdx.json"',
      ),
    );
    expect(
      workflow,
      contains(
        r'--bundle "$mount/Gapless.app" --target "${{ matrix.target }}" '
        r'--sbom "$GITHUB_WORKSPACE/build/sbom-${{ matrix.target }}.spdx.json"',
      ),
    );
    expect(
      workflow,
      isNot(
        contains(
          'cp macos/Build/Products/Release/Gapless.app/Contents/Resources/'
          'compliance/sbom.spdx.json',
        ),
      ),
    );
  });

  test('publishes through a protected least-privilege tag job', () {
    final publish = workflow.substring(workflow.indexOf('  publish:'));
    expect(publish, contains('needs: build'));
    expect(publish, contains('name: macos-release'));
    expect(publish, contains('contents: write'));
    expect(publish, contains('generate_release_notes: true'));
    expect(publish, contains('softprops/action-gh-release@'));
    expect(
      workflow.substring(0, workflow.indexOf('  publish:')),
      contains('contents: read'),
    );
  });

  test('refuses to replace an existing public release or its assets', () {
    final publish = workflow.substring(workflow.indexOf('  publish:'));
    final preflight = publish.indexOf(
      '      - name: Refuse an existing GitHub Release',
    );
    final releaseAction = publish.indexOf('softprops/action-gh-release@');

    expect(preflight, greaterThanOrEqualTo(0));
    expect(preflight, lessThan(releaseAction));
    expect(publish, contains(r'/releases/tags/$GITHUB_REF_NAME'));
    expect(publish, contains(r'case "$status" in'));
    expect(publish, contains('200)'));
    expect(publish, contains('404)'));
    expect(publish, contains('overwrite_files: false'));
  });

  test('documents the public macOS-only 0.1.0 download', () {
    final readme = File('README.md').readAsStringSync();
    final building = File('docs/building.md').readAsStringSync();

    expect(readme, contains('Gapless 0.1.0'));
    expect(
      readme,
      contains('https://github.com/navnit/gapless/releases/latest'),
    );
    expect(readme, contains('Windows and Linux remain planned targets'));
    expect(building, contains('Ubuntu 24.04/glibc 2.39 baseline'));
    expect(building, contains('v0.1.0'));
    expect(building, contains('macos-release'));
    expect(building, contains('first public release target'));
    expect(
      building,
      contains(
        'Public downloads become available only after the protected tag '
        'workflow succeeds and approval completes.',
      ),
    );
    expect(
      building,
      contains('https://github.com/navnit/gapless/releases/latest'),
    );
    for (final secret in macosReleaseSecrets) {
      expect(building, contains(secret), reason: secret);
    }
    expect(building, contains('macos-release environment secrets'));
    expect(building, isNot(contains('requires these repository secrets')));
    expect(building, contains('protected `main`'));
    expect(building, contains('`v*` tag ruleset'));
    expect(building, contains('blocks tag updates and deletions'));
  });

  test('documents mandatory protected-environment deployment rules', () {
    final building = File('docs/building.md').readAsStringSync();

    expect(building, contains('Deployment branches and tags'));
    expect(building, contains('Selected branches and tags'));
    expect(building, contains('only `main` and `v0.1.0`'));
    expect(building, contains('Require at least one reviewer'));
    expect(building, contains('enable `Prevent self-review`'));
  });

  test('documents approval before credential-bearing builds and signing', () {
    final building = File('docs/building.md').readAsStringSync();

    expect(
      RegExp(
        r'approval happens before\s+credential-bearing matrix builds and signing',
      ).hasMatch(building),
      isTrue,
    );
    expect(
      building,
      contains('Publication remains protected and approval-gated.'),
    );
  });
}
