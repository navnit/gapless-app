import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:gapless/app/app_dependencies.dart';
import 'package:gapless/app/gapless_app.dart';
import 'package:gapless/app/installed_smoke_test.dart';
import 'package:media_kit/media_kit.dart';

Future<void> main(List<String> arguments) async {
  if (arguments case ['--smoke-test', final source, final output]) {
    try {
      await runInstalledSmokeTest(
        absoluteSmokeTestFileUri(source),
        absoluteSmokeTestFileUri(output),
      );
      stdout.writeln('Installed artifact smoke test passed.');
      await stdout.flush();
      exit(0);
    } on Object catch (error) {
      stderr.writeln('Installed artifact smoke test failed: $error');
      await stderr.flush();
      exit(1);
    }
  }
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final dependencies = await AppDependencies.production();
  runApp(GaplessApp(dependencies: dependencies));
}
