# Building and releasing Gapless

Gapless 0.1.0 is the first public release target, for macOS 12+ Apple Silicon
and Intel DMGs. The 0.1.0 build is ad hoc signed but is **not** signed with an
Apple Developer ID and is **not notarized** by Apple, so its artifacts are named
with an explicit `UNNOTARIZED` marker. Public downloads become available only after the protected tag workflow succeeds and approval completes.
After that success, download assets from the [latest GitHub Release](https://github.com/navnit/gapless-app/releases/latest).
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

## Git hooks

CI (`.github/workflows/verify.yml`) rejects any commit whose Dart is
unformatted or fails the analyzer. Enable the matching pre-commit hook once per
clone to catch both locally:

```sh
git config core.hooksPath tool/hooks
```

The hook (`tool/hooks/pre-commit`) auto-formats the staged Dart files with
`dart format`, re-stages them, then runs `flutter analyze` and blocks the
commit if the analyzer reports problems. Bypass it for a single commit with
`git commit --no-verify`.

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
third-party notices, source offer, and SPDX SBOM. For a macOS release, the
public per-target SBOM remains outside the signed app: the workflow generates
it from the final signed app after packaging, then checks exact regular-file
coverage and SHA-256 values against both the build app and the mounted DMG app.

## Ad hoc signing (no Apple Developer ID)

The 0.1.0 macOS release requires no Apple Developer Program membership and no
repository or environment signing secrets. `packaging/macos/package_dmg.sh` ad
hoc signs every nested executable (engine, process host, dylibs, frameworks)
inside-out and then the outer app with `codesign --force --sign -`, and verifies
the result with `codesign --verify --deep --strict`. It never uses a Developer
ID identity, `--options runtime`, `--timestamp`, Apple notarization, or `stapler`.

## First launch on an unnotarized build

Because the app is not notarized, macOS Gatekeeper blocks the first launch of a
downloaded copy. Open Gapless normally; if macOS reports it cannot be verified,
open **System Settings > Privacy & Security**, scroll to Security, click **Open
Anyway**, and confirm. This is a deliberate manual user action and is never
scripted by the release or the Homebrew cask. Each new version is a new download
and may require this approval again. The release never runs `spctl` as a success
gate and never clears quarantine or disables Gatekeeper.

## 0.1.0 release workflow

Before any candidate or tag run, configure protected `main` to require pull
requests, review approval, and required verification checks, and to block force
pushes and deletion. Also configure a `v*` tag ruleset that restricts tag
creation to release owners and blocks tag updates and deletions. These
protections make the reviewed `main` commit and every published release tag
immutable prerequisites rather than conventions.

In the repository settings, create the protected `macos-release` environment for
approval gating; it carries no Apple signing secrets. For its deployment rules,
set `Deployment branches and tags` to `Selected branches and tags`, then permit
only `main` and `v0.1.0` for this release. Require at least one reviewer and
enable `Prevent self-review`. These are mandatory prerequisites; a workflow file
cannot substitute for GitHub's environment enforcement.

The workflow has separate manual-candidate and tag entry points. Because the
build matrix uses `macos-release`, approval happens before the matrix builds. A
manual candidate runs only from `main` with version `0.1.0`; after this approval
it ad hoc signs, verifies, smoke-tests, and uploads its DMGs as Actions
artifacts, without creating or modifying a GitHub Release.

After the manual candidate has passed, create annotated tag `v0.1.0` from the
approved `main` commit and push it. The tag run starts its Apple Silicon and
Intel builds only when the tag commit still equals fetched `origin/main` and
after protected-environment approval. Publication refuses a tag that already has
a GitHub Release and never overwrites existing assets. The publication job also
uses `macos-release`. Publication remains protected and approval-gated.

## Release outputs

The approved `v0.1.0` tag run publishes separate Apple Silicon and Intel
`UNNOTARIZED` DMGs, `SHA256SUMS`, per-target SPDX SBOMs, the third-party
notices, the source offer, and this build guide.

## Homebrew installation

The supported install path is:

    brew install --cask navnit/gapless/gapless

The cask lives in the separate public tap `navnit/homebrew-gapless`. It installs
only assets already published by the canonical GitHub Release, verifies their
SHA-256 checksums, and never rebuilds Gapless. Because the build is unnotarized,
the first launch still requires the manual **Open Anyway** approval above.
