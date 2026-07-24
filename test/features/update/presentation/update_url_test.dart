import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/features/update/presentation/update_url.dart';

void main() {
  test('allows only https github hosts', () {
    expect(
      isAllowedUpdateUrl('https://github.com/navnit/gapless-app/releases'),
      isTrue,
    );
    expect(
      isAllowedUpdateUrl('https://objects.githubusercontent.com/x.dmg'),
      isTrue,
    );
    expect(isAllowedUpdateUrl('http://github.com/x'), isFalse);
    expect(isAllowedUpdateUrl('https://evil.example.com/x'), isFalse);
    expect(isAllowedUpdateUrl('file:///etc/passwd'), isFalse);
    expect(isAllowedUpdateUrl('not a url'), isFalse);
  });

  test('openExternalUrl runs open only for allowed urls', () async {
    final calls = <List<String>>[];
    Future<void> fakeRun(String cmd, List<String> args) async =>
        calls.add([cmd, ...args]);

    await openExternalUrl('https://github.com/x', run: fakeRun);
    await openExternalUrl('file:///etc/passwd', run: fakeRun);

    expect(calls, [
      ['open', 'https://github.com/x'],
    ]);
  });
}
