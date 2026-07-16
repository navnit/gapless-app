import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gapless/core/errors/app_failure.dart';
import 'package:gapless/core/process/process_runner.dart';
import 'package:gapless/features/engine/data/auto_editor/auto_editor_locator.dart';
import 'package:path/path.dart' as p;

const _maxDownloadBytes = 128 * 1024 * 1024;
const _releaseAssetHost = 'release-assets.githubusercontent.com';

final class RedirectDecision {
  RedirectDecision({required this.url, required Map<String, String> headers})
    : headers = Map.unmodifiable(headers);

  final Uri url;
  final Map<String, String> headers;
}

/// Pure redirect validation for the four pinned GitHub release URLs.
final class EngineRedirectPolicy {
  EngineRedirectPolicy({required this.configuredUrl, this.maxRedirects = 5}) {
    validateInitial(configuredUrl, configuredUrl);
    if (maxRedirects <= 0) {
      throw ArgumentError.value(maxRedirects, 'maxRedirects');
    }
  }

  final Uri configuredUrl;
  final int maxRedirects;

  static void validateInitial(Uri configured, Uri requested) {
    _validateHttpsUri(requested);
    if (configured != requested ||
        requested.host != 'github.com' ||
        requested.hasQuery ||
        requested.hasFragment ||
        !requested.path.startsWith(
          '/WyattBlue/auto-editor/releases/download/31.2.0/',
        )) {
      throw const FormatException('Initial engine URL must match the manifest');
    }
  }

  RedirectDecision follow({
    required Uri currentUrl,
    required String location,
    required int redirectCount,
    required Set<Uri> visited,
    required Map<String, String> headers,
  }) {
    if (redirectCount < 0 || redirectCount >= maxRedirects) {
      throw const FormatException('Too many engine redirects');
    }
    final next = currentUrl.resolve(location);
    _validateHttpsUri(next);
    final allowed = switch (currentUrl.host) {
      'github.com' =>
        next.host == 'github.com' || next.host == _releaseAssetHost,
      _releaseAssetHost => next.host == _releaseAssetHost,
      _ => false,
    };
    if (!allowed || next.path.isEmpty) {
      throw const FormatException('Unapproved engine redirect host');
    }
    if (visited.contains(next)) {
      throw const FormatException('Engine redirect loop');
    }
    final nextHeaders = Map<String, String>.from(headers);
    if (next.host != currentUrl.host) {
      nextHeaders.removeWhere((name, _) {
        final normalized = name.toLowerCase();
        return normalized == 'authorization' ||
            normalized == 'proxy-authorization' ||
            normalized == 'cookie';
      });
    }
    return RedirectDecision(url: next, headers: nextHeaders);
  }
}

Future<void> main(List<String> arguments) async {
  final options = _FetchOptions.parse(arguments);
  final root = Directory.current.absolute.path;
  final manifestPath = p.join(root, 'assets', 'engine', 'manifest.json');
  final installRoot = p.join(root, 'assets', 'engine');
  final manifest = AutoEditorManifest.parse(
    await File(manifestPath).readAsString(),
  );
  final targetName = options.target ?? currentAutoEditorTarget();
  final target = manifest.targets[targetName];
  if (target == null) throw ArgumentError.value(targetName, 'target');
  final runner = _ToolProcessRunner();
  final locator = AutoEditorLocator(
    manifestPath: manifestPath,
    installRoot: installRoot,
    processRunner: runner,
    target: targetName,
  );

  if (options.verifyOnly) {
    final path = await locator.verifyTarget(target);
    stdout.writeln('Verified Auto-Editor $autoEditorPinnedVersion: $path');
    return;
  }

  final targetDirectory = Directory(p.join(installRoot, targetName));
  await targetDirectory.create(recursive: true);
  try {
    final existing = await locator.verifyTarget(target);
    stdout.writeln(
      'Already verified Auto-Editor $autoEditorPinnedVersion: $existing',
    );
    return;
  } on EngineMissingFailure {
    // Explicit fetch repairs missing installations.
  } on EngineChecksumFailure {
    // Explicit fetch repairs checksum-mismatched installations.
  } on EngineContractFailure {
    // Explicit fetch repairs version-mismatched installations.
  }

  final temporaryDirectory = await targetDirectory.createTemp('.fetch-');
  final temporary = File(p.join(temporaryDirectory.path, target.installedFile));
  try {
    await _download(target, temporary);
    final actual = await hashFileSha256(temporary);
    if (actual != target.sha256) {
      throw EngineChecksumFailure(
        expectedSha256: target.sha256,
        actualSha256: actual,
      );
    }
    if (!Platform.isWindows) {
      final chmod = await Process.run('/bin/chmod', ['755', temporary.path]);
      if (chmod.exitCode != 0) {
        throw FileSystemException(
          'Unable to set executable permission',
          temporary.path,
        );
      }
    }
    await _verifyVersion(temporary.path);
    final destination = File(
      p.join(targetDirectory.path, target.installedFile),
    );
    await temporary.rename(destination.path);
    stdout.writeln(
      'Installed Auto-Editor $autoEditorPinnedVersion: ${destination.path}',
    );
  } finally {
    if (await temporary.exists()) await temporary.delete();
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  }
}

Future<void> _download(AutoEditorTarget target, File destination) async {
  EngineRedirectPolicy.validateInitial(target.url, target.url);
  final policy = EngineRedirectPolicy(configuredUrl: target.url);
  final client = HttpClient()..autoUncompress = false;
  var current = target.url;
  var headers = const <String, String>{
    HttpHeaders.acceptHeader: 'application/octet-stream',
  };
  final visited = <Uri>{current};
  var redirects = 0;
  try {
    while (true) {
      final request = await client.getUrl(current);
      request.followRedirects = false;
      request.maxRedirects = 0;
      headers.forEach(request.headers.set);
      final response = await request.close();
      if (_isRedirect(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>();
        if (location == null) {
          throw const FormatException('Redirect omitted Location');
        }
        final decision = policy.follow(
          currentUrl: current,
          location: location,
          redirectCount: redirects,
          visited: visited,
          headers: headers,
        );
        redirects++;
        current = decision.url;
        headers = decision.headers;
        visited.add(current);
        continue;
      }
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException(
          'Unexpected engine download status ${response.statusCode}',
          uri: current,
        );
      }
      final declaredLength = response.contentLength;
      if (declaredLength > _maxDownloadBytes) {
        await response.drain<void>();
        throw const FormatException('Engine download exceeds size limit');
      }
      final output = await destination.open(mode: FileMode.writeOnly);
      var received = 0;
      try {
        await for (final chunk in response) {
          received += chunk.length;
          if (received > _maxDownloadBytes) {
            throw const FormatException('Engine download exceeds size limit');
          }
          await output.writeFrom(chunk);
        }
        await output.flush();
      } finally {
        await output.close();
      }
      return;
    }
  } finally {
    client.close(force: true);
  }
}

Future<void> _verifyVersion(String executable) async {
  final result = await Process.run(executable, const ['--version']);
  final stdoutText = result.stdout.toString();
  final stderrText = result.stderr.toString();
  if (result.exitCode != 0 || stdoutText.trim() != autoEditorPinnedVersion) {
    throw EngineContractFailure(
      operation: 'fetch-engine',
      reason: result.exitCode == 0
          ? EngineContractReason.unsupportedVersion
          : EngineContractReason.unexpectedExit,
      exitCode: result.exitCode,
      diagnostics: [_bounded('$stderrText$stdoutText')],
    );
  }
}

void _validateHttpsUri(Uri uri) {
  if (uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasPort ||
      uri.hasFragment) {
    throw const FormatException('Unsafe engine URL');
  }
}

bool _isRedirect(int status) =>
    status == HttpStatus.movedPermanently ||
    status == HttpStatus.found ||
    status == HttpStatus.seeOther ||
    status == HttpStatus.temporaryRedirect ||
    status == HttpStatus.permanentRedirect;

String _bounded(String value) {
  final singleLine = value.replaceAll(RegExp(r'[\r\n]+'), ' ');
  return singleLine.length <= 1024 ? singleLine : singleLine.substring(0, 1024);
}

final class _FetchOptions {
  const _FetchOptions({required this.verifyOnly, required this.target});

  factory _FetchOptions.parse(List<String> arguments) {
    var verifyOnly = false;
    String? target;
    for (var index = 0; index < arguments.length; index++) {
      switch (arguments[index]) {
        case '--verify-only':
          verifyOnly = true;
        case '--target':
          if (index + 1 == arguments.length) {
            throw const FormatException('--target requires a value');
          }
          target = arguments[++index];
        default:
          throw FormatException('Unknown argument: ${arguments[index]}');
      }
    }
    return _FetchOptions(verifyOnly: verifyOnly, target: target);
  }

  final bool verifyOnly;
  final String? target;
}

final class _ToolProcessRunner implements ProcessRunner {
  @override
  Future<RunningProcess> start(ProcessRequest request) async {
    final process = await Process.start(
      request.executable,
      request.arguments,
      workingDirectory: request.workingDirectory,
      environment: request.environment.isEmpty ? null : request.environment,
      runInShell: false,
    );
    return _ToolRunningProcess(process);
  }
}

final class _ToolRunningProcess implements RunningProcess {
  const _ToolRunningProcess(this.process);

  final Process process;

  @override
  int get pid => process.pid;

  @override
  Stream<String> get stdoutLines =>
      process.stdout.transform(utf8.decoder).transform(const LineSplitter());

  @override
  Stream<String> get stderrLines =>
      process.stderr.transform(utf8.decoder).transform(const LineSplitter());

  @override
  Future<int> get exitCode => process.exitCode;

  @override
  Future<void> cancel() async {
    process.kill();
    await process.exitCode;
  }
}
