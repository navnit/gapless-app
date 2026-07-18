import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
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
        workflow.indexOf(
          'Import Apple signing and notarization credentials',
        ),
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

  test('requires installed-artifact proof before upload', () {
    for (final required in <String>[
      'MACOS_P12_BASE64',
      'MACOS_NOTARY_KEY_BASE64',
      'MACOS_SIGN_IDENTITY',
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
}
