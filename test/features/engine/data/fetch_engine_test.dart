import 'package:flutter_test/flutter_test.dart';

import '../../../../tool/engine/fetch_engine.dart';

void main() {
  final configured = Uri.parse(
    'https://github.com/WyattBlue/auto-editor/releases/download/31.2.0/'
    'auto-editor-macos-arm64',
  );

  test('redirect policy requires the exact configured initial URL', () {
    expect(
      () => EngineRedirectPolicy.validateInitial(configured, configured),
      returnsNormally,
    );
    for (final invalid in [
      configured.replace(path: '${configured.path}-other'),
      configured.replace(scheme: 'http'),
      configured.replace(userInfo: 'user:secret'),
      configured.replace(port: 444),
    ]) {
      expect(
        () => EngineRedirectPolicy.validateInitial(configured, invalid),
        throwsFormatException,
      );
    }
  });

  test(
    'redirect policy allows same-host and the observed release CDN only',
    () {
      final policy = EngineRedirectPolicy(configuredUrl: configured);
      final sameHost = policy.follow(
        currentUrl: configured,
        location: '/WyattBlue/auto-editor/releases/download/31.2.0/asset',
        redirectCount: 0,
        visited: {configured},
        headers: const {'Accept': 'application/octet-stream'},
      );
      expect(sameHost.url.host, 'github.com');

      final cdn = policy.follow(
        currentUrl: sameHost.url,
        location:
            'https://release-assets.githubusercontent.com/object?token=opaque',
        redirectCount: 1,
        visited: {configured, sameHost.url},
        headers: const {'Accept': 'application/octet-stream'},
      );
      expect(cdn.url.host, 'release-assets.githubusercontent.com');

      final cdnHop = policy.follow(
        currentUrl: cdn.url,
        location: '/object-2?token=opaque',
        redirectCount: 2,
        visited: {configured, sameHost.url, cdn.url},
        headers: const {'Accept': 'application/octet-stream'},
      );
      expect(cdnHop.url.host, 'release-assets.githubusercontent.com');
    },
  );

  test('redirect policy rejects arbitrary hosts and unsafe URLs', () {
    final policy = EngineRedirectPolicy(configuredUrl: configured);
    for (final location in [
      'https://example.com/asset',
      'http://release-assets.githubusercontent.com/asset',
      'https://user:secret@release-assets.githubusercontent.com/asset',
      'https://release-assets.githubusercontent.com:444/asset',
    ]) {
      expect(
        () => policy.follow(
          currentUrl: configured,
          location: location,
          redirectCount: 0,
          visited: {configured},
          headers: const {},
        ),
        throwsFormatException,
        reason: location,
      );
    }
  });

  test('redirect policy rejects loops and excessive hops', () {
    final policy = EngineRedirectPolicy(
      configuredUrl: configured,
      maxRedirects: 2,
    );
    expect(
      () => policy.follow(
        currentUrl: configured,
        location: configured.toString(),
        redirectCount: 0,
        visited: {configured},
        headers: const {},
      ),
      throwsFormatException,
    );
    expect(
      () => policy.follow(
        currentUrl: configured,
        location: 'https://release-assets.githubusercontent.com/object',
        redirectCount: 2,
        visited: {configured},
        headers: const {},
      ),
      throwsFormatException,
    );
  });

  test('cross-host redirect strips credential-bearing headers', () {
    final policy = EngineRedirectPolicy(configuredUrl: configured);
    final headers = {
      'Authorization': 'Bearer secret',
      'Cookie': 'session=secret',
      'Proxy-Authorization': 'proxy secret',
      'Accept': 'application/octet-stream',
    };

    final sameHost = policy.follow(
      currentUrl: configured,
      location: '/same-host',
      redirectCount: 0,
      visited: {configured},
      headers: headers,
    );
    expect(sameHost.headers, headers);

    final crossHost = policy.follow(
      currentUrl: configured,
      location: 'https://release-assets.githubusercontent.com/object',
      redirectCount: 0,
      visited: {configured},
      headers: headers,
    );
    expect(crossHost.headers, {'Accept': 'application/octet-stream'});
  });
}
