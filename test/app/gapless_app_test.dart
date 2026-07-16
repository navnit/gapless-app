import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/app/app_dependencies.dart';
import 'package:gapless/app/gapless_app.dart';
import 'package:gapless/features/editor/presentation/editor_screen.dart';
import 'package:gapless/features/editor/presentation/editor_view_model.dart';

void main() {
  testWidgets('shows the Gapless empty workspace', (tester) async {
    await tester.pumpWidget(GaplessApp(dependencies: AppDependencies.empty()));

    expect(find.text('Gapless'), findsOneWidget);
    expect(find.text('Open Video'), findsOneWidget);
    expect(find.text('Drop a video here'), findsOneWidget);
  });

  testWidgets('uses the injected editor and approved light theme tokens', (
    tester,
  ) async {
    var created = 0;
    await tester.pumpWidget(
      GaplessApp(
        dependencies: AppDependencies(
          editorViewModelFactory: () {
            created += 1;
            return EditorViewModel.empty();
          },
        ),
      ),
    );

    final context = tester.element(find.byType(EditorScreen));
    final theme = Theme.of(context);
    expect(created, 1);
    expect(theme.textTheme.bodyMedium?.fontFamily, 'InstrumentSans');
    expect(theme.scaffoldBackgroundColor, const Color(0xFFE6E7E9));
    expect(theme.colorScheme.primary, const Color(0xFFE3A63B));
  });
}
