import 'dart:io';

final class ReleaseVersion {
  const ReleaseVersion({required this.name, required this.buildNumber});

  final String name;
  final int buildNumber;

  static final _pubspecPattern = RegExp(
    r'^version:[ \t]*((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))\+([1-9][0-9]*)[ \t]*\r?$',
    multiLine: true,
  );

  factory ReleaseVersion.parsePubspec(String source) {
    final matches = _pubspecPattern.allMatches(source).toList();
    if (matches.length != 1) {
      throw const FormatException(
        'pubspec.yaml must contain exactly one '
        'version: MAJOR.MINOR.PATCH+BUILD line.',
      );
    }
    return ReleaseVersion(
      name: matches.single.group(1)!,
      buildNumber: int.parse(matches.single.group(2)!),
    );
  }

  void requireReleaseName(String supplied) {
    if (supplied != name) {
      throw FormatException(
        'Release version $supplied does not match pubspec version $name.',
      );
    }
  }
}

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2 || arguments.first != '--release-version') {
    stderr.writeln(
      'Usage: dart run tool/release/validate_release_version.dart '
      '--release-version MAJOR.MINOR.PATCH',
    );
    exitCode = 64;
    return;
  }
  try {
    final version = ReleaseVersion.parsePubspec(
      await File('pubspec.yaml').readAsString(),
    );
    version.requireReleaseName(arguments[1]);
    stdout.writeln('Validated Gapless ${version.name}+${version.buildNumber}.');
  } on FormatException catch (error) {
    stderr.writeln('error: ${error.message}');
    exitCode = 1;
  }
}
