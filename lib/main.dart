import 'package:flutter/widgets.dart';
import 'package:gapless/app/app_dependencies.dart';
import 'package:gapless/app/gapless_app.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  MediaKit.ensureInitialized();
  runApp(const GaplessApp(dependencies: AppDependencies.empty()));
}
