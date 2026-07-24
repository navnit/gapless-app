import 'dart:io';

const String kBrewUpgradeCommand = 'brew upgrade --cask gapless';

const _allowedHosts = {'github.com', 'objects.githubusercontent.com'};

bool isAllowedUpdateUrl(String url) {
  final parsed = Uri.tryParse(url);
  if (parsed == null) return false;
  return parsed.scheme == 'https' && _allowedHosts.contains(parsed.host);
}

Future<void> openExternalUrl(
  String url, {
  Future<void> Function(String, List<String>) run = _defaultRun,
}) async {
  if (!isAllowedUpdateUrl(url)) return;
  await run('open', [url]);
}

Future<void> _defaultRun(String executable, List<String> arguments) async {
  await Process.run(executable, arguments);
}
