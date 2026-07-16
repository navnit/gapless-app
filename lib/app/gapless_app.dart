import 'package:flutter/material.dart';
import 'package:gapless/app/app_dependencies.dart';
import 'package:gapless/features/editor/presentation/editor_screen.dart';
import 'package:gapless/features/editor/presentation/editor_view_model.dart';

final class GaplessApp extends StatefulWidget {
  const GaplessApp({required this.dependencies, super.key});

  final AppDependencies dependencies;

  @override
  State<GaplessApp> createState() => _GaplessAppState();
}

final class _GaplessAppState extends State<GaplessApp> {
  late final EditorViewModel _editor = widget.dependencies
      .createEditorViewModel();

  @override
  void dispose() {
    _editor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Gapless',
    debugShowCheckedModeBanner: false,
    themeMode: ThemeMode.system,
    theme: _gaplessTheme(Brightness.light),
    darkTheme: _gaplessTheme(Brightness.dark),
    home: EditorScreen(
      viewModel: _editor,
      videoController: widget.dependencies.videoController,
    ),
  );
}

ThemeData _gaplessTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  const accent = Color(0xFFE3A63B);
  final background = dark ? const Color(0xFF121316) : const Color(0xFFE6E7E9);
  final panel = dark ? const Color(0xFF1A1C20) : const Color(0xFFF5F5F6);
  final raised = dark ? const Color(0xFF24262C) : Colors.white;
  final border = dark ? const Color(0xFF2A2D34) : const Color(0xFFD8DADD);
  final scheme =
      ColorScheme.fromSeed(
        seedColor: accent,
        brightness: brightness,
        surface: panel,
      ).copyWith(
        primary: accent,
        onPrimary: const Color(0xFF211903),
        surface: panel,
        surfaceContainer: raised,
        outlineVariant: border,
      );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: 'InstrumentSans',
    scaffoldBackgroundColor: background,
    dividerColor: border,
    canvasColor: panel,
    sliderTheme: const SliderThemeData(
      activeTrackColor: accent,
      thumbColor: accent,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: const Color(0xFF211903),
        minimumSize: const Size(36, 32),
      ),
    ),
    visualDensity: VisualDensity.compact,
  );
}
