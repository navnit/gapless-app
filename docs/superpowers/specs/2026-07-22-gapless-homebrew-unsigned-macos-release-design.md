# Gapless unsigned macOS and Homebrew release design

**Date:** 2026-07-22
**Status:** Approved for implementation planning

## Objective

Make Gapless installable on Apple Silicon and Intel Macs with one Homebrew
command, without requiring an Apple Developer Program membership. GitHub
Releases remains the canonical source for versioned binaries, checksums,
compliance material, and source code.

The supported installation command is:

```sh
brew install --cask navnit/gapless/gapless
```

This command installs the app. Because the release is not signed with a
Developer ID certificate or notarized by Apple, the user's first launch still
requires an explicit approval in **System Settings > Privacy & Security > Open
Anyway**.

## Scope

### Included

- Public, architecture-specific macOS DMGs built by GitHub Actions.
- Ad hoc signing of all nested executable code and the outer app so macOS can
  validate bundle integrity without asserting a developer identity.
- Explicit `UNNOTARIZED` artifact naming and release documentation.
- SHA-256 checksums, SPDX SBOMs, third-party notices, source offer, and build
  instructions alongside each release.
- A separate public `navnit/homebrew-gapless` tap containing a `gapless` cask.
- One-command installation, upgrade, and removal through Homebrew.
- Automated validation of release artifacts and the Homebrew cask.

### Excluded

- Apple Developer ID signing, notarization, stapling, or Mac App Store
  distribution.
- Clearing quarantine attributes or disabling Gatekeeper automatically.
- pip, uv, npm, or pub.dev wrappers for the Flutter desktop application.
- Automatic in-app updates in version 0.1.0.
- Homebrew Core or the central `homebrew/cask` repository for the initial
  release.

## Architecture

### Gapless repository

The existing `.github/workflows/release-macos.yml` workflow remains the only
producer of release artifacts. It builds and verifies two targets:

- `macos-arm64` on `macos-14`
- `macos-x64` on `macos-15-intel`

The workflow publishes these immutable assets for version `X.Y.Z`:

- `Gapless-X.Y.Z-macos-arm64-UNNOTARIZED.dmg`
- `Gapless-X.Y.Z-macos-x64-UNNOTARIZED.dmg`
- `SHA256SUMS`
- one SPDX SBOM per architecture
- `building.md`
- `THIRD_PARTY_NOTICES.md`
- `SOURCE_OFFER.md`

`THIRD_PARTY_NOTICES.md` and `SOURCE_OFFER.md` are published as release assets
and are also copied into `Gapless.app/Contents/Resources/compliance` so the
compliance material travels with an installed, offline app.

The 0.1.0 release workflow is unsigned-only. The signing- and
notarization-secret validation, keychain import, and notarize/staple steps are
removed outright, and the `macos-release` environment no longer defines any
`MACOS_*` secret, so the workflow contains no reference to Apple credentials. If
signed and notarized publishing returns later, it is re-added fresh as a
separate release mode rather than left dormant behind a flag.

Its packaging path ad hoc signs executable components from the inside out with
`codesign --force --sign -`, deliberately omitting the `--options runtime` and
`--timestamp` flags, which apply only to Developer ID signing and notarization.
It then verifies the final app with `codesign --verify --deep --strict`, creates
the DMG, mounts it, runs the installed smoke test, and verifies the mounted
bundle. It does not run `spctl` as a success gate because Gatekeeper is expected
to reject an unnotarized downloaded application.

The release description must state that the artifacts are unnotarized, link to
the public source and checksums, and provide Apple's current **Open Anyway**
steps. It must not imply that the application has been reviewed by Apple.

### Homebrew tap repository

The public repository `navnit/homebrew-gapless` represents the Homebrew tap
named `navnit/gapless`. It contains:

```text
Casks/gapless.rb
README.md
```

The cask declares version `X.Y.Z`, architecture-specific SHA-256 values, and
architecture-specific GitHub Release URLs. Its only application artifact is
`Gapless.app`. It includes concise caveats explaining the unnotarized status
and the first-launch approval path.

The tap never rebuilds Gapless and never downloads an unversioned or mutable
artifact. It installs only assets already published by the canonical Gapless
GitHub Release.

## Release and update flow

1. Update `pubspec.yaml` to the intended semantic version and merge the reviewed
   release changes to `main`.
2. Tag the exact `main` commit as `vX.Y.Z`.
3. The macOS release workflow builds, ad hoc signs, verifies, smoke-tests, and
   publishes both DMGs and their supporting files.
4. After the GitHub Release succeeds, update `Casks/gapless.rb` with the same
   version and the two checksums from `SHA256SUMS`.
5. Validate the cask and merge the tap update.
6. Users install or upgrade with Homebrew. Homebrew selects the correct DMG for
   the current CPU architecture.

The tap update must never precede a successful, public GitHub Release. This
prevents the cask from referencing missing or replaceable files.

## User experience

### Install

```sh
brew install --cask navnit/gapless/gapless
```

Homebrew downloads the matching DMG, verifies its SHA-256 checksum, and installs
`Gapless.app` in Applications.

### First launch

The user attempts to open Gapless normally. If macOS blocks it, the user opens
**System Settings > Privacy & Security**, scrolls to Security, clicks **Open
Anyway**, and confirms. This approval is a deliberate user action and is never
scripted by the cask.

### Upgrade and uninstall

```sh
brew upgrade --cask gapless
brew uninstall --cask gapless
```

Each new unnotarized version may require first-launch approval again because it
is a new downloaded artifact.

## Failure handling

- Missing or partially configured Apple secrets cannot block the workflow,
  because the unsigned-only workflow no longer defines or references them.
- Packaging stops before publication if ad hoc signing, bundle verification,
  mounted smoke testing, SBOM generation, or checksum generation fails.
- The workflow refuses to overwrite an existing GitHub Release for the tag.
- The cask fails closed when an artifact checksum differs from its declared
  SHA-256 value.
- The tap is not updated when either architecture is absent or fails its release
  gates.
- User-facing documentation distinguishes an expected Gatekeeper warning from a
  damaged bundle, failed checksum, or application runtime error.
- Release scripts do not run `xattr`, `spctl --master-disable`, or any equivalent
  Gatekeeper bypass.

## Verification

### Gapless repository

- Contract tests cover the unsigned packaging path and prove that release and
  pull-request workflows do not reference Apple signing secrets.
- Shell syntax and static analysis pass for packaging scripts.
- Both architecture jobs run Flutter analysis and tests, engine verification,
  bundle verification, mounted-DMG smoke testing, native editor/recovery tests,
  SBOM generation, and checksum generation.
- Tests assert that unsigned artifact names contain `UNNOTARIZED` and that the
  published release notes contain the security disclosure and approval steps.
- The release workflow remains tag-bound to the reviewed `main` revision.

### Homebrew tap

- `brew audit --cask --strict gapless` passes within the tap's supported policy.
- `brew style --cask gapless` passes.
- Automated tests verify that both architecture URLs exist and match their
  declared checksums.
- A macOS smoke job installs the cask, verifies that `Gapless.app` exists, and
  uninstalls it. Gatekeeper approval is documented rather than automated.

## Security and trust statement

The GitHub Release, its checksums, and reproducible build instructions form the
trust anchor for the zero-cost release. Homebrew improves discovery,
architecture selection, checksum enforcement, upgrades, and removal; it does
not replace Developer ID signing or Apple notarization.

If a trusted project organization later obtains an eligible Apple fee waiver or
a Developer ID certificate, signed and notarized publishing can be introduced
as a separate release mode without changing the Homebrew command or artifact
ownership model.

## Acceptance criteria

- A new Mac user can install the correct Gapless build with
  `brew install --cask navnit/gapless/gapless`.
- No Apple Developer Program credentials are required to build or publish the
  release.
- Every downloadable binary is versioned, immutable, checksummed, and linked to
  public source and compliance material.
- The expected Gatekeeper limitation and manual approval are clearly disclosed
  before installation and in the GitHub Release.
- CI proves both architecture artifacts and the cask before they are presented
  as releasable.
