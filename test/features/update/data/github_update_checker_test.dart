import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:gapless/features/update/domain/update_status.dart';
import 'package:gapless/features/update/domain/update_checker_port.dart';
import 'package:gapless/features/update/data/github_update_checker.dart';

String _payload() => jsonEncode({
  'tag_name': 'v0.2.0',
  'html_url': 'https://github.com/navnit/gapless-app/releases/tag/v0.2.0',
  'body': 'Release notes',
  'assets': [
    {
      'name': 'Gapless-0.2.0-macos-arm64-UNNOTARIZED.dmg',
      'browser_download_url':
          'https://github.com/navnit/gapless-app/releases/download/v0.2.0/Gapless-0.2.0-macos-arm64-UNNOTARIZED.dmg',
    },
    {
      'name': 'Gapless-0.2.0-macos-x64-UNNOTARIZED.dmg',
      'browser_download_url':
          'https://github.com/navnit/gapless-app/releases/download/v0.2.0/Gapless-0.2.0-macos-x64-UNNOTARIZED.dmg',
    },
  ],
});

void main() {
  test('parses latest release and selects arch-matching dmg', () async {
    final checker = GithubUpdateChecker(
      client: MockClient((_) async => http.Response(_payload(), 200)),
      archToken: 'arm64',
    );
    final release = await checker.fetchLatest();
    expect(release.version.toString(), '0.2.0');
    expect(release.notes, 'Release notes');
    expect(release.dmgAssetUrl, contains('macos-arm64'));
  });

  test('maps 403 and 429 to rateLimited', () async {
    for (final code in [403, 429]) {
      final checker = GithubUpdateChecker(
        client: MockClient((_) async => http.Response('', code)),
        archToken: 'arm64',
      );
      expect(
        () => checker.fetchLatest(),
        throwsA(
          isA<UpdateCheckException>().having(
            (e) => e.reason,
            'reason',
            CheckFailureReason.rateLimited,
          ),
        ),
      );
    }
  });

  test('maps other errors to network', () async {
    final checker = GithubUpdateChecker(
      client: MockClient((_) async => http.Response('nope', 500)),
      archToken: 'arm64',
    );
    expect(
      () => checker.fetchLatest(),
      throwsA(
        isA<UpdateCheckException>().having(
          (e) => e.reason,
          'reason',
          CheckFailureReason.network,
        ),
      ),
    );
  });

  test('caps overly long release notes', () async {
    final body = 'x' * 50000;
    final checker = GithubUpdateChecker(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'tag_name': 'v0.2.0',
            'html_url': 'https://github.com/x',
            'body': body,
            'assets': [],
          }),
          200,
        ),
      ),
      archToken: 'arm64',
      notesLimit: 20000,
    );
    expect((await checker.fetchLatest()).notes.length, 20000);
  });
}
