import 'dart:convert';

import 'package:gapless/features/update/domain/app_version.dart';
import 'package:gapless/features/update/domain/release_info.dart';
import 'package:gapless/features/update/domain/update_checker_port.dart';
import 'package:gapless/features/update/domain/update_status.dart';
import 'package:http/http.dart' as http;

final class GithubUpdateChecker implements UpdateCheckerPort {
  GithubUpdateChecker({
    required this.client,
    required this.archToken,
    Uri? endpoint,
    this.timeout = const Duration(seconds: 5),
    this.notesLimit = 20000,
  }) : endpoint =
           endpoint ??
           Uri.parse(
             'https://api.github.com/repos/navnit/gapless-app/releases/latest',
           );

  final http.Client client;
  final String archToken;
  final Uri endpoint;
  final Duration timeout;
  final int notesLimit;

  @override
  Future<ReleaseInfo> fetchLatest() async {
    final http.Response response;
    try {
      response = await client
          .get(
            endpoint,
            headers: const {'Accept': 'application/vnd.github+json'},
          )
          .timeout(timeout);
    } on Object {
      throw const UpdateCheckException(CheckFailureReason.network);
    }

    if (response.statusCode == 403 || response.statusCode == 429) {
      throw const UpdateCheckException(CheckFailureReason.rateLimited);
    }
    if (response.statusCode != 200) {
      throw const UpdateCheckException(CheckFailureReason.network);
    }

    try {
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final version = AppVersion.tryParse(json['tag_name'] as String);
      final htmlUrl = json['html_url'] as String;
      if (version == null) {
        throw const UpdateCheckException(CheckFailureReason.network);
      }
      final notes = (json['body'] as String?) ?? '';
      final capped = notes.length > notesLimit
          ? notes.substring(0, notesLimit)
          : notes;
      final assets = (json['assets'] as List<dynamic>?) ?? const <dynamic>[];
      String? dmg;
      for (final entry in assets) {
        final asset = entry as Map<String, dynamic>;
        final name = (asset['name'] as String?) ?? '';
        if (name.contains('-macos-$archToken-') && name.endsWith('.dmg')) {
          dmg = asset['browser_download_url'] as String?;
          break;
        }
      }
      return ReleaseInfo(
        version: version,
        notes: capped,
        htmlUrl: htmlUrl,
        dmgAssetUrl: dmg,
      );
    } on UpdateCheckException {
      rethrow;
    } on Object {
      throw const UpdateCheckException(CheckFailureReason.network);
    }
  }
}
