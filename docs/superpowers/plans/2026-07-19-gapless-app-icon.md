# Gapless App Icon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the default Flutter macOS and Windows launcher icons with the approved, reproducibly generated Gap Bars artwork.

**Architecture:** Add one pure-Dart branding tool that renders the icon at each native size, encodes deterministic PNG and ICO bytes, and transactionally replaces the committed platform assets. A focused Flutter test imports that tool to verify its binary contracts, platform configuration, exact regeneration, colors, and absence of Flutter branding; the existing macOS and Windows build paths continue consuming their current asset references.

**Tech Stack:** Dart 3.12 standard library, Flutter test, Xcode asset catalogs, Windows resource compiler, GitHub Actions.

## Global Constraints

- Use charcoal `#17191D` for the rounded-square background.
- Use amber `#E3A63B` for both vertical bars; render the right bar at 45 percent opacity over the background.
- Include no letters, words, gradients, photographs, shadows, or Flutter branding.
- Generate macOS PNGs at 16, 32, 64, 128, 256, 512, and 1024 px.
- Generate Windows ICO frames at 16, 32, 48, 64, 128, and 256 px.
- Generate each size directly with antialiasing; never upscale a smaller source image.
- Keep generation deterministic and dependency-free beyond the Dart SDK already supplied by Flutter.
- Generate all bytes before replacing outputs, and restore every original file if any replacement fails.
- Leave Linux branding, runtime Flutter widgets, application behavior, signing identity, bundle ID, version `0.1.0+1`, and release-matrix targets unchanged.
- Deliver on `codex/macos-0.1.0-release` through pull request #2 without merging, tagging, dispatching a release, or creating a GitHub Release.

---

## File map

- Create `tool/branding/generate_app_icons.dart`: approved geometry, supersampled rasterization, deterministic PNG/ICO encoders, transactional writer, and CLI entry point.
- Create `test/tool/branding/generate_app_icons_test.dart`: binary-format, artwork, determinism, platform-reference, and committed-output contracts.
- Replace `macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{16,32,64,128,256,512,1024}.png`: generated macOS assets consumed by the existing `Contents.json`.
- Replace `windows/runner/resources/app_icon.ico`: generated multi-frame Windows icon consumed by the existing `Runner.rc`.

### Task 1: Deterministic Gap Bars raster and encoders

**Files:**
- Create: `tool/branding/generate_app_icons.dart`
- Create: `test/tool/branding/generate_app_icons_test.dart`

**Interfaces:**
- Produces: `const macosIconSizes`, `const windowsIconSizes`, `Uint8List renderGaplessPng(int size)`, `Uint8List encodeWindowsIco(Map<int, Uint8List> pngFrames)`, `PngInfo inspectPng(Uint8List bytes)`, and `List<IcoFrame> inspectIco(Uint8List bytes)`.
- Consumes: Dart `dart:io`, `dart:math`, `dart:typed_data`, and `dart:convert` only.

- [ ] **Step 1: Write failing format and artwork tests**

Create tests that require the approved sizes and public binary inspection contracts:

```dart
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../../../tool/branding/generate_app_icons.dart';

void main() {
  group('Gapless app icon generator', () {
    test('renders deterministic PNGs at every macOS size', () {
      expect(macosIconSizes, <int>[16, 32, 64, 128, 256, 512, 1024]);
      for (final size in macosIconSizes) {
        final first = renderGaplessPng(size);
        final second = renderGaplessPng(size);
        expect(first, second, reason: '$size px output must be deterministic');
        final info = inspectPng(first);
        expect(info.width, size);
        expect(info.height, size);
        expect(info.rgbaAt(size ~/ 2, size ~/ 2), const Rgba(23, 25, 29, 255));
        expect(info.containsRgb(2, 169, 244), isFalse,
            reason: 'Flutter cyan must not remain');
      }
    });

    test('uses the approved solid and muted amber bars', () {
      final info = inspectPng(renderGaplessPng(256));
      expect(info.rgbaAt(98, 128), const Rgba(227, 166, 59, 255));
      expect(info.rgbaAt(158, 128), const Rgba(115, 88, 43, 255));
      expect(info.rgbaAt(0, 0).alpha, 0);
    });

    test('encodes every required Windows ICO frame', () {
      expect(windowsIconSizes, <int>[16, 32, 48, 64, 128, 256]);
      final ico = encodeWindowsIco(<int, Uint8List>{
        for (final size in windowsIconSizes) size: renderGaplessPng(size),
      });
      final frames = inspectIco(ico);
      expect(frames.map((frame) => frame.size), windowsIconSizes);
      for (final frame in frames) {
        expect(inspectPng(frame.pngBytes).width, frame.size);
      }
    });
  });
}
```

- [ ] **Step 2: Run the focused test and verify the expected failure**

Run: `flutter test test/tool/branding/generate_app_icons_test.dart`

Expected: FAIL because `tool/branding/generate_app_icons.dart` and its exported contracts do not exist.

- [ ] **Step 3: Implement the renderer and deterministic encoders**

Implement these exact public types and constants:

```dart
const macosIconSizes = <int>[16, 32, 64, 128, 256, 512, 1024];
const windowsIconSizes = <int>[16, 32, 48, 64, 128, 256];

final class Rgba {
  const Rgba(this.red, this.green, this.blue, this.alpha);
  final int red;
  final int green;
  final int blue;
  final int alpha;
  @override
  bool operator ==(Object other) =>
      other is Rgba &&
      red == other.red && green == other.green &&
      blue == other.blue && alpha == other.alpha;
  @override
  int get hashCode => Object.hash(red, green, blue, alpha);
}

final class PngInfo {
  const PngInfo(this.width, this.height, this._rgba);
  final int width;
  final int height;
  final Uint8List _rgba;
  Rgba rgbaAt(int x, int y) {
    if (x < 0 || x >= width || y < 0 || y >= height) {
      throw RangeError('Pixel ($x, $y) is outside ${width}x$height');
    }
    final offset = (y * width + x) * 4;
    return Rgba(
      _rgba[offset],
      _rgba[offset + 1],
      _rgba[offset + 2],
      _rgba[offset + 3],
    );
  }
  bool containsRgb(int red, int green, int blue) {
    for (var offset = 0; offset < _rgba.length; offset += 4) {
      if (_rgba[offset] == red &&
          _rgba[offset + 1] == green &&
          _rgba[offset + 2] == blue &&
          _rgba[offset + 3] != 0) {
        return true;
      }
    }
    return false;
  }
}

final class IcoFrame {
  const IcoFrame(this.size, this.pngBytes);
  final int size;
  final Uint8List pngBytes;
}
```

Rasterize each requested size directly with a 4 by 4 fixed supersampling grid. Use normalized geometry so each sample is tested against a rounded square inset by `0.0625`, with radius `0.21875`, and two rounded bars spanning `y = 0.28125..0.71875`, `x = 0.3515625..0.4296875` and `x = 0.5703125..0.6484375`. Composite sample coverage in premultiplied-alpha order: transparent canvas, opaque charcoal background, solid amber left bar, and amber at `0.45` opacity for the right bar. Average the 16 samples into one RGBA pixel.

Encode PNG with signature, `IHDR` (`8`-bit RGBA, color type `6`, filter/interlace `0`), `IDAT` containing `ZLibEncoder(level: 9).convert(...)`, and `IEND`. Prefix every scanline with filter byte `0`; calculate each chunk CRC-32 in Dart so the byte stream is stable. `inspectPng` must validate the signature and IHDR, concatenate and zlib-decode IDAT chunks, reject nonzero filters, and return decoded RGBA data.

Encode ICO with header `(reserved=0, type=1, count=6)`, one 16-byte directory entry per ascending size, `0` width/height bytes for 256 px, 32-bit color depth, and each PNG payload at its exact recorded offset. `inspectIco` must bounds-check the directory, normalize zero dimensions to 256, reject non-square frames, and return the embedded PNG bytes.

Reject sizes outside `16..1024` with `ArgumentError`. Reject malformed PNG and ICO inputs with `FormatException` messages that identify the invalid field.

- [ ] **Step 4: Run focused tests and analyzer**

Run: `dart format tool/branding/generate_app_icons.dart test/tool/branding/generate_app_icons_test.dart && flutter test test/tool/branding/generate_app_icons_test.dart && flutter analyze`

Expected: formatting succeeds, the focused test passes, and analyzer reports `No issues found!`.

- [ ] **Step 5: Commit the tested generator**

```bash
git add tool/branding/generate_app_icons.dart test/tool/branding/generate_app_icons_test.dart
git commit -m "feat: generate Gapless app icons"
```

### Task 2: Transactional platform assets and integration contracts

**Files:**
- Modify: `tool/branding/generate_app_icons.dart`
- Modify: `test/tool/branding/generate_app_icons_test.dart`
- Replace: `macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_16.png`
- Replace: `macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_32.png`
- Replace: `macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_64.png`
- Replace: `macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_128.png`
- Replace: `macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png`
- Replace: `macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_512.png`
- Replace: `macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png`
- Replace: `windows/runner/resources/app_icon.ico`

**Interfaces:**
- Consumes: Task 1 `renderGaplessPng` and `encodeWindowsIco`.
- Produces: `Future<Map<String, Uint8List>> generateAppIconFiles()`, `Future<void> writeAppIcons(Directory repositoryRoot)`, and CLI `dart run tool/branding/generate_app_icons.dart [REPOSITORY_ROOT]`.

- [ ] **Step 1: Add failing generation and platform-wiring tests**

Add tests that:

```dart
test('regenerates the exact committed macOS and Windows assets', () async {
  final root = Directory.current;
  final generated = await generateAppIconFiles();
  for (final entry in generated.entries) {
    expect(await File('${root.path}/${entry.key}').readAsBytes(), entry.value,
        reason: '${entry.key} must be regenerated before commit');
  }
});

test('platform configurations reference the generated assets', () async {
  final root = Directory.current;
  final catalog = await File(
    '${root.path}/macos/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json',
  ).readAsString();
  for (final size in macosIconSizes) {
    expect(catalog, contains('app_icon_$size.png'));
  }
  final runnerResource =
      await File('${root.path}/windows/runner/Runner.rc').readAsString();
  expect(runnerResource,
      contains(r'IDI_APP_ICON            ICON                    "resources\\app_icon.ico"'));
});

test('writes a complete generated set to a repository-shaped directory',
    () async {
  final root = await Directory.systemTemp.createTemp('gapless-icons-');
  addTearDown(() => root.delete(recursive: true));
  await writeAppIcons(root);
  for (final path in (await generateAppIconFiles()).keys) {
    expect(File('${root.path}/$path').existsSync(), isTrue);
  }
});
```

- [ ] **Step 2: Run the focused test and verify its committed-output failure**

Run: `flutter test test/tool/branding/generate_app_icons_test.dart`

Expected: FAIL because `generateAppIconFiles`/`writeAppIcons` do not exist and the committed platform assets still contain Flutter artwork.

- [ ] **Step 3: Implement generation, rollback, and CLI behavior**

`generateAppIconFiles` must return a `LinkedHashMap` in stable path order containing the seven macOS PNG paths and the Windows ICO path. It must render all assets in memory before any filesystem operation.

`writeAppIcons` must create required parent directories, write each result to a unique sibling `.gapless-icon-new` file, flush and close every handle, rename existing destinations to `.gapless-icon-backup`, then rename staged files into place. On any exception, remove only newly installed destinations, restore every backup, delete staged files, and rethrow a `FileSystemException('Unable to update Gapless app icons; original assets restored', ...)`. On success, delete the backups. Refuse to begin if a staging or backup path already exists, with a message naming that path.

The CLI must accept zero or one argument, default to `Directory.current`, print each updated relative path on success, and use exit code `64` plus `Usage: dart run tool/branding/generate_app_icons.dart [REPOSITORY_ROOT]` for extra arguments. Filesystem failures must set exit code `1` and print their clear exception message.

- [ ] **Step 4: Generate and inspect the committed assets**

Run: `dart run tool/branding/generate_app_icons.dart`

Expected: eight `Updated ...` lines, one for each platform file group member, and no `.gapless-icon-new` or `.gapless-icon-backup` files left behind.

Run: `flutter test test/tool/branding/generate_app_icons_test.dart && git diff --check`

Expected: all branding tests pass and whitespace validation is clean.

- [ ] **Step 5: Commit platform assets and integration contracts**

```bash
git add tool/branding/generate_app_icons.dart test/tool/branding/generate_app_icons_test.dart macos/Runner/Assets.xcassets/AppIcon.appiconset windows/runner/resources/app_icon.ico
git commit -m "feat: brand macOS and Windows app icons"
```

### Task 3: Native package proof and PR delivery

**Files:**
- Verify only: `build/macos/Build/Products/Release/Gapless.app/Contents/Resources/AppIcon.icns`
- Verify only: `.github/workflows/verify.yml`
- Verify only: `.github/workflows/windows-process-host.yml`

**Interfaces:**
- Consumes: committed generated assets from Task 2 and existing Flutter platform build configuration.
- Produces: a verified macOS bundle and a fresh green CI run on pull request #2.

- [ ] **Step 1: Run complete local static and test verification**

Run: `flutter analyze && flutter test`

Expected: analyzer reports `No issues found!`; every runnable test passes and only explicitly environment-gated tests are skipped.

- [ ] **Step 2: Build the macOS release bundle using the off-volume Flutter configuration**

Run:

```bash
XDG_CONFIG_HOME=/Users/navnit/Documents/desilence/.worktrees/macos-0.1.0-release/.superpowers/sdd/flutter-config flutter build macos --release
```

Expected: `Built build/macos/Build/Products/Release/Gapless.app`.

- [ ] **Step 3: Verify the packaged icon resource**

Run:

```bash
test -s build/macos/Build/Products/Release/Gapless.app/Contents/Resources/AppIcon.icns
file build/macos/Build/Products/Release/Gapless.app/Contents/Resources/AppIcon.icns
```

Expected: both commands succeed and `file` identifies a macOS icon resource rather than a Flutter source PNG.

Extract the package icon to a temporary directory with `iconutil -c iconset`, confirm its PNG entries can be read by `sips`, and visually inspect the largest extracted image against the approved charcoal/two-bar design.

- [ ] **Step 4: Review the branch diff and commits**

Run: `git status --short --branch && git diff origin/codex/macos-0.1.0-release...HEAD --stat && git log --oneline origin/codex/macos-0.1.0-release..HEAD`

Expected: only the design spec, implementation plan, generator, generator test, and generated macOS/Windows assets are added or changed; the branch contains intentional commits only.

- [ ] **Step 5: Push pull request #2 and watch every fresh check**

Run: `git push origin codex/macos-0.1.0-release`

Then run: `gh pr checks 2 --watch --interval 10`

Expected: the pushed head includes the icon commits and every required check reaches a terminal passing or explicitly skipped state. If any check fails, inspect its log, fix the root cause, rerun local proof, commit, push, and watch the replacement run before reporting completion.
