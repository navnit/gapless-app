import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/core/errors/app_failure.dart';
import 'package:gapless/core/errors/failure_presenter.dart';

void main() {
  group('FailurePresenter.present', () {
    final mappings =
        <
          ({
            AppFailure failure,
            String title,
            FailureAction primary,
            FailureAction? secondary,
          })
        >[
          (
            failure: const ProjectFormatFailure('schema is invalid'),
            title: 'Project could not be opened',
            primary: FailureAction.retry,
            secondary: FailureAction.copyDiagnostics,
          ),
          (
            failure: ProjectSaveFailure(
              Uri.file('/projects/interview.gapless'),
              StateError('write failed'),
            ),
            title: 'Project could not be saved',
            primary: FailureAction.saveAs,
            secondary: FailureAction.copyDiagnostics,
          ),
          (
            failure: const SourceMissingFailure(),
            title: 'Source video not found',
            primary: FailureAction.relocate,
            secondary: null,
          ),
          (
            failure: const SourceChangedFailure(
              expectedFingerprint: 'expected',
              actualFingerprint: 'actual',
            ),
            title: 'Source video changed',
            primary: FailureAction.relocate,
            secondary: FailureAction.copyDiagnostics,
          ),
          (
            failure: const EngineMissingFailure(),
            title: 'Editing engine is missing',
            primary: FailureAction.reinstall,
            secondary: FailureAction.copyDiagnostics,
          ),
          (
            failure: const EngineChecksumFailure(
              expectedSha256: 'expected',
              actualSha256: 'actual',
            ),
            title: 'Editing engine could not be verified',
            primary: FailureAction.reinstall,
            secondary: FailureAction.copyDiagnostics,
          ),
          (
            failure: DiskFullFailure(
              destination: Uri.file('/exports/interview.mp4'),
            ),
            title: 'Not enough free space',
            primary: FailureAction.chooseDestination,
            secondary: FailureAction.copyDiagnostics,
          ),
        ];

    for (final mapping in mappings) {
      test('maps ${mapping.failure.runtimeType}', () {
        final presentation = FailurePresenter.present(mapping.failure);

        expect(presentation.title, mapping.title);
        expect(presentation.primaryAction, mapping.primary);
        expect(presentation.secondaryAction, mapping.secondary);
        expect(presentation.body, isNotEmpty);
        expect(presentation.destructive, isFalse);
      });
    }

    for (final reason in EngineContractReason.values) {
      test('maps EngineContractFailure.$reason to retry and diagnostics', () {
        final presentation = FailurePresenter.present(
          EngineContractFailure(operation: 'analysis', reason: reason),
        );

        expect(
          presentation.title,
          reason == EngineContractReason.unsupportedSources
              ? 'A video file is required'
              : 'Editing engine could not finish',
        );
        if (reason == EngineContractReason.unsupportedSources) {
          expect(presentation.body, contains('Audio-only files'));
        }
        expect(presentation.primaryAction, FailureAction.retry);
        expect(presentation.secondaryAction, FailureAction.copyDiagnostics);
        expect(presentation.destructive, isFalse);
      });
    }

    for (final reason in MediaReadReason.values) {
      test('maps MediaReadFailure.$reason without destructive actions', () {
        final presentation = FailurePresenter.present(
          MediaReadFailure(
            source: Uri.file('/videos/interview.mp4'),
            reason: reason,
          ),
        );

        if (reason == MediaReadReason.noAudio) {
          expect(presentation.title, 'This video has no audio track');
          expect(presentation.primaryAction, FailureAction.useMotion);
          expect(presentation.secondaryAction, isNull);
        } else {
          expect(presentation.primaryAction, FailureAction.retry);
          expect(presentation.secondaryAction, FailureAction.copyDiagnostics);
        }
        expect(presentation.destructive, isFalse);
      });
    }

    test('rejects cancellation because it is a ready-state outcome', () {
      expect(
        () => FailurePresenter.present(
          const OperationCancelled(operation: 'analysis'),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Cancellation is handled as a ready state',
          ),
        ),
      );
    });

    test('uses every non-destructive recovery action', () {
      final failures = <AppFailure>[
        ...mappings.map((mapping) => mapping.failure),
        EngineContractFailure(
          operation: 'analysis',
          reason: EngineContractReason.unexpectedExit,
        ),
        MediaReadFailure(
          source: Uri.file('/videos/interview.mp4'),
          reason: MediaReadReason.noAudio,
        ),
      ];
      final actions = <FailureAction>{};
      for (final failure in failures) {
        final presentation = FailurePresenter.present(failure);
        actions.add(presentation.primaryAction);
        final secondary = presentation.secondaryAction;
        if (secondary != null) actions.add(secondary);
      }

      expect(actions, FailureAction.values.toSet());
    });

    test('presentation values are const immutable contracts', () {
      const first = FailurePresentation(
        title: 'Source video not found',
        body: 'Locate the original video to continue editing this project.',
        primaryAction: FailureAction.relocate,
      );
      const second = FailurePresentation(
        title: 'Source video not found',
        body: 'Locate the original video to continue editing this project.',
        primaryAction: FailureAction.relocate,
      );

      expect(identical(first, second), isTrue);
      expect(first.destructive, isFalse);
    });
  });

  group('FailurePresenter.formatDiagnostics', () {
    test('uses stable headings and typed engine facts', () {
      final copy = FailurePresenter.formatDiagnostics(
        appVersion: '1.2.3',
        engineVersion: '31.2.0',
        platform: 'macOS 15 arm64',
        stage: 'analysis',
        failure: EngineContractFailure(
          operation: 'levels',
          reason: EngineContractReason.unexpectedExit,
          exitCode: 17,
          diagnostics: const <String>['process stopped'],
        ),
      );

      expect(copy, startsWith('Gapless diagnostics\n'));
      expect(copy, contains('\nApp: 1.2.3\n'));
      expect(copy, contains('Engine: 31.2.0'));
      expect(copy, contains('Platform: macOS 15 arm64'));
      expect(copy, contains('Stage: analysis'));
      expect(copy, contains('Failure: EngineContractFailure'));
      expect(copy, contains('Facts:\n'));
      expect(copy, contains('- Operation: levels'));
      expect(copy, contains('- Reason: unexpectedExit'));
      expect(copy, contains('- Exit code: 17'));
      expect(copy, contains('Diagnostics:\n- process stopped'));
    });

    test('redacts paths URI metadata and common secrets', () {
      final copy = FailurePresenter.formatDiagnostics(
        appVersion: '1.2.3 token=topsecret',
        engineVersion: '31.2.0',
        platform: r'''Windows path='C:\Users\Alice\Private Clip.mp4' done''',
        stage: 'open "~/Movies/Private Stage.mov" safely',
        failure: EngineContractFailure(
          operation: 'render "/Users/alice/Movies/Private Interview.mp4" done',
          reason: EngineContractReason.unexpectedExit,
          diagnostics: const <String>[
            'file:///Users/alice/clip.mp4?token=query-secret#fragment-secret',
            r'C:\Users\Alice\My Private Video.mp4 password=hunter2',
            'read /Users/alice/My Private Video.mp4, then retry',
            'open [/Users/alice/Bracketed Private.mp4] then retry',
            'https://uri-user-sentinel:uri-secret-sentinel@example.invalid/'
                'path?view=private#fragment',
            'Authorization: Bearer abc.def.ghi',
          ],
        ),
      );

      for (final secret in <String>[
        'topsecret',
        'Alice',
        'alice',
        'query-secret',
        'fragment-secret',
        'hunter2',
        'abc.def.ghi',
        'Private Video.mp4',
        'Private Clip.mp4',
        'Private Stage.mov',
        'Private Interview.mp4',
        'Bracketed Private.mp4',
        'uri-user-sentinel',
        'uri-secret-sentinel',
      ]) {
        expect(copy, isNot(contains(secret)));
      }
      expect(copy, contains('[redacted]'));
      expect(copy, contains('[path]'));
      expect(copy, isNot(contains('?token=')));
      expect(copy, isNot(contains('#fragment')));
      expect(copy, contains('done'));
      expect(copy, contains('safely'));
      expect(copy, contains('then retry'));
    });

    test('redacts prefixed credentials auth headers and cookies', () {
      final copy = FailurePresenter.formatDiagnostics(
        appVersion: '1.2.3',
        engineVersion: '31.2.0',
        platform: 'linux x64',
        stage: 'render',
        failure: EngineContractFailure(
          operation: 'export',
          reason: EngineContractReason.unexpectedExit,
          diagnostics: const <String>[
            'GITHUB_TOKEN=unique-github-token-value',
            'AWS_SECRET_ACCESS_KEY=unique-aws-access-value',
            'SIGNING_PRIVATE_KEY=unique-private-key-value',
            'DATABASE_CREDENTIAL=unique-database-credential-value',
            'EDITOR_SESSION_ID=unique-session-id-value',
            'Authorization: Basic unique-basic-auth-value',
            'Cookie: session=unique-cookie-value; theme=dark',
            'Set-Cookie: auth=unique-set-cookie-value; HttpOnly',
          ],
        ),
      );

      for (final secret in <String>[
        'unique-github-token-value',
        'unique-aws-access-value',
        'unique-private-key-value',
        'unique-database-credential-value',
        'unique-session-id-value',
        'unique-basic-auth-value',
        'unique-cookie-value',
        'unique-set-cookie-value',
      ]) {
        expect(copy, isNot(contains(secret)));
      }
      for (final rawKey in <String>[
        'GITHUB_TOKEN',
        'AWS_SECRET_ACCESS_KEY',
        'SIGNING_PRIVATE_KEY',
        'DATABASE_CREDENTIAL',
        'EDITOR_SESSION_ID',
        'Authorization:',
        'Cookie:',
        'Set-Cookie:',
      ]) {
        expect(copy, isNot(contains(rawKey)));
      }
    });

    test('bounds diagnostic entries and final output deterministically', () {
      final longValue = List<String>.filled(1200, 'x').join();
      final failure = EngineContractFailure(
        operation: 'render',
        reason: EngineContractReason.unexpectedExit,
        diagnostics: List<String>.generate(
          40,
          (index) => 'diagnostic-$index $longValue',
        ),
      );

      final first = FailurePresenter.formatDiagnostics(
        appVersion: longValue,
        engineVersion: longValue,
        platform: longValue,
        stage: longValue,
        failure: failure,
      );
      final second = FailurePresenter.formatDiagnostics(
        appVersion: longValue,
        engineVersion: longValue,
        platform: longValue,
        stage: longValue,
        failure: failure,
      );
      final diagnosticLines = first
          .split('\n')
          .skipWhile((line) => line != 'Diagnostics:')
          .skip(1)
          .where((line) => line.startsWith('- '));

      expect(first, second);
      expect(first.length, lessThanOrEqualTo(4096));
      expect(diagnosticLines.every((line) => line.length <= 322), isTrue);
    });

    test('redacts common environment assignments from diagnostics', () {
      const environment = <String, String>{
        'PATH': 'unique-path-environment-value',
        'HOME': 'unique-home-environment-value',
        'USER': 'unique-user-environment-value',
        'USERNAME': 'unique-username-environment-value',
        'USERPROFILE': 'unique-userprofile-environment-value',
        'APPDATA': 'unique-appdata-environment-value',
        'LOCALAPPDATA': 'unique-localappdata-environment-value',
        'TEMP': 'unique-temp-environment-value',
        'TMP': 'unique-tmp-environment-value',
        'SHELL': 'unique-shell-environment-value',
      };
      final copy = FailurePresenter.formatDiagnostics(
        appVersion: '1.2.3',
        engineVersion: '31.2.0',
        platform: 'linux x64',
        stage: 'probe',
        failure: EngineContractFailure(
          operation: 'probe',
          reason: EngineContractReason.unexpectedExit,
          diagnostics: environment.entries
              .map((entry) => '${entry.key}=${entry.value}')
              .toList(growable: false),
        ),
      );

      for (final entry in environment.entries) {
        expect(copy, isNot(contains(entry.key)));
        expect(copy, isNot(contains(entry.value)));
      }
      expect(copy, contains('[environment]=[redacted]'));
    });
  });
}
