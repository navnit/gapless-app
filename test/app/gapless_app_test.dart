import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/app/app_dependencies.dart';
import 'package:gapless/app/gapless_app.dart';

void main() {
  testWidgets('shows the Gapless empty workspace', (tester) async {
    await tester.pumpWidget(GaplessApp(dependencies: AppDependencies.empty()));

    expect(find.text('Gapless'), findsOneWidget);
    expect(find.text('Open Video'), findsOneWidget);
    expect(find.text('Drop a video here'), findsOneWidget);
  });
}
