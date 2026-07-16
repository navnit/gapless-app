import 'package:flutter/widgets.dart';
import 'package:gapless/app/app_dependencies.dart';
import 'package:gapless/app/gapless_app.dart';
import 'package:media_kit/media_kit.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final dependencies = await AppDependencies.production();
  runApp(GaplessApp(dependencies: dependencies));
}
