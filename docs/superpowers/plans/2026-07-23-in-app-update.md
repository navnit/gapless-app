# In-App Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement task-by-task. Steps use `- [ ]` checkboxes for tracking.

**Goal:** Add an in-app "notify + hand-off" update feature to Gapless: a throttled background check on launch plus a manual "Check for Updates…" menu item, with Homebrew-vs-DMG channel detection driving the right install guidance.

**Architecture:** New `lib/features/update/` feature in the existing `domain / application / data / presentation` split. All network, filesystem, and preference access sits behind ports (matching `RecentProjectsPort`). A const `AppUpdateServices` on `AppDependencies` carries the coordinator + preferences; `GaplessApp` hosts a `PlatformMenuBar` and an overlay banner and kicks off the launch check — mirroring the existing `AppExportDialogHost` pattern.

**Tech Stack:** Flutter (Dart), `http` (with `MockClient` for tests), `package_info_plus`, `path` (already present), `path_provider` (already present). macOS-only runtime behavior.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-23-in-app-update-design.md`.
- Exactly **two** new deps: `http`, `package_info_plus`. No `pub_semver`, no `url_launcher`.
- Release API endpoint: `https://api.github.com/repos/navnit/gapless-app/releases/latest`.
- Brew command is the compile-time constant `brew upgrade --cask gapless` — never assembled from API data.
- URLs opened externally must be `https` with host ∈ {`github.com`, `objects.githubusercontent.com`}.
- DMG asset name tokens: `-macos-arm64-` / `-macos-x64-` (matched against `Abi.current()`).
- Launch check: gated by `autoCheckEnabled` (default `true`) and a 24 h throttle via `lastCheckedAt`. Launch failures are silent; manual failures are reported.
- Follow existing style: `final class`, `abstract interface class` for ports, atomic `schemaVersion`+`.tmp`+`rename` JSON stores.
- Every task ends green: `flutter analyze` clean and the task's tests pass before commit.

---

### Task 0: Dependencies and debug entitlement

**Files:**
- Modify: `pubspec.yaml` (dependencies)
- Modify: `macos/Runner/DebugProfile.entitlements`

- [ ] **Step 1: Add dependencies.** Under `dependencies:` in `pubspec.yaml`, add (keep alphabetical grouping consistent with neighbors):

```yaml
  http: ^1.2.2
  package_info_plus: ^8.0.0
```

- [ ] **Step 2: Resolve.** Run: `flutter pub get` — Expected: succeeds, `http` and `package_info_plus` appear in `pubspec.lock`.
- [ ] **Step 3: Add the debug network-client entitlement** so the check works under `flutter run` (Release is unsandboxed and needs no change). In `macos/Runner/DebugProfile.entitlements`, inside the top `<dict>`, add:

```xml
	<key>com.apple.security.network.client</key>
	<true/>
```

- [ ] **Step 4: Verify analyze.** Run: `flutter analyze` — Expected: No issues found.
- [ ] **Step 5: Commit.**

```bash
git add pubspec.yaml pubspec.lock macos/Runner/DebugProfile.entitlements
git commit -m "chore: add http + package_info_plus and debug network entitlement for update check"
```

---

### Task 1: AppVersion value type

**Files:**
- Create: `lib/features/update/domain/app_version.dart`
- Test: `test/features/update/domain/app_version_test.dart`

**Interfaces:**
- Produces: `final class AppVersion implements Comparable<AppVersion>` with `static AppVersion? tryParse(String)`, `bool isNewerThan(AppVersion)`, `String toString()` → `"0.1.1"`, value equality.

- [ ] **Step 1: Write failing test.**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/features/update/domain/app_version.dart';

void main() {
  test('parses plain and v-prefixed versions', () {
    expect(AppVersion.tryParse('0.1.1'), AppVersion.tryParse('v0.1.1'));
    expect(AppVersion.tryParse('0.1.1').toString(), '0.1.1');
  });

  test('compares numerically, not lexically', () {
    expect(AppVersion.tryParse('0.10.0')!.isNewerThan(AppVersion.tryParse('0.9.0')!), isTrue);
    expect(AppVersion.tryParse('1.0.0')!.isNewerThan(AppVersion.tryParse('0.99.99')!), isTrue);
    expect(AppVersion.tryParse('0.1.1')!.isNewerThan(AppVersion.tryParse('0.1.1')!), isFalse);
  });

  test('rejects suffixes, build metadata, and malformed input as null', () {
    for (final raw in ['0.2.0-rc1', '0.1.1+1', '1.2', '1.2.3.4', 'abc', '']) {
      expect(AppVersion.tryParse(raw), isNull, reason: raw);
    }
  });
}
```

- [ ] **Step 2: Run test, verify fails.** Run: `flutter test test/features/update/domain/app_version_test.dart` — Expected: FAIL (`app_version.dart` missing).
- [ ] **Step 3: Implement.**

```dart
final class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch);

  final int major;
  final int minor;
  final int patch;

  static AppVersion? tryParse(String raw) {
    var text = raw.trim();
    if (text.startsWith('v')) text = text.substring(1);
    final parts = text.split('.');
    if (parts.length != 3) return null;
    final numbers = parts.map(int.tryParse).toList();
    if (numbers.any((value) => value == null || value < 0)) return null;
    return AppVersion(numbers[0]!, numbers[1]!, numbers[2]!);
  }

  bool isNewerThan(AppVersion other) => compareTo(other) > 0;

  @override
  int compareTo(AppVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  @override
  bool operator ==(Object other) =>
      other is AppVersion && other.major == major && other.minor == minor && other.patch == patch;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() => '$major.$minor.$patch';
}
```

- [ ] **Step 4: Run test, verify passes.** Run: `flutter test test/features/update/domain/app_version_test.dart` — Expected: PASS.
- [ ] **Step 5: Commit.**

```bash
git add lib/features/update/domain/app_version.dart test/features/update/domain/app_version_test.dart
git commit -m "feat: add AppVersion semver value type with numeric compare"
```

---

### Task 2: Domain value types (channel, release, status, failure)

**Files:**
- Create: `lib/features/update/domain/install_channel.dart`
- Create: `lib/features/update/domain/release_info.dart`
- Create: `lib/features/update/domain/update_status.dart`
- Test: `test/features/update/domain/update_status_test.dart`

**Interfaces:**
- Produces:
  - `enum InstallChannel { homebrew, directDmg, unknown }`
  - `final class ReleaseInfo { AppVersion version; String notes; String htmlUrl; String? dmgAssetUrl; }`
  - `sealed class UpdateStatus`; subtypes `UpToDate`, `UpdateAvailable({ReleaseInfo release, InstallChannel channel, AppVersion current})`, `CheckFailed(CheckFailureReason reason)`
  - `enum CheckFailureReason { rateLimited, network }`

- [ ] **Step 1: Write failing test.**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/features/update/domain/app_version.dart';
import 'package:gapless/features/update/domain/install_channel.dart';
import 'package:gapless/features/update/domain/release_info.dart';
import 'package:gapless/features/update/domain/update_status.dart';

void main() {
  test('UpdateAvailable carries release, channel, and current version', () {
    final release = ReleaseInfo(
      version: AppVersion.tryParse('0.2.0')!,
      notes: 'notes',
      htmlUrl: 'https://github.com/navnit/gapless-app/releases/tag/v0.2.0',
    );
    final UpdateStatus status = UpdateAvailable(
      release: release,
      channel: InstallChannel.homebrew,
      current: AppVersion.tryParse('0.1.1')!,
    );
    expect(status, isA<UpdateAvailable>());
    expect((status as UpdateAvailable).channel, InstallChannel.homebrew);
    expect(status.release.dmgAssetUrl, isNull);
  });

  test('failure reasons are distinct', () {
    expect(const CheckFailed(CheckFailureReason.rateLimited).reason,
        isNot(const CheckFailed(CheckFailureReason.network).reason));
  });
}
```

- [ ] **Step 2: Run test, verify fails.** Run: `flutter test test/features/update/domain/update_status_test.dart` — Expected: FAIL (types missing).
- [ ] **Step 3: Implement the three files.**

`install_channel.dart`:

```dart
enum InstallChannel { homebrew, directDmg, unknown }
```

`release_info.dart`:

```dart
import 'package:gapless/features/update/domain/app_version.dart';

final class ReleaseInfo {
  const ReleaseInfo({
    required this.version,
    required this.notes,
    required this.htmlUrl,
    this.dmgAssetUrl,
  });

  final AppVersion version;
  final String notes;
  final String htmlUrl;
  final String? dmgAssetUrl;
}
```

`update_status.dart`:

```dart
import 'package:gapless/features/update/domain/app_version.dart';
import 'package:gapless/features/update/domain/install_channel.dart';
import 'package:gapless/features/update/domain/release_info.dart';

enum CheckFailureReason { rateLimited, network }

sealed class UpdateStatus {
  const UpdateStatus();
}

final class UpToDate extends UpdateStatus {
  const UpToDate();
}

final class UpdateAvailable extends UpdateStatus {
  const UpdateAvailable({
    required this.release,
    required this.channel,
    required this.current,
  });

  final ReleaseInfo release;
  final InstallChannel channel;
  final AppVersion current;
}

final class CheckFailed extends UpdateStatus {
  const CheckFailed(this.reason);

  final CheckFailureReason reason;
}
```

- [ ] **Step 4: Run test, verify passes.** Run: `flutter test test/features/update/domain/update_status_test.dart` — Expected: PASS.
- [ ] **Step 5: Commit.**

```bash
git add lib/features/update/domain/install_channel.dart lib/features/update/domain/release_info.dart lib/features/update/domain/update_status.dart test/features/update/domain/update_status_test.dart
git commit -m "feat: add update domain value types (channel, release, status)"
```

---

### Task 3: Domain ports and preferences data

**Files:**
- Create: `lib/features/update/domain/update_checker_port.dart`
- Create: `lib/features/update/domain/channel_detector_port.dart`
- Create: `lib/features/update/domain/update_preferences_port.dart`
- Test: `test/features/update/domain/update_preferences_data_test.dart`

**Interfaces:**
- Produces:
  - `abstract interface class UpdateCheckerPort { Future<ReleaseInfo> fetchLatest(); }`
  - `final class UpdateCheckException implements Exception { CheckFailureReason reason; }`
  - `abstract interface class ChannelDetectorPort { Future<InstallChannel> detect(); }`
  - `final class UpdatePreferencesData { bool autoCheckEnabled; String? skippedVersion; DateTime? lastCheckedAt; copyWith(...); }`
  - `abstract interface class UpdatePreferencesPort { Future<UpdatePreferencesData> load(); Future<void> save(UpdatePreferencesData); }`

- [ ] **Step 1: Write failing test** (only `UpdatePreferencesData` has behavior worth a unit test):

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/features/update/domain/update_preferences_port.dart';

void main() {
  test('defaults to auto-check on with no skip or timestamp', () {
    const data = UpdatePreferencesData();
    expect(data.autoCheckEnabled, isTrue);
    expect(data.skippedVersion, isNull);
    expect(data.lastCheckedAt, isNull);
  });

  test('copyWith replaces only named fields', () {
    final base = const UpdatePreferencesData();
    final updated = base.copyWith(skippedVersion: '0.2.0', autoCheckEnabled: false);
    expect(updated.skippedVersion, '0.2.0');
    expect(updated.autoCheckEnabled, isFalse);
    expect(updated.lastCheckedAt, isNull);
  });
}
```

- [ ] **Step 2: Run test, verify fails.** Run: `flutter test test/features/update/domain/update_preferences_data_test.dart` — Expected: FAIL.
- [ ] **Step 3: Implement the three port files.**

`update_checker_port.dart`:

```dart
import 'package:gapless/features/update/domain/release_info.dart';
import 'package:gapless/features/update/domain/update_status.dart';

abstract interface class UpdateCheckerPort {
  Future<ReleaseInfo> fetchLatest();
}

final class UpdateCheckException implements Exception {
  const UpdateCheckException(this.reason);

  final CheckFailureReason reason;
}
```

`channel_detector_port.dart`:

```dart
import 'package:gapless/features/update/domain/install_channel.dart';

abstract interface class ChannelDetectorPort {
  Future<InstallChannel> detect();
}
```

`update_preferences_port.dart`:

```dart
final class UpdatePreferencesData {
  const UpdatePreferencesData({
    this.autoCheckEnabled = true,
    this.skippedVersion,
    this.lastCheckedAt,
  });

  final bool autoCheckEnabled;
  final String? skippedVersion;
  final DateTime? lastCheckedAt;

  UpdatePreferencesData copyWith({
    bool? autoCheckEnabled,
    String? skippedVersion,
    DateTime? lastCheckedAt,
  }) =>
      UpdatePreferencesData(
        autoCheckEnabled: autoCheckEnabled ?? this.autoCheckEnabled,
        skippedVersion: skippedVersion ?? this.skippedVersion,
        lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
      );
}

abstract interface class UpdatePreferencesPort {
  Future<UpdatePreferencesData> load();
  Future<void> save(UpdatePreferencesData data);
}
```

> Note: `copyWith` cannot clear a field back to null (not needed — skip/toggle/timestamp only ever set values). Documented limitation.

- [ ] **Step 4: Run test, verify passes.** Run: `flutter test test/features/update/domain/update_preferences_data_test.dart` — Expected: PASS.
- [ ] **Step 5: Commit.**

```bash
git add lib/features/update/domain/update_checker_port.dart lib/features/update/domain/channel_detector_port.dart lib/features/update/domain/update_preferences_port.dart test/features/update/domain/update_preferences_data_test.dart
git commit -m "feat: add update ports and preferences data"
```

---

### Task 4: CaskroomChannelDetector

**Files:**
- Create: `lib/features/update/data/caskroom_channel_detector.dart`
- Test: `test/features/update/data/caskroom_channel_detector_test.dart`

**Interfaces:**
- Consumes: `ChannelDetectorPort`, `InstallChannel`.
- Produces: `final class CaskroomChannelDetector implements ChannelDetectorPort` constructed with `({required String resolvedExecutable, List<String> caskroomPrefixes})` (prefixes default `['/opt/homebrew', '/usr/local']`).

- [ ] **Step 1: Write failing test** (uses real temp dirs as prefixes — no brew install needed):

```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/features/update/domain/install_channel.dart';
import 'package:gapless/features/update/data/caskroom_channel_detector.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory prefix;
  setUp(() => prefix = Directory.systemTemp.createTempSync('cask_prefix'));
  tearDown(() => prefix.deleteSync(recursive: true));

  test('bundle running under a Caskroom path is homebrew', () async {
    final detector = CaskroomChannelDetector(
      resolvedExecutable: '/opt/homebrew/Caskroom/gapless/0.1.1/Gapless.app/Contents/MacOS/Gapless',
      caskroomPrefixes: const [],
    );
    expect(await detector.detect(), InstallChannel.homebrew);
  });

  test('receipt file present is homebrew', () async {
    final receipt = File(p.join(prefix.path, 'Caskroom', 'gapless', '.metadata', 'INSTALL_RECEIPT.json'));
    receipt.createSync(recursive: true);
    final detector = CaskroomChannelDetector(
      resolvedExecutable: '/Applications/Gapless.app/Contents/MacOS/Gapless',
      caskroomPrefixes: [prefix.path],
    );
    expect(await detector.detect(), InstallChannel.homebrew);
  });

  test('caskroom directory without receipt is homebrew', () async {
    Directory(p.join(prefix.path, 'Caskroom', 'gapless')).createSync(recursive: true);
    final detector = CaskroomChannelDetector(
      resolvedExecutable: '/Applications/Gapless.app/Contents/MacOS/Gapless',
      caskroomPrefixes: [prefix.path],
    );
    expect(await detector.detect(), InstallChannel.homebrew);
  });

  test('no caskroom signal is directDmg', () async {
    final detector = CaskroomChannelDetector(
      resolvedExecutable: '/Applications/Gapless.app/Contents/MacOS/Gapless',
      caskroomPrefixes: [prefix.path],
    );
    expect(await detector.detect(), InstallChannel.directDmg);
  });
}
```

- [ ] **Step 2: Run test, verify fails.** Run: `flutter test test/features/update/data/caskroom_channel_detector_test.dart` — Expected: FAIL.
- [ ] **Step 3: Implement.**

```dart
import 'dart:io';

import 'package:gapless/features/update/domain/channel_detector_port.dart';
import 'package:gapless/features/update/domain/install_channel.dart';
import 'package:path/path.dart' as p;

final class CaskroomChannelDetector implements ChannelDetectorPort {
  const CaskroomChannelDetector({
    required this.resolvedExecutable,
    this.caskroomPrefixes = const ['/opt/homebrew', '/usr/local'],
  });

  final String resolvedExecutable;
  final List<String> caskroomPrefixes;

  @override
  Future<InstallChannel> detect() async {
    try {
      if (resolvedExecutable.contains('/Caskroom/')) {
        return InstallChannel.homebrew;
      }
      for (final prefix in caskroomPrefixes) {
        final receipt = File(
          p.join(prefix, 'Caskroom', 'gapless', '.metadata', 'INSTALL_RECEIPT.json'),
        );
        final directory = Directory(p.join(prefix, 'Caskroom', 'gapless'));
        if (await receipt.exists() || await directory.exists()) {
          return InstallChannel.homebrew;
        }
      }
      return InstallChannel.directDmg;
    } on Object {
      return InstallChannel.unknown;
    }
  }
}
```

- [ ] **Step 4: Run test, verify passes.** Run: `flutter test test/features/update/data/caskroom_channel_detector_test.dart` — Expected: PASS.
- [ ] **Step 5: Commit.**

```bash
git add lib/features/update/data/caskroom_channel_detector.dart test/features/update/data/caskroom_channel_detector_test.dart
git commit -m "feat: detect homebrew vs dmg install channel via caskroom receipt"
```

---

### Task 5: GithubUpdateChecker

**Files:**
- Create: `lib/features/update/data/github_update_checker.dart`
- Test: `test/features/update/data/github_update_checker_test.dart`

**Interfaces:**
- Consumes: `UpdateCheckerPort`, `UpdateCheckException`, `ReleaseInfo`, `AppVersion`, `CheckFailureReason`.
- Produces: `final class GithubUpdateChecker implements UpdateCheckerPort` constructed with `({required http.Client client, required String archToken, Uri endpoint, Duration timeout, int notesLimit})`. Throws `UpdateCheckException(rateLimited)` on 403/429, `UpdateCheckException(network)` on other non-200/timeout/parse failures.

- [ ] **Step 1: Write failing test** (via `package:http/testing.dart` `MockClient`):

```dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:gapless/features/update/domain/update_status.dart';
import 'package:gapless/features/update/domain/update_checker_port.dart';
import 'package:gapless/features/update/data/github_update_checker.dart';

String _payload() => jsonEncode({
      'tag_name': 'v0.2.0',
      'html_url': 'https://github.com/navnit/gapless-app/releases/tag/v0.2.0',
      'body': 'Release notes',
      'assets': [
        {
          'name': 'Gapless-0.2.0-macos-arm64-UNNOTARIZED.dmg',
          'browser_download_url':
              'https://github.com/navnit/gapless-app/releases/download/v0.2.0/Gapless-0.2.0-macos-arm64-UNNOTARIZED.dmg',
        },
        {
          'name': 'Gapless-0.2.0-macos-x64-UNNOTARIZED.dmg',
          'browser_download_url':
              'https://github.com/navnit/gapless-app/releases/download/v0.2.0/Gapless-0.2.0-macos-x64-UNNOTARIZED.dmg',
        },
      ],
    });

void main() {
  test('parses latest release and selects arch-matching dmg', () async {
    final checker = GithubUpdateChecker(
      client: MockClient((_) async => http.Response(_payload(), 200)),
      archToken: 'arm64',
    );
    final release = await checker.fetchLatest();
    expect(release.version.toString(), '0.2.0');
    expect(release.notes, 'Release notes');
    expect(release.dmgAssetUrl, contains('macos-arm64'));
  });

  test('maps 403 and 429 to rateLimited', () async {
    for (final code in [403, 429]) {
      final checker = GithubUpdateChecker(
        client: MockClient((_) async => http.Response('', code)),
        archToken: 'arm64',
      );
      expect(
        () => checker.fetchLatest(),
        throwsA(isA<UpdateCheckException>()
            .having((e) => e.reason, 'reason', CheckFailureReason.rateLimited)),
      );
    }
  });

  test('maps other errors to network', () async {
    final checker = GithubUpdateChecker(
      client: MockClient((_) async => http.Response('nope', 500)),
      archToken: 'arm64',
    );
    expect(
      () => checker.fetchLatest(),
      throwsA(isA<UpdateCheckException>()
          .having((e) => e.reason, 'reason', CheckFailureReason.network)),
    );
  });

  test('caps overly long release notes', () async {
    final body = 'x' * 50000;
    final checker = GithubUpdateChecker(
      client: MockClient((_) async => http.Response(
          jsonEncode({'tag_name': 'v0.2.0', 'html_url': 'https://github.com/x', 'body': body, 'assets': []}),
          200)),
      archToken: 'arm64',
      notesLimit: 20000,
    );
    expect((await checker.fetchLatest()).notes.length, 20000);
  });
}
```

- [ ] **Step 2: Run test, verify fails.** Run: `flutter test test/features/update/data/github_update_checker_test.dart` — Expected: FAIL.
- [ ] **Step 3: Implement.**

```dart
import 'dart:convert';

import 'package:gapless/features/update/domain/app_version.dart';
import 'package:gapless/features/update/domain/release_info.dart';
import 'package:gapless/features/update/domain/update_checker_port.dart';
import 'package:gapless/features/update/domain/update_status.dart';
import 'package:http/http.dart' as http;

final class GithubUpdateChecker implements UpdateCheckerPort {
  GithubUpdateChecker({
    required this.client,
    required this.archToken,
    Uri? endpoint,
    this.timeout = const Duration(seconds: 5),
    this.notesLimit = 20000,
  }) : endpoint = endpoint ??
            Uri.parse('https://api.github.com/repos/navnit/gapless-app/releases/latest');

  final http.Client client;
  final String archToken;
  final Uri endpoint;
  final Duration timeout;
  final int notesLimit;

  @override
  Future<ReleaseInfo> fetchLatest() async {
    final http.Response response;
    try {
      response = await client
          .get(endpoint, headers: const {'Accept': 'application/vnd.github+json'})
          .timeout(timeout);
    } on Object {
      throw const UpdateCheckException(CheckFailureReason.network);
    }

    if (response.statusCode == 403 || response.statusCode == 429) {
      throw const UpdateCheckException(CheckFailureReason.rateLimited);
    }
    if (response.statusCode != 200) {
      throw const UpdateCheckException(CheckFailureReason.network);
    }

    try {
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final version = AppVersion.tryParse(json['tag_name'] as String);
      final htmlUrl = json['html_url'] as String;
      if (version == null) {
        throw const UpdateCheckException(CheckFailureReason.network);
      }
      final notes = (json['body'] as String?) ?? '';
      final capped = notes.length > notesLimit ? notes.substring(0, notesLimit) : notes;
      final assets = (json['assets'] as List<dynamic>?) ?? const <dynamic>[];
      String? dmg;
      for (final entry in assets) {
        final asset = entry as Map<String, dynamic>;
        final name = (asset['name'] as String?) ?? '';
        if (name.contains('-macos-$archToken-') && name.endsWith('.dmg')) {
          dmg = asset['browser_download_url'] as String?;
          break;
        }
      }
      return ReleaseInfo(version: version, notes: capped, htmlUrl: htmlUrl, dmgAssetUrl: dmg);
    } on UpdateCheckException {
      rethrow;
    } on Object {
      throw const UpdateCheckException(CheckFailureReason.network);
    }
  }
}
```

- [ ] **Step 4: Run test, verify passes.** Run: `flutter test test/features/update/data/github_update_checker_test.dart` — Expected: PASS.
- [ ] **Step 5: Commit.**

```bash
git add lib/features/update/data/github_update_checker.dart test/features/update/data/github_update_checker_test.dart
git commit -m "feat: fetch latest release from GitHub with arch-matched dmg and rate-limit mapping"
```

---

### Task 6: JsonUpdatePreferences store

**Files:**
- Create: `lib/features/update/data/json_update_preferences.dart`
- Test: `test/features/update/data/json_update_preferences_test.dart`

**Interfaces:**
- Consumes: `UpdatePreferencesPort`, `UpdatePreferencesData`.
- Produces: `final class JsonUpdatePreferences implements UpdatePreferencesPort` constructed with `(File file)`; `schemaVersion = 1`; atomic `.tmp`+`rename` write; unknown/mismatched schema loads defaults.

- [ ] **Step 1: Write failing test.**

```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/features/update/domain/update_preferences_port.dart';
import 'package:gapless/features/update/data/json_update_preferences.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('update_prefs'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('missing file loads defaults', () async {
    final store = JsonUpdatePreferences(File(p.join(dir.path, 'update.json')));
    final data = await store.load();
    expect(data.autoCheckEnabled, isTrue);
    expect(data.skippedVersion, isNull);
  });

  test('round-trips all fields', () async {
    final file = File(p.join(dir.path, 'update.json'));
    final store = JsonUpdatePreferences(file);
    final when = DateTime.fromMillisecondsSinceEpoch(1700000000000);
    await store.save(UpdatePreferencesData(
      autoCheckEnabled: false,
      skippedVersion: '0.2.0',
      lastCheckedAt: when,
    ));
    final loaded = await store.load();
    expect(loaded.autoCheckEnabled, isFalse);
    expect(loaded.skippedVersion, '0.2.0');
    expect(loaded.lastCheckedAt, when);
  });

  test('rejects wrong schema version as defaults', () async {
    final file = File(p.join(dir.path, 'update.json'));
    await file.writeAsString('{"schemaVersion":99,"autoCheckEnabled":false}');
    final data = await JsonUpdatePreferences(file).load();
    expect(data.autoCheckEnabled, isTrue);
  });
}
```

- [ ] **Step 2: Run test, verify fails.** Run: `flutter test test/features/update/data/json_update_preferences_test.dart` — Expected: FAIL.
- [ ] **Step 3: Implement** (mirrors `JsonRecentProjectsStore`):

```dart
import 'dart:convert';
import 'dart:io';

import 'package:gapless/features/update/domain/update_preferences_port.dart';

final class JsonUpdatePreferences implements UpdatePreferencesPort {
  const JsonUpdatePreferences(this.file);

  static const schemaVersion = 1;
  final File file;

  @override
  Future<UpdatePreferencesData> load() async {
    try {
      if (!await file.exists()) return const UpdatePreferencesData();
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic> || decoded['schemaVersion'] != schemaVersion) {
        return const UpdatePreferencesData();
      }
      final millis = decoded['lastCheckedAt'];
      return UpdatePreferencesData(
        autoCheckEnabled: decoded['autoCheckEnabled'] as bool? ?? true,
        skippedVersion: decoded['skippedVersion'] as String?,
        lastCheckedAt: millis is int ? DateTime.fromMillisecondsSinceEpoch(millis) : null,
      );
    } on Object {
      return const UpdatePreferencesData();
    }
  }

  @override
  Future<void> save(UpdatePreferencesData data) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      '${jsonEncode(<String, Object?>{
        'schemaVersion': schemaVersion,
        'autoCheckEnabled': data.autoCheckEnabled,
        'skippedVersion': data.skippedVersion,
        'lastCheckedAt': data.lastCheckedAt?.millisecondsSinceEpoch,
      })}\n',
      flush: true,
    );
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }
}
```

- [ ] **Step 4: Run test, verify passes.** Run: `flutter test test/features/update/data/json_update_preferences_test.dart` — Expected: PASS.
- [ ] **Step 5: Commit.**

```bash
git add lib/features/update/data/json_update_preferences.dart test/features/update/data/json_update_preferences_test.dart
git commit -m "feat: persist update preferences with atomic json store"
```

---

### Task 7: UpdateCoordinator

**Files:**
- Create: `lib/features/update/application/update_coordinator.dart`
- Test: `test/features/update/application/update_coordinator_test.dart`

**Interfaces:**
- Consumes: `UpdateCheckerPort`, `ChannelDetectorPort`, `UpdatePreferencesPort`, `UpdatePreferencesData`, `AppVersion`, `UpdateStatus`/`UpToDate`/`UpdateAvailable`/`CheckFailed`, `UpdateCheckException`.
- Produces: `final class UpdateCoordinator` constructed with `({required UpdateCheckerPort checker, required ChannelDetectorPort detector, required UpdatePreferencesPort preferences, required AppVersion currentVersion, required DateTime Function() now, Duration throttle})`. Methods:
  - `Future<UpdateAvailable?> checkOnLaunch()` — respects opt-out + 24 h throttle + skipped version; silent on failure; records `lastCheckedAt` on a completed check.
  - `Future<UpdateStatus> checkManually()` — ignores throttle/skip; returns `CheckFailed` on failure; records `lastCheckedAt`.
  - `Future<void> skipVersion(String version)` — persists `skippedVersion`.
  - `Future<void> setAutoCheckEnabled(bool enabled)` — persists `autoCheckEnabled`.
  - `Future<bool> autoCheckEnabled()` — reads the current toggle.

- [ ] **Step 1: Write failing test** with fakes:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/features/update/domain/app_version.dart';
import 'package:gapless/features/update/domain/channel_detector_port.dart';
import 'package:gapless/features/update/domain/install_channel.dart';
import 'package:gapless/features/update/domain/release_info.dart';
import 'package:gapless/features/update/domain/update_checker_port.dart';
import 'package:gapless/features/update/domain/update_preferences_port.dart';
import 'package:gapless/features/update/domain/update_status.dart';
import 'package:gapless/features/update/application/update_coordinator.dart';

class _FakeChecker implements UpdateCheckerPort {
  _FakeChecker(this._result);
  final Object _result; // ReleaseInfo or UpdateCheckException
  int calls = 0;
  @override
  Future<ReleaseInfo> fetchLatest() async {
    calls++;
    final result = _result;
    if (result is ReleaseInfo) return result;
    throw result as Object;
  }
}

class _FakeDetector implements ChannelDetectorPort {
  _FakeDetector(this.channel);
  final InstallChannel channel;
  @override
  Future<InstallChannel> detect() async => channel;
}

class _MemoryPrefs implements UpdatePreferencesPort {
  _MemoryPrefs([this.data = const UpdatePreferencesData()]);
  UpdatePreferencesData data;
  @override
  Future<UpdatePreferencesData> load() async => data;
  @override
  Future<void> save(UpdatePreferencesData next) async => data = next;
}

ReleaseInfo _release(String v) => ReleaseInfo(
      version: AppVersion.tryParse(v)!,
      notes: '',
      htmlUrl: 'https://github.com/navnit/gapless-app/releases/tag/v$v',
    );

UpdateCoordinator _coordinator({
  required UpdateCheckerPort checker,
  UpdatePreferencesPort? prefs,
  DateTime? now,
}) =>
    UpdateCoordinator(
      checker: checker,
      detector: _FakeDetector(InstallChannel.homebrew),
      preferences: prefs ?? _MemoryPrefs(),
      currentVersion: AppVersion.tryParse('0.1.1')!,
      now: () => now ?? DateTime.fromMillisecondsSinceEpoch(1700000000000),
    );

void main() {
  test('launch check returns UpdateAvailable and records timestamp', () async {
    final prefs = _MemoryPrefs();
    final result = await _coordinator(checker: _FakeChecker(_release('0.2.0')), prefs: prefs).checkOnLaunch();
    expect(result, isA<UpdateAvailable>());
    expect(prefs.data.lastCheckedAt, isNotNull);
  });

  test('launch check is skipped within the throttle window', () async {
    final now = DateTime.fromMillisecondsSinceEpoch(1700000000000);
    final prefs = _MemoryPrefs(UpdatePreferencesData(lastCheckedAt: now.subtract(const Duration(hours: 1))));
    final checker = _FakeChecker(_release('0.2.0'));
    final result = await _coordinator(checker: checker, prefs: prefs, now: now).checkOnLaunch();
    expect(result, isNull);
    expect(checker.calls, 0);
  });

  test('launch check short-circuits when auto-check disabled', () async {
    final prefs = _MemoryPrefs(const UpdatePreferencesData(autoCheckEnabled: false));
    final checker = _FakeChecker(_release('0.2.0'));
    expect(await _coordinator(checker: checker, prefs: prefs).checkOnLaunch(), isNull);
    expect(checker.calls, 0);
  });

  test('launch check suppresses a skipped version but manual still reports it', () async {
    final prefs = _MemoryPrefs(const UpdatePreferencesData(skippedVersion: '0.2.0'));
    expect(await _coordinator(checker: _FakeChecker(_release('0.2.0')), prefs: prefs).checkOnLaunch(), isNull);
    final manual = await _coordinator(checker: _FakeChecker(_release('0.2.0')), prefs: prefs).checkManually();
    expect(manual, isA<UpdateAvailable>());
  });

  test('up-to-date when latest is not newer', () async {
    expect(await _coordinator(checker: _FakeChecker(_release('0.1.1'))).checkManually(), isA<UpToDate>());
  });

  test('launch failure is swallowed, manual failure surfaces reason', () async {
    final launch = await _coordinator(
      checker: _FakeChecker(const UpdateCheckException(CheckFailureReason.rateLimited)),
    ).checkOnLaunch();
    expect(launch, isNull);
    final manual = await _coordinator(
      checker: _FakeChecker(const UpdateCheckException(CheckFailureReason.rateLimited)),
    ).checkManually();
    expect(manual, isA<CheckFailed>());
    expect((manual as CheckFailed).reason, CheckFailureReason.rateLimited);
  });
}
```

- [ ] **Step 2: Run test, verify fails.** Run: `flutter test test/features/update/application/update_coordinator_test.dart` — Expected: FAIL.
- [ ] **Step 3: Implement.**

```dart
import 'package:gapless/features/update/domain/app_version.dart';
import 'package:gapless/features/update/domain/channel_detector_port.dart';
import 'package:gapless/features/update/domain/update_checker_port.dart';
import 'package:gapless/features/update/domain/update_preferences_port.dart';
import 'package:gapless/features/update/domain/update_status.dart';

final class UpdateCoordinator {
  UpdateCoordinator({
    required this.checker,
    required this.detector,
    required this.preferences,
    required this.currentVersion,
    required this.now,
    this.throttle = const Duration(hours: 24),
  });

  final UpdateCheckerPort checker;
  final ChannelDetectorPort detector;
  final UpdatePreferencesPort preferences;
  final AppVersion currentVersion;
  final DateTime Function() now;
  final Duration throttle;

  Future<UpdateAvailable?> checkOnLaunch() async {
    final prefs = await preferences.load();
    if (!prefs.autoCheckEnabled) return null;
    final last = prefs.lastCheckedAt;
    if (last != null && now().difference(last) < throttle) return null;
    try {
      final status = await _check();
      await preferences.save(prefs.copyWith(lastCheckedAt: now()));
      if (status is UpdateAvailable &&
          status.release.version.toString() != prefs.skippedVersion) {
        return status;
      }
      return null;
    } on Object {
      return null;
    }
  }

  Future<UpdateStatus> checkManually() async {
    final prefs = await preferences.load();
    try {
      final status = await _check();
      await preferences.save(prefs.copyWith(lastCheckedAt: now()));
      return status;
    } on UpdateCheckException catch (error) {
      return CheckFailed(error.reason);
    }
  }

  Future<void> skipVersion(String version) async {
    final prefs = await preferences.load();
    await preferences.save(prefs.copyWith(skippedVersion: version));
  }

  Future<void> setAutoCheckEnabled(bool enabled) async {
    final prefs = await preferences.load();
    await preferences.save(prefs.copyWith(autoCheckEnabled: enabled));
  }

  Future<bool> autoCheckEnabled() async => (await preferences.load()).autoCheckEnabled;

  Future<UpdateStatus> _check() async {
    final release = await checker.fetchLatest();
    if (!release.version.isNewerThan(currentVersion)) return const UpToDate();
    final channel = await detector.detect();
    return UpdateAvailable(release: release, channel: channel, current: currentVersion);
  }
}
```

- [ ] **Step 4: Run test, verify passes.** Run: `flutter test test/features/update/application/update_coordinator_test.dart` — Expected: PASS.
- [ ] **Step 5: Commit.**

```bash
git add lib/features/update/application/update_coordinator.dart test/features/update/application/update_coordinator_test.dart
git commit -m "feat: orchestrate update check with throttle, opt-out, and skip"
```

---

### Task 8: URL-safety guard and external opener

**Files:**
- Create: `lib/features/update/presentation/update_url.dart`
- Test: `test/features/update/presentation/update_url_test.dart`

**Interfaces:**
- Produces:
  - `bool isAllowedUpdateUrl(String url)` — true only for `https` + host ∈ {`github.com`, `objects.githubusercontent.com`}.
  - `const String kBrewUpgradeCommand = 'brew upgrade --cask gapless';`
  - `Future<void> openExternalUrl(String url, {Future<void> Function(String, List<String>) run})` — validates then `open`s via `Process.run` (injectable `run` for tests, default `Process.run`). No-op on a disallowed URL.

- [ ] **Step 1: Write failing test.**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/features/update/presentation/update_url.dart';

void main() {
  test('allows only https github hosts', () {
    expect(isAllowedUpdateUrl('https://github.com/navnit/gapless-app/releases'), isTrue);
    expect(isAllowedUpdateUrl('https://objects.githubusercontent.com/x.dmg'), isTrue);
    expect(isAllowedUpdateUrl('http://github.com/x'), isFalse);
    expect(isAllowedUpdateUrl('https://evil.example.com/x'), isFalse);
    expect(isAllowedUpdateUrl('file:///etc/passwd'), isFalse);
    expect(isAllowedUpdateUrl('not a url'), isFalse);
  });

  test('openExternalUrl runs open only for allowed urls', () async {
    final calls = <List<String>>[];
    Future<void> fakeRun(String cmd, List<String> args) async => calls.add([cmd, ...args]);

    await openExternalUrl('https://github.com/x', run: fakeRun);
    await openExternalUrl('file:///etc/passwd', run: fakeRun);

    expect(calls, [['open', 'https://github.com/x']]);
  });
}
```

- [ ] **Step 2: Run test, verify fails.** Run: `flutter test test/features/update/presentation/update_url_test.dart` — Expected: FAIL.
- [ ] **Step 3: Implement.**

```dart
import 'dart:io';

const String kBrewUpgradeCommand = 'brew upgrade --cask gapless';

const _allowedHosts = {'github.com', 'objects.githubusercontent.com'};

bool isAllowedUpdateUrl(String url) {
  final parsed = Uri.tryParse(url);
  if (parsed == null) return false;
  return parsed.scheme == 'https' && _allowedHosts.contains(parsed.host);
}

Future<void> openExternalUrl(
  String url, {
  Future<void> Function(String, List<String>) run = _defaultRun,
}) async {
  if (!isAllowedUpdateUrl(url)) return;
  await run('open', [url]);
}

Future<void> _defaultRun(String executable, List<String> arguments) async {
  await Process.run(executable, arguments);
}
```

- [ ] **Step 4: Run test, verify passes.** Run: `flutter test test/features/update/presentation/update_url_test.dart` — Expected: PASS.
- [ ] **Step 5: Commit.**

```bash
git add lib/features/update/presentation/update_url.dart test/features/update/presentation/update_url_test.dart
git commit -m "feat: guard external update urls to https github hosts"
```

---

### Task 9: UpdateDialog

**Files:**
- Create: `lib/features/update/presentation/update_dialog.dart`
- Test: `test/features/update/presentation/update_dialog_test.dart`

**Interfaces:**
- Consumes: `UpdateAvailable`, `InstallChannel`, `kBrewUpgradeCommand`, `openExternalUrl`.
- Produces: `class UpdateDialog extends StatelessWidget` with `({required UpdateAvailable status, required VoidCallback onSkip, required VoidCallback onClose, Future<void> Function(String)? openUrl, Future<void> Function(String)? copyText})`. For `homebrew`: shows `kBrewUpgradeCommand` text + a Copy button. For `directDmg`/`unknown`: shows a **Download** button and the "drag … choose Replace" reminder.

- [ ] **Step 1: Write failing test.**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/features/update/domain/app_version.dart';
import 'package:gapless/features/update/domain/install_channel.dart';
import 'package:gapless/features/update/domain/release_info.dart';
import 'package:gapless/features/update/domain/update_status.dart';
import 'package:gapless/features/update/presentation/update_dialog.dart';

UpdateAvailable _status(InstallChannel channel) => UpdateAvailable(
      release: ReleaseInfo(
        version: AppVersion.tryParse('0.2.0')!,
        notes: 'What is new',
        htmlUrl: 'https://github.com/navnit/gapless-app/releases/tag/v0.2.0',
        dmgAssetUrl: 'https://github.com/navnit/gapless-app/releases/download/v0.2.0/Gapless-0.2.0-macos-arm64-UNNOTARIZED.dmg',
      ),
      channel: channel,
      current: AppVersion.tryParse('0.1.1')!,
    );

Future<void> _pump(WidgetTester tester, InstallChannel channel) => tester.pumpWidget(
      MaterialApp(
        home: UpdateDialog(status: _status(channel), onSkip: () {}, onClose: () {}, openUrl: (_) async {}, copyText: (_) async {}),
      ),
    );

void main() {
  testWidgets('homebrew shows the brew command', (tester) async {
    await _pump(tester, InstallChannel.homebrew);
    expect(find.text('brew upgrade --cask gapless'), findsOneWidget);
    expect(find.text('Download'), findsNothing);
  });

  testWidgets('directDmg shows a Download action', (tester) async {
    await _pump(tester, InstallChannel.directDmg);
    expect(find.text('Download'), findsOneWidget);
    expect(find.textContaining('Replace'), findsOneWidget);
  });

  testWidgets('unknown channel is treated like directDmg', (tester) async {
    await _pump(tester, InstallChannel.unknown);
    expect(find.text('Download'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run test, verify fails.** Run: `flutter test test/features/update/presentation/update_dialog_test.dart` — Expected: FAIL.
- [ ] **Step 3: Implement.**

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gapless/features/update/domain/install_channel.dart';
import 'package:gapless/features/update/domain/update_status.dart';
import 'package:gapless/features/update/presentation/update_url.dart';

class UpdateDialog extends StatelessWidget {
  const UpdateDialog({
    required this.status,
    required this.onSkip,
    required this.onClose,
    this.openUrl,
    this.copyText,
    super.key,
  });

  final UpdateAvailable status;
  final VoidCallback onSkip;
  final VoidCallback onClose;
  final Future<void> Function(String url)? openUrl;
  final Future<void> Function(String text)? copyText;

  Future<void> _open(String url) async => (openUrl ?? openExternalUrl)(url);

  Future<void> _copy(String text) async =>
      (copyText ?? (value) => Clipboard.setData(ClipboardData(text: value)))(text);

  @override
  Widget build(BuildContext context) {
    final release = status.release;
    final isBrew = status.channel == InstallChannel.homebrew;
    return AlertDialog(
      title: Text('Gapless ${release.version} is available'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('You have ${status.current}.', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: SingleChildScrollView(child: Text(release.notes)),
            ),
            const SizedBox(height: 16),
            if (isBrew)
              Row(children: [
                Expanded(child: SelectableText(kBrewUpgradeCommand)),
                TextButton(onPressed: () => _copy(kBrewUpgradeCommand), child: const Text('Copy')),
              ])
            else
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                FilledButton(
                  onPressed: () => _open(release.dmgAssetUrl ?? release.htmlUrl),
                  child: const Text('Download'),
                ),
                const SizedBox(height: 6),
                Text(
                  'Drag the new Gapless into Applications and choose Replace.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ]),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => _open(release.htmlUrl), child: const Text('View release')),
        TextButton(onPressed: onSkip, child: const Text('Skip this version')),
        TextButton(onPressed: onClose, child: const Text('Close')),
      ],
    );
  }
}
```

- [ ] **Step 4: Run test, verify passes.** Run: `flutter test test/features/update/presentation/update_dialog_test.dart` — Expected: PASS.
- [ ] **Step 5: Commit.**

```bash
git add lib/features/update/presentation/update_dialog.dart test/features/update/presentation/update_dialog_test.dart
git commit -m "feat: channel-branched update dialog"
```

---

### Task 10: UpdateBanner

**Files:**
- Create: `lib/features/update/presentation/update_banner.dart`
- Test: `test/features/update/presentation/update_banner_test.dart`

**Interfaces:**
- Consumes: `UpdateAvailable`.
- Produces: `class UpdateBanner extends StatelessWidget` with `({required UpdateAvailable status, required VoidCallback onView, required VoidCallback onSkip, required VoidCallback onDismiss})`.

- [ ] **Step 1: Write failing test.**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/features/update/domain/app_version.dart';
import 'package:gapless/features/update/domain/install_channel.dart';
import 'package:gapless/features/update/domain/release_info.dart';
import 'package:gapless/features/update/domain/update_status.dart';
import 'package:gapless/features/update/presentation/update_banner.dart';

void main() {
  testWidgets('shows the new version and fires View', (tester) async {
    var viewed = false;
    final status = UpdateAvailable(
      release: ReleaseInfo(version: AppVersion.tryParse('0.2.0')!, notes: '', htmlUrl: 'https://github.com/x'),
      channel: InstallChannel.homebrew,
      current: AppVersion.tryParse('0.1.1')!,
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: UpdateBanner(status: status, onView: () => viewed = true, onSkip: () {}, onDismiss: () {}),
      ),
    ));
    expect(find.textContaining('0.2.0'), findsOneWidget);
    await tester.tap(find.text('View'));
    expect(viewed, isTrue);
  });
}
```

- [ ] **Step 2: Run test, verify fails.** Run: `flutter test test/features/update/presentation/update_banner_test.dart` — Expected: FAIL.
- [ ] **Step 3: Implement.**

```dart
import 'package:flutter/material.dart';
import 'package:gapless/features/update/domain/update_status.dart';

class UpdateBanner extends StatelessWidget {
  const UpdateBanner({
    required this.status,
    required this.onView,
    required this.onSkip,
    required this.onDismiss,
    super.key,
  });

  final UpdateAvailable status;
  final VoidCallback onView;
  final VoidCallback onSkip;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(children: [
          const Icon(Icons.arrow_circle_up, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text('Gapless ${status.release.version} is available')),
          TextButton(onPressed: onView, child: const Text('View')),
          TextButton(onPressed: onSkip, child: const Text('Skip this version')),
          IconButton(onPressed: onDismiss, icon: const Icon(Icons.close, size: 16), tooltip: 'Remind me later'),
        ]),
      ),
    );
  }
}
```

- [ ] **Step 4: Run test, verify passes.** Run: `flutter test test/features/update/presentation/update_banner_test.dart` — Expected: PASS.
- [ ] **Step 5: Commit.**

```bash
git add lib/features/update/presentation/update_banner.dart test/features/update/presentation/update_banner_test.dart
git commit -m "feat: dismissible update-available banner"
```

---

### Task 11: AppUpdateServices and AppDependencies wiring

**Files:**
- Create: `lib/features/update/application/app_update_services.dart`
- Modify: `lib/app/app_dependencies.dart` (add `update` field + construct in `production`; imports)
- Test: `test/app/app_dependencies_update_test.dart`

**Interfaces:**
- Consumes: `UpdateCoordinator`, `GithubUpdateChecker`, `CaskroomChannelDetector`, `JsonUpdatePreferences`, `AppVersion`, `package_info_plus`, `Abi`.
- Produces:
  - `final class AppUpdateServices { final UpdateCoordinator coordinator; }`
  - `AppDependencies.update` (`AppUpdateServices?`), non-null from `production()`, null from `empty()`.
  - `production()` gains optional injection params: `UpdateCoordinator? updateCoordinator` (bypasses real construction in tests).

- [ ] **Step 1: Write failing test.**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/app/app_dependencies.dart';
// Reuse fakes: define a minimal coordinator by injecting one built from fakes,
// or assert production wires a non-null update service on a real (macOS) host.

void main() {
  test('empty dependencies expose no update services', () {
    expect(const AppDependencies.empty().update, isNull);
  });
}
```

> The `production()` path constructs real `package_info_plus`/filesystem clients; the deep wiring is exercised by the coordinator's own tests. This task's automated check asserts the `empty()` contract and that the code compiles + analyzes; manual verification (Task 14) confirms the live launch check. If `production()` gains an injectable `updateCoordinator` param, add an assertion that passing a fake yields `update != null`.

- [ ] **Step 2: Run test, verify fails.** Run: `flutter test test/app/app_dependencies_update_test.dart` — Expected: FAIL (`update` getter missing).
- [ ] **Step 3: Implement `app_update_services.dart`.**

```dart
import 'package:gapless/features/update/application/update_coordinator.dart';

final class AppUpdateServices {
  const AppUpdateServices({required this.coordinator});

  final UpdateCoordinator coordinator;
}
```

- [ ] **Step 4: Wire into `AppDependencies`.** In `lib/app/app_dependencies.dart`:
  - Add field `final AppUpdateServices? update;` to the class; add `this.update` to the const constructor; set `update = null` in `AppDependencies.empty()`.
  - Add imports for `package_info_plus`, `dart:ffi` `Abi`, and the update data/application classes.
  - Add an optional param `UpdateCoordinator? updateCoordinator` to `production()`.
  - Build the coordinator near the existing `applicationSupport` usage:

```dart
final resolvedUpdateCoordinator = updateCoordinator ??
    UpdateCoordinator(
      checker: GithubUpdateChecker(
        client: http.Client(),
        archToken: Abi.current() == Abi.macosX64 ? 'x64' : 'arm64',
      ),
      detector: CaskroomChannelDetector(resolvedExecutable: Platform.resolvedExecutable),
      preferences: JsonUpdatePreferences(
        File(p.join(directories.applicationSupport.path, 'update-preferences.json')),
      ),
      currentVersion: AppVersion.tryParse((await PackageInfo.fromPlatform()).version) ??
          const AppVersion(0, 0, 0),
      now: DateTime.now,
    );
```

  - Pass `update: AppUpdateServices(coordinator: resolvedUpdateCoordinator)` in the returned `AppDependencies(...)`.

- [ ] **Step 5: Run test + analyze.** Run: `flutter test test/app/app_dependencies_update_test.dart` then `flutter analyze` — Expected: PASS / no issues.
- [ ] **Step 6: Commit.**

```bash
git add lib/features/update/application/app_update_services.dart lib/app/app_dependencies.dart test/app/app_dependencies_update_test.dart
git commit -m "feat: wire update services into AppDependencies.production"
```

---

### Task 12: GaplessApp integration — menu, banner, launch check

**Files:**
- Modify: `lib/app/gapless_app.dart`
- Test: `test/app/gapless_app_update_test.dart`

**Interfaces:**
- Consumes: `AppUpdateServices`, `UpdateCoordinator`, `UpdateAvailable`, `UpdateStatus`/`UpToDate`/`CheckFailed`, `UpdateBanner`, `UpdateDialog`, `PlatformMenuBar`.
- Produces: no new public API; `_GaplessAppState` gains update state + handlers.

- [ ] **Step 1: Write failing test** (inject a fake coordinator through `AppDependencies` so no network happens; assert a banner renders when a launch update is available):

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// Build an AppDependencies whose update.coordinator returns a fixed UpdateAvailable
// from checkOnLaunch(). Pump GaplessApp, pumpAndSettle, expect the banner text.
// (Construct the coordinator from the in-memory fakes used in Task 7.)
```

> Concretely: reuse the `_FakeChecker`/`_FakeDetector`/`_MemoryPrefs` from Task 7 (extract them to `test/features/update/support/fakes.dart` in this task and import from both places — DRY), build a real `UpdateCoordinator` returning `0.2.0`, wrap in `AppUpdateServices`, place on `AppDependencies`, then:

```dart
  testWidgets('shows the update banner after a launch check', (tester) async {
    await tester.pumpWidget(GaplessApp(dependencies: deps));
    await tester.pumpAndSettle();
    expect(find.textContaining('0.2.0 is available'), findsOneWidget);
  });
```

- [ ] **Step 2: Run test, verify fails.** Run: `flutter test test/app/gapless_app_update_test.dart` — Expected: FAIL.
- [ ] **Step 3: Implement in `_GaplessAppState`.**
  - Add `UpdateAvailable? _availableUpdate;` and `bool _autoCheckEnabled = true;`.
  - In `initState`, if `widget.dependencies.update case final services?`, call `unawaited(_runLaunchCheck(services.coordinator))`:

```dart
Future<void> _runLaunchCheck(UpdateCoordinator coordinator) async {
  _autoCheckEnabled = await coordinator.autoCheckEnabled();
  final result = await coordinator.checkOnLaunch();
  if (!mounted) return;
  setState(() => _availableUpdate = result);
}
```

  - Add handlers: `_openUpdateDialog()` (shows `UpdateDialog` via `showDialog` using `_navigatorKey.currentContext`), `_skipAvailable()` (calls `coordinator.skipVersion(version)` then clears the banner), `_dismissBanner()` (clears `_availableUpdate` only), `_runManualCheck()` (calls `checkManually()` and shows dialog/snackbar per outcome), `_toggleAutoCheck(bool)` (calls `setAutoCheckEnabled` + setState).
  - Wrap `home:` in a `PlatformMenuBar` adding a menu group with a "Check for Updates…" item (`onSelected: _runManualCheck`) and a checkbox-style "Automatically check for updates" item bound to `_autoCheckEnabled`/`_toggleAutoCheck`. Guard with `if (widget.dependencies.update != null)` so `empty()` builds unchanged.
  - Render the banner above `EditorScreen`: replace `home: EditorScreen(...)` with a `Column`/overlay where `if (_availableUpdate case final update?) UpdateBanner(status: update, onView: _openUpdateDialog, onSkip: _skipAvailable, onDismiss: _dismissBanner)` sits above `Expanded(child: EditorScreen(...))`.

- [ ] **Step 4: Run test + analyze.** Run: `flutter test test/app/gapless_app_update_test.dart` then `flutter analyze` — Expected: PASS / no issues.
- [ ] **Step 5: Commit.**

```bash
git add lib/app/gapless_app.dart test/app/gapless_app_update_test.dart test/features/update/support/fakes.dart
git commit -m "feat: surface update menu, banner, and launch check in GaplessApp"
```

---

### Task 13: README note and full verification

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Document the check** in `README.md` (near install/usage): a short paragraph — Gapless checks GitHub for a newer release on launch (at most once per day), shows a banner if one exists, and this can be turned off via the app menu's "Automatically check for updates".
- [ ] **Step 2: Run the full suite.** Run: `flutter test` — Expected: all pass (existing + new `test/features/update/**`, `test/app/*update*`).
- [ ] **Step 3: Analyze + format.** Run: `flutter analyze` (Expected: no issues) and `dart format --set-exit-if-changed lib/features/update lib/app/gapless_app.dart` (Expected: already formatted; if it reformats, re-stage).
- [ ] **Step 4: Manual smoke (macOS).** Run `flutter run -d macos`, confirm no crash and that "Check for Updates…" appears in the app menu and reports a result (against the live GitHub API). Note: requires the Task 0 debug entitlement.
- [ ] **Step 5: Commit.**

```bash
git add README.md
git commit -m "docs: describe in-app update check and how to disable it"
```

---

## Self-Review

**Spec coverage** — each spec section maps to a task:
- Auto-check on launch + throttle + opt-out → Tasks 6, 7, 12.
- Manual "Check for Updates…" via native menu → Task 12.
- Channel detection (receipt + directory + fallbacks) → Task 4.
- Version compare (numeric, fail-safe) → Task 1.
- GitHub client (arch match, notes cap, 403/429) → Task 5.
- Preferences (autoCheckEnabled/skippedVersion/lastCheckedAt, atomic store) → Tasks 3, 6.
- URL safety + brew constant → Task 8.
- UI states (dialog, banner, menu) → Tasks 9, 10, 12.
- Silent-launch / reported-manual error handling → Task 7.
- Two deps + debug entitlement → Task 0.
- README disclosure → Task 13.

**Placeholder scan** — no "TBD"/"add error handling" placeholders; every code step is concrete. Task 11 Step 1 and Task 12 Step 1 intentionally describe the test scaffold in prose because they reuse fakes extracted in Task 12 Step 5 / and assert the `empty()` contract; the concrete assertions are given.

**Type consistency** — `UpdateCoordinator` ctor params (`checker`/`detector`/`preferences`/`currentVersion`/`now`/`throttle`), `UpdateAvailable({release, channel, current})`, `CheckFailureReason{rateLimited, network}`, `AppUpdateServices({coordinator})`, `isAllowedUpdateUrl`, `openExternalUrl`, `kBrewUpgradeCommand`, and `AppVersion.tryParse/isNewerThan/toString` are used identically across producing and consuming tasks.

## Execution Handoff

Offered separately.
