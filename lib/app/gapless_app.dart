import 'package:flutter/material.dart';
import 'package:gapless/app/app_dependencies.dart';

final class GaplessApp extends StatelessWidget {
  const GaplessApp({required this.dependencies, super.key});

  final AppDependencies dependencies;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Gapless',
    debugShowCheckedModeBanner: false,
    themeMode: ThemeMode.system,
    home: const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Gapless'),
            Text('Drop a video here'),
            Text('Open Video'),
          ],
        ),
      ),
    ),
  );
}
