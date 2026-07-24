import 'dart:async';

import 'package:flutter/material.dart';
import 'package:gapless/app/app_dependencies.dart';
import 'package:gapless/features/editor/presentation/editor_screen.dart';
import 'package:gapless/features/editor/presentation/editor_view_model.dart';
import 'package:gapless/features/export/application/export_coordinator.dart';
import 'package:gapless/features/export/presentation/export_dialog.dart';
import 'package:gapless/features/update/application/update_coordinator.dart';
import 'package:gapless/features/update/domain/update_status.dart';
import 'package:gapless/features/update/presentation/update_banner.dart';
import 'package:gapless/features/update/presentation/update_dialog.dart';
import 'package:gapless/features/update/presentation/update_menu.dart';

final class GaplessApp extends StatefulWidget {
  const GaplessApp({required this.dependencies, super.key});

  final AppDependencies dependencies;

  @override
  State<GaplessApp> createState() => _GaplessAppState();
}

final class _GaplessAppState extends State<GaplessApp> {
  late final EditorViewModel _editor = widget.dependencies
      .createEditorViewModel();
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  StreamSubscription<AppExportDialogRequest>? _exportRequests;
  UpdateAvailable? _availableUpdate;

  @override
  void initState() {
    super.initState();
    final services = widget.dependencies.exportDialogs;
    if (services != null) {
      _exportRequests = services.host.requests.listen(
        (request) => unawaited(_showExportDialog(services, request)),
      );
    }
    final updateServices = widget.dependencies.update;
    if (updateServices != null) {
      unawaited(_runLaunchCheck(updateServices.coordinator));
    }
  }

  @override
  void dispose() {
    unawaited(_exportRequests?.cancel());
    _editor.dispose();
    super.dispose();
  }

  Future<void> _showExportDialog(
    AppExportDialogServices services,
    AppExportDialogRequest pending,
  ) async {
    final coordinator = ExportCoordinator(engine: services.engine);
    try {
      final dialogContext = _navigatorKey.currentContext;
      if (!mounted || dialogContext == null) return;
      await showDialog<void>(
        context: dialogContext,
        barrierDismissible: false,
        builder: (_) => ExportDialog(
          coordinator: coordinator,
          source: pending.request.source,
          metadata: pending.request.metadata,
          timeline: pending.request.timeline,
          destinationPicker: services.destinationPicker,
          revealInFolder: services.revealInFolder,
        ),
      );
    } finally {
      await coordinator.dispose();
      pending.finish();
    }
  }

  Future<void> _runLaunchCheck(UpdateCoordinator coordinator) async {
    final result = await coordinator.checkOnLaunch();
    if (!mounted) return;
    setState(() => _availableUpdate = result);
  }

  Future<void> _runManualCheck() async {
    final services = widget.dependencies.update;
    if (services == null) return;
    final result = await services.coordinator.checkManually();
    if (!mounted) return;
    switch (result) {
      case UpdateAvailable():
        await _showUpdateDialog(result);
      case UpToDate():
        final context = _navigatorKey.currentContext;
        if (context == null || !context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Gapless ${services.coordinator.currentVersion} is the latest version.',
            ),
          ),
        );
      case CheckFailed(reason: CheckFailureReason.rateLimited):
        final context = _navigatorKey.currentContext;
        if (context == null || !context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('GitHub rate limit — try again later.')),
        );
      case CheckFailed(reason: CheckFailureReason.network):
        final context = _navigatorKey.currentContext;
        if (context == null || !context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              "Couldn't check for updates. Check your connection and try again.",
            ),
          ),
        );
    }
  }

  Future<void> _showUpdateDialog(UpdateAvailable status) async {
    final services = widget.dependencies.update;
    final context = _navigatorKey.currentContext;
    if (services == null || context == null) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => UpdateDialog(
        status: status,
        onSkip: () {
          unawaited(
            services.coordinator.skipVersion(status.release.version.toString()),
          );
          Navigator.pop(ctx);
          setState(() => _availableUpdate = null);
        },
        onClose: () => Navigator.pop(ctx),
      ),
    );
  }

  void _dismissBanner() => setState(() => _availableUpdate = null);

  void _skipFromBanner() {
    final services = widget.dependencies.update;
    final update = _availableUpdate;
    if (services != null && update != null) {
      unawaited(
        services.coordinator.skipVersion(update.release.version.toString()),
      );
    }
    setState(() => _availableUpdate = null);
  }

  Widget _shell(Widget home) {
    final withBanner = Stack(
      children: [
        Positioned.fill(child: home),
        if (_availableUpdate case final update?)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: UpdateBanner(
                status: update,
                onView: () => _showUpdateDialog(update),
                onSkip: _skipFromBanner,
                onDismiss: _dismissBanner,
              ),
            ),
          ),
      ],
    );
    final services = widget.dependencies.update;
    if (services == null) return withBanner;
    return PlatformMenuBar(
      menus: buildAppMenus(onCheckForUpdates: _runManualCheck),
      child: withBanner,
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Gapless',
    navigatorKey: _navigatorKey,
    debugShowCheckedModeBanner: false,
    themeMode: ThemeMode.system,
    theme: _gaplessTheme(Brightness.light),
    darkTheme: _gaplessTheme(Brightness.dark),
    home: _shell(
      EditorScreen(
        viewModel: _editor,
        videoController: widget.dependencies.videoController,
      ),
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
