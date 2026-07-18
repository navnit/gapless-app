# Building and releasing Gapless

Gapless 1.x targets macOS 12+ (Apple Silicon and Intel), Windows 10+ x64, and
Linux x64 with a glibc 2.35 baseline (Ubuntu 22.04 runners).

## Reproducible inputs

Install Flutter 3.44.4 (the exact version pinned by CI), then run:

```sh
flutter pub get
dart run tool/engine/fetch_engine.dart
dart run tool/engine/fetch_engine.dart --verify-only
flutter analyze
flutter test
```

The engine URLs and hashes are committed in `assets/engine/manifest.json`.
Packaging-tool versions and download hashes are committed in
`tool/release/tool_manifest.json`. Release jobs fail rather than using an
unverified replacement.

Build release artifacts from a checkout outside iCloud Drive and other
FileProvider-managed directories. If codesign reports `resource fork, Finder
information, or similar detritus not allowed`, move the checkout or build
mirror to a local non-FileProvider filesystem; clearing only the finished app
is insufficient because incremental framework copies can restore the metadata.

## Native bundle layouts

- macOS: `Gapless.app/Contents/Resources/engine/auto-editor`
- Windows: `engine/auto-editor.exe` beside `Gapless.exe`
- Linux AppDir: `usr/lib/gapless/engine/auto-editor`

Each layout includes the engine manifest and a `compliance` directory with the
third-party notices, source offer, and SPDX SBOM. Run `verify_bundle.dart`
against the native bundle with its exact manifest target before creating its
installer.

## Signing

CI secrets are available only to tagged release jobs. On macOS, sign the nested
engine and process host before the app, then notarize and staple the DMG. On
Windows, Authenticode-sign the engine, app, process host, and final installer.
Linux publishes the AppImage plus detached SHA-256 sums. Never print signing
credentials or pass them to pull-request workflows.

## Release outputs

Tagged releases publish separate arm64 and x64 DMGs, an x64 Windows installer,
an x64 AppImage, `SHA256SUMS`, the SPDX SBOM, notices, and this build guide.
