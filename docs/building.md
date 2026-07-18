# Building and releasing Gapless

Gapless 0.1.0 is the first public release target, for macOS 12+ Apple Silicon
and Intel DMGs. Public downloads become available only after the protected tag workflow succeeds and approval completes.
After that success, download assets from the [latest GitHub Release](https://github.com/navnit/gapless/releases/latest).
Windows 10+ x64 and Linux x64 remain planned targets; the Linux target uses an
Ubuntu 24.04/glibc 2.39 baseline.

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

The protected macOS release workflow requires these repository secrets:

- `MACOS_P12_BASE64`
- `MACOS_P12_PASSWORD`
- `MACOS_KEYCHAIN_PASSWORD`
- `MACOS_NOTARY_KEY_BASE64`
- `MACOS_NOTARY_KEY_ID`
- `MACOS_NOTARY_ISSUER`
- `MACOS_SIGN_IDENTITY`

On macOS, sign the nested engine and process host before the app, then notarize,
staple, and validate the DMG ticket. Never print signing credentials or pass
them to pull-request workflows.

## 0.1.0 release workflow

In the repository settings, create the protected `macos-release` environment
and configure at least one required reviewer before assigning its signing and
notarization secrets. The workflow has separate manual-candidate and tag entry
points. A manual candidate runs from `main` with version `0.1.0`; it signs,
notarizes, validates, smoke-tests, and uploads its DMGs as Actions artifacts,
without creating or modifying a GitHub Release.

After the manual candidate has passed, create annotated tag `v0.1.0` from the
approved `main` commit and push it. The tag run builds the Apple Silicon and
Intel DMGs and waits for approval in `macos-release`. Only approval of that tag
run makes the GitHub Release public.

## Release outputs

The approved `v0.1.0` tag run publishes separate Apple Silicon and Intel DMGs,
`SHA256SUMS`, the SPDX SBOM, notices, and this build guide.
