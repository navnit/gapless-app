# Gapless unsigned macOS + Homebrew release — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert the macOS 0.1.0 release from Developer-ID-signed + notarized to ad hoc signed / `UNNOTARIZED`, remove all Apple signing infrastructure, and publish a Homebrew cask in a separate tap.

**Architecture:** The existing `release-macos.yml` workflow and `package_dmg.sh` stay the sole producers of release artifacts, but stop referencing Apple credentials. Packaging ad hoc signs (`codesign --sign -`) inside-out, names artifacts `…-UNNOTARIZED.dmg`, and drops `spctl` as a gate. A separate public repo `navnit/homebrew-gapless` carries a cask that installs the already-published DMGs. The repo's contract tests (which currently *assert* signing) are inverted first, TDD-style, so the tests define the new behavior before the workflow/script/docs change.

**Tech Stack:** GitHub Actions, `codesign`/`hdiutil` (macOS), Dart/Flutter (`flutter test` for contract tests + `tool/release/*.dart`), Homebrew cask (Ruby).

## Global Constraints

- Supported install command, verbatim: `brew install --cask navnit/gapless/gapless`
- Two targets only: `macos-arm64` on `macos-14`, `macos-x64` on `macos-15-intel`
- Artifact names MUST contain `UNNOTARIZED`, e.g. `Gapless-0.1.0-macos-arm64-UNNOTARIZED.dmg`
- Ad hoc identity is the literal `-`; NEVER use `--options runtime`, `--timestamp`, `notarytool`, or `stapler`
- The workflow MUST contain no `MACOS_` and no `secrets.` reference (approval-only `macos-release` environment stays; its Apple secrets are removed)
- NEVER run `xattr`, `spctl --master-disable`, or `spctl --assess` as a success gate
- SBOM phase strings stay `pre-sign-embedded` / `post-sign-external` — they are opaque stage labels coupled to the namespace regex in `tool/release/verify_bundle.dart`; renaming them is out of scope
- Publish `SOURCE_OFFER.md` as a release asset AND keep it copied into `Gapless.app/Contents/Resources/compliance`
- The tap update MUST never precede a successful public GitHub Release
- pubspec version stays `0.1.0+1`; do not bump in this work

---

## Part A — Gapless repository (this worktree, fully testable now)

Run all Dart tests with `flutter test`. A single test file: `flutter test test/tool/release/<file>.dart`.

### Task 1: Ad hoc packaging script + its contract test

**Files:**
- Modify: `test/tool/release/macos_packaging_test.dart` (full rewrite, 30 lines)
- Modify: `packaging/macos/package_dmg.sh`

**Interfaces:**
- Produces: `package_dmg.sh <Gapless.app> <OUTPUT.dmg>` — unchanged 2-arg signature; no longer reads `GAPLESS_MACOS_SIGN_IDENTITY` or `GAPLESS_NOTARY_PROFILE`.

- [ ] **Step 1: Rewrite the packaging contract test (RED).** Replace the entire body of `test/tool/release/macos_packaging_test.dart` (keep the `import 'dart:io';` and `import 'package:flutter_test/flutter_test.dart';` header) with:

```dart
void main() {
  test('ad hoc signs nested frameworks before the outer macOS app', () async {
    final script = await File('packaging/macos/package_dmg.sh').readAsString();

    final frameworkSigning = script.indexOf(r'find "$app/Contents/Frameworks"');
    final appSigning = script.indexOf(r'codesign --force --sign - "$app"');

    expect(frameworkSigning, greaterThanOrEqualTo(0));
    expect(script, contains("-name '*.framework'"));
    expect(frameworkSigning, lessThan(appSigning));
    expect(script, contains(r'codesign --verify --deep --strict'));
  });

  test('uses the ad hoc identity and no Developer ID / notarization', () async {
    final script = await File('packaging/macos/package_dmg.sh').readAsString();

    expect(script, contains('codesign --force --sign - '));
    for (final forbidden in <String>[
      '--options runtime',
      '--timestamp',
      'GAPLESS_MACOS_SIGN_IDENTITY',
      'GAPLESS_NOTARY_PROFILE',
      'notarytool',
      'stapler',
    ]) {
      expect(script, isNot(contains(forbidden)), reason: forbidden);
    }
  });
}
```

- [ ] **Step 2: Run the test, verify it fails.** Run: `flutter test test/tool/release/macos_packaging_test.dart`. Expected: FAIL (script still contains `--options runtime`, `notarytool`, etc.).

- [ ] **Step 3: Rewrite `packaging/macos/package_dmg.sh`.** Replace the entire file with:

```sh
#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
  echo "usage: $0 Gapless.app OUTPUT.dmg" >&2
  exit 64
fi

app=$(CDPATH='' cd -- "$(dirname -- "$1")" && pwd)/$(basename -- "$1")
output=$(CDPATH='' cd -- "$(dirname -- "$2")" && pwd)/$(basename -- "$2")
repo=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
mkdir -p "$app/Contents/Resources/compliance"
cp "$repo/third_party/THIRD_PARTY_NOTICES.md" "$app/Contents/Resources/compliance/"
cp "$repo/third_party/SOURCE_OFFER.md" "$app/Contents/Resources/compliance/"
codesign --force --sign - "$app/Contents/Resources/engine/auto-editor"
case "$(uname -m)" in
  arm64) engine_target=macos-arm64 ;;
  x86_64) engine_target=macos-x64 ;;
  *) echo "unsupported macOS architecture" >&2; exit 1 ;;
esac
(cd "$repo" && dart run tool/release/stamp_installed_engine.dart --bundle "$app" --target "$engine_target")
codesign --force --sign - "$app/Contents/Resources/gapless_process_host"
find "$app/Contents/Frameworks" -type f -name '*.dylib' \
  -exec codesign --force --sign - {} \;
find "$app/Contents/Frameworks" -depth -type d -name '*.framework' \
  -exec codesign --force --sign - {} \;
codesign --force --sign - "$app"
codesign --verify --deep --strict --verbose=2 "$app"
(cd "$repo" && dart run tool/release/verify_bundle.dart --bundle "$app" --target "$engine_target")
hdiutil create -volname Gapless -srcfolder "$app" -ov -format UDZO "$output"
```

(Changes vs. current: dropped the `identity` var; every `codesign … --sign "$identity"` → `codesign --force --sign -`; removed `--options runtime --timestamp`; removed the DMG-signing line; removed the entire `GAPLESS_NOTARY_PROFILE` notarize/staple block. Inside-out order and `codesign --verify --deep --strict` preserved.)

- [ ] **Step 4: Run the test, verify it passes.** Run: `flutter test test/tool/release/macos_packaging_test.dart`. Expected: PASS.

- [ ] **Step 5: Lint the shell script.** Run: `shellcheck packaging/macos/package_dmg.sh` (if installed) and `sh -n packaging/macos/package_dmg.sh`. Expected: no errors.

- [ ] **Step 6: Commit.**

```bash
git add packaging/macos/package_dmg.sh test/tool/release/macos_packaging_test.dart
git commit -m "feat: ad hoc sign macOS packaging without Developer ID or notarization"
```

### Task 2: Unsigned/`UNNOTARIZED` release workflow, its contract test, and build docs

This is one deliverable: `macos_release_workflow_test.dart` gates both `release-macos.yml` and `docs/building.md`, so all three change together.

**Files:**
- Modify: `test/tool/release/macos_release_workflow_test.dart`
- Modify: `.github/workflows/release-macos.yml`
- Modify: `docs/building.md` (full rewrite)

- [ ] **Step 1: Invert the workflow contract test (RED).** In `test/tool/release/macos_release_workflow_test.dart`:

  Delete the `macosReleaseSecrets` const list (lines 6–14).

  In `'validates version before engine and signing work'`: remove the assertion ordering against `'Import Apple signing and notarization credentials'` (that step is deleted); change the DMG-name assertion to require the `-UNNOTARIZED` suffix:

```dart
    expect(
      workflow,
      contains(
        r'Gapless-${{ steps.version.outputs.value }}-'
        r'${{ matrix.target }}-UNNOTARIZED.dmg',
      ),
    );
```

  In `'keeps hostile manual version input out of the shell program'`: change the substring end-anchor from `'      - name: Validate signing and notarization secrets'` to `'      - name: Ad hoc sign and package DMG'` (both occurrences).

  In `'signs only main dispatches or tags at the fetched main commit'`: rename it and re-anchor to a surviving step. Replace the `secretValidation` anchor with the Flutter-action step:

```dart
  test('builds only main dispatches or tags at the fetched main commit', () {
    final refValidation = workflow.indexOf(
      '      - name: Require reviewed main revision',
    );
    final flutterSetup = workflow.indexOf('subosito/flutter-action@');

    expect(refValidation, greaterThanOrEqualTo(0));
    expect(refValidation, lessThan(flutterSetup));
    expect(workflow, contains(r'[ "$GITHUB_REF" = refs/heads/main ]'));
    expect(
      workflow,
      contains('git fetch --no-tags origin main:refs/remotes/origin/main'),
    );
    expect(workflow, contains(r'main_sha=$(git rev-parse origin/main^{commit})'));
    expect(
      workflow,
      contains(r'release_sha=$(git rev-parse "$GITHUB_SHA^{commit}")'),
    );
    expect(workflow, contains(r'[ "$release_sha" = "$main_sha" ]'));
  });
```

  Replace `'requires installed-artifact proof before upload'` with a version that asserts the *unsigned* contract and the *absence* of all Apple credentials:

```dart
  test('proves an unsigned, credential-free installed-artifact path', () {
    for (final required in <String>[
      'package_dmg.sh',
      '--smoke-test',
      'verify_bundle.dart',
      'integration_test/editor_workflow_test.dart',
      'integration_test/recovery_workflow_test.dart',
      'actions/upload-artifact',
      '-UNNOTARIZED.dmg',
    ]) {
      expect(workflow, contains(required), reason: required);
    }
    for (final forbidden in <String>[
      'MACOS_',
      'secrets.',
      'notarytool',
      'stapler',
      'spctl --assess',
      'spctl --master-disable',
      'xattr',
    ]) {
      expect(workflow, isNot(contains(forbidden)), reason: forbidden);
    }
  });
```

  In `'protects every credential-bearing build with macos-release'`: keep it (the environment stays for approval gating) but rename to `'gates every build behind the macos-release approval environment'`. The three `expect` bodies are unchanged.

  In `'generates and verifies each public SBOM …'`: change the step-name anchor `'      - name: Generate and verify final signed-app SBOM'` → `'      - name: Generate and verify final app SBOM'`. Keep the `--phase pre-sign-embedded` and `--phase post-sign-external` assertions verbatim.

  Rewrite the three `docs/building.md` tests as a single test matching the new doc (see Step 3 for the exact strings it must contain):

```dart
  test('documents the public unnotarized macOS 0.1.0 download', () {
    final readme = File('README.md').readAsStringSync();
    final building = File('docs/building.md').readAsStringSync();

    expect(readme, contains('Gapless 0.1.0'));
    expect(readme, contains('https://github.com/navnit/gapless/releases/latest'));
    expect(readme, contains('Windows and Linux remain planned targets'));

    for (final phrase in <String>[
      'first public release target',
      'Ubuntu 24.04/glibc 2.39 baseline',
      'v0.1.0',
      'macos-release',
      'ad hoc',
      'UNNOTARIZED',
      'not notarized',
      'Open Anyway',
      'brew install --cask navnit/gapless/gapless',
      'Public downloads become available only after the protected tag '
          'workflow succeeds and approval completes.',
      'https://github.com/navnit/gapless/releases/latest',
      'protected `main`',
      '`v*` tag ruleset',
      'blocks tag updates and deletions',
      'Require at least one reviewer',
      'enable `Prevent self-review`',
    ]) {
      expect(building, contains(phrase), reason: phrase);
    }
    for (final forbidden in <String>[
      'MACOS_P12_BASE64',
      'MACOS_SIGN_IDENTITY',
      'notarytool',
      'macos-release environment secrets',
    ]) {
      expect(building, isNot(contains(forbidden)), reason: forbidden);
    }
  });
```

  Add a new test asserting the GitHub Release description carries the security disclosure (the testable proxy for the spec's "published release notes contain the security disclosure and approval steps"):

```dart
  test('publishes the unnotarized security disclosure in the release notes', () {
    final publish = workflow.substring(workflow.indexOf('  publish:'));
    for (final phrase in <String>[
      'body: |',
      'UNNOTARIZED',
      'not notarized by Apple',
      'not been reviewed by Apple',
      'Open Anyway',
      'SHA256SUMS',
    ]) {
      expect(publish, contains(phrase), reason: phrase);
    }
    expect(publish, contains('generate_release_notes: true'));
  });
```

  Delete the now-superseded tests `'documents mandatory protected-environment deployment rules'` and `'documents approval before credential-bearing builds and signing'` (their surviving assertions are folded into the test above / the doc no longer says "signing").

- [ ] **Step 2: Run the test, verify it fails.** Run: `flutter test test/tool/release/macos_release_workflow_test.dart`. Expected: FAIL (workflow still has secrets, no `-UNNOTARIZED`, etc.).

- [ ] **Step 3: Rewrite `docs/building.md`.** Replace the `## Signing`, `## 0.1.0 release workflow`, and `## Release outputs` sections and the intro paragraph so the file reads (keep `## Reproducible inputs` and `## Native bundle layouts` unchanged):

  Intro paragraph (replace lines 3–7):

```markdown
Gapless 0.1.0 is the first public release target, for macOS 12+ Apple Silicon
and Intel DMGs. The 0.1.0 build is ad hoc signed but is **not** signed with an
Apple Developer ID and is **not notarized** by Apple, so its artifacts are named
with an explicit `UNNOTARIZED` marker. Public downloads become available only
after the protected tag workflow succeeds and approval completes.
After that success, download assets from the [latest GitHub Release](https://github.com/navnit/gapless/releases/latest).
Windows 10+ x64 and Linux x64 remain planned targets; the Linux target uses an
Ubuntu 24.04/glibc 2.39 baseline.
```

  Replace `## Signing` with:

```markdown
## Ad hoc signing (no Apple Developer ID)

The 0.1.0 macOS release requires no Apple Developer Program membership and no
repository or environment signing secrets. `packaging/macos/package_dmg.sh` ad
hoc signs every nested executable (engine, process host, dylibs, frameworks)
inside-out and then the outer app with `codesign --force --sign -`, and verifies
the result with `codesign --verify --deep --strict`. It never uses a Developer
ID identity, `--options runtime`, `--timestamp`, `notarytool`, or `stapler`.

## First launch on an unnotarized build

Because the app is not notarized, macOS Gatekeeper blocks the first launch of a
downloaded copy. Open Gapless normally; if macOS reports it cannot be verified,
open **System Settings > Privacy & Security**, scroll to Security, click **Open
Anyway**, and confirm. This is a deliberate manual user action and is never
scripted by the release or the Homebrew cask. Each new version is a new download
and may require this approval again. The release never runs `spctl` as a success
gate and never clears quarantine or disables Gatekeeper.
```

  Replace the `## 0.1.0 release workflow` section so the `macos-release` environment is described as approval-only (drop the "add the seven environment secrets" sentence and every mention of signing/notarizing):

```markdown
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
```

  Replace `## Release outputs` with:

```markdown
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
```

- [ ] **Step 4: Edit `.github/workflows/release-macos.yml`.** Apply these edits:
  - Delete the step `- name: Validate signing and notarization secrets` and its `env:`/`run:` block (current lines 66–82).
  - Delete the step `- name: Import Apple signing and notarization credentials` and its block (current lines 92–109).
  - Replace the `- name: Sign, notarize, and package DMG` step (110–114) with:

```yaml
      - name: Ad hoc sign and package DMG
        run: packaging/macos/package_dmg.sh build/macos/Build/Products/Release/Gapless.app "build/Gapless-${{ steps.version.outputs.value }}-${{ matrix.target }}-UNNOTARIZED.dmg"
```

  - Rename the SBOM step `- name: Generate and verify final signed-app SBOM` → `- name: Generate and verify final app SBOM` (keep its `run:` body, including `--phase post-sign-external`, unchanged).
  - In `- name: Smoke test installed macOS DMG`: change the `dmg=` line to the `-UNNOTARIZED` name and delete the `spctl --assess --type execute --verbose=4 "$mount/Gapless.app"` line:

```yaml
      - name: Smoke test installed macOS DMG
        run: |
          dmg="build/Gapless-${{ steps.version.outputs.value }}-${{ matrix.target }}-UNNOTARIZED.dmg"
          mount="$RUNNER_TEMP/gapless-mounted"
          mkdir -p "$mount"
          hdiutil attach "$dmg" -nobrowse -mountpoint "$mount"
          trap 'hdiutil detach "$mount"' EXIT
          "$mount/Gapless.app/Contents/MacOS/Gapless" --smoke-test "$GITHUB_WORKSPACE/build/smoke/source.avi" "$RUNNER_TEMP/installed-output.mp4"
          dart run tool/release/verify_bundle.dart --bundle "$mount/Gapless.app" --target "${{ matrix.target }}" --sbom "$GITHUB_WORKSPACE/build/sbom-${{ matrix.target }}.spdx.json"
```

  - In `- name: Checksums and source material`: use the `-UNNOTARIZED` name and copy `SOURCE_OFFER.md`:

```yaml
      - name: Checksums and source material
        run: |
          cd build
          shasum -a 256 "Gapless-${{ steps.version.outputs.value }}-${{ matrix.target }}-UNNOTARIZED.dmg" > "SHA256SUMS-${{ matrix.target }}"
          cp ../docs/building.md .
          cp ../third_party/THIRD_PARTY_NOTICES.md .
          cp ../third_party/SOURCE_OFFER.md .
```

  - In the `upload-artifact` `path:` list, use the `-UNNOTARIZED` DMG name and add `build/SOURCE_OFFER.md`:

```yaml
          path: |
            build/Gapless-${{ steps.version.outputs.value }}-${{ matrix.target }}-UNNOTARIZED.dmg
            build/SHA256SUMS-${{ matrix.target }}
            build/building.md
            build/THIRD_PARTY_NOTICES.md
            build/SOURCE_OFFER.md
            build/sbom-${{ matrix.target }}.spdx.json
```

  - In the `publish:` job's `- name: Publish public GitHub Release` step, add an inline `body:` disclosure. The `publish:` job has no `actions/checkout`, so the disclosure lives inline in the workflow rather than a repo file; `softprops/action-gh-release` appends the auto-generated notes after `body`. Keep the existing `with:` keys and add `body:`:

```yaml
        with:
          tag_name: ${{ github.ref_name }}
          name: Gapless ${{ github.ref_name }}
          generate_release_notes: true
          overwrite_files: false
          body: |
            ## Unnotarized macOS build — read before installing

            These macOS DMGs are ad hoc signed but **not notarized by Apple** and
            have **not been reviewed by Apple**. Artifacts are marked `UNNOTARIZED`.

            On first launch macOS Gatekeeper will block the app. To open it, go to
            **System Settings > Privacy & Security**, scroll to Security, and click
            **Open Anyway**, then confirm. Each new version may require this again.

            Verify your download against `SHA256SUMS`. Build instructions
            (`building.md`), third-party notices, and the source offer are attached
            to this release; source code is at https://github.com/navnit/gapless.
          files: artifacts/*
```

- [ ] **Step 5: Run the workflow contract test, verify it passes.** Run: `flutter test test/tool/release/macos_release_workflow_test.dart`. Expected: PASS.

- [ ] **Step 6: Run the full release-tooling suite.** Run: `flutter test test/tool/release/`. Expected: PASS (including `verify_bundle_test.dart` and `validate_release_version_test.dart`, which are untouched).

- [ ] **Step 7: Commit.**

```bash
git add .github/workflows/release-macos.yml docs/building.md test/tool/release/macos_release_workflow_test.dart
git commit -m "feat: publish unsigned UNNOTARIZED macOS release without Apple secrets"
```

### Task 3: CI guard proving the release workflow references no Apple secrets

**Files:**
- Modify: `.github/workflows/verify.yml`

- [ ] **Step 1: Add a workflow-safety step for the release workflow.** In the `workflow-safety` job, after the existing `Ensure PR workflow has no signing secrets` step, add:

```yaml
      - name: Ensure the macOS release workflow references no Apple secrets
        run: '! grep -R -E "MACOS_|secrets\." .github/workflows/release-macos.yml'
```

  (grep returns 0 if either pattern matches, so `!` makes the step fail on any match. After Task 2 the release workflow uses only `github.token`/`inputs`/`matrix`/`steps` expansions — no `secrets.`.)

- [ ] **Step 2: Verify the guard locally.** Run: `grep -R -E "MACOS_|secrets\." .github/workflows/release-macos.yml; echo "exit=$?"`. Expected: no output and `exit=1` (no matches). If it prints matches, Task 2 left a reference behind — fix it before continuing.

- [ ] **Step 3: Commit.**

```bash
git add .github/workflows/verify.yml
git commit -m "test: assert the macOS release workflow carries no Apple secrets"
```

### Task 4: Repo-wide verification and format

- [ ] **Step 1: Format check.** Run: `dart format --output=none --set-exit-if-changed lib test integration_test tool`. Expected: PASS. If it fails, run `dart format lib test integration_test tool` and re-commit.
- [ ] **Step 2: Analyze.** Run: `flutter analyze`. Expected: no issues.
- [ ] **Step 3: Full test suite.** Run: `flutter test`. Expected: PASS.
- [ ] **Step 4: Grep for stragglers.** Run: `grep -R -nE "notarytool|stapler|spctl --assess|MACOS_" .github packaging docs/building.md`. Expected: no matches. (The design spec and this plan legitimately mention them; scope the grep to shipping files only.)
- [ ] **Step 5: Commit any format fixes** if Step 1 produced them.

> **Manual (repository settings, not code):** in GitHub, delete the seven `MACOS_*` secrets from the `macos-release` environment. The CI guard proves the workflow no longer *references* them, but only a human with repo admin can remove the stored secret values.

---

## Part B — Homebrew tap `navnit/homebrew-gapless` (separate repo, post-release runbook)

This part is **not** implementable or testable inside this worktree: it is a different public repository, and the cask needs the real SHA-256 values that exist only after the GitHub Release publishes. Execute it **after** the `v0.1.0` tag run succeeds and the Release is public. `brew audit`/`brew style` run in that repo's CI, not here.

### B1. Create the tap repository

- [ ] Create public repo `navnit/homebrew-gapless` with this layout:

```text
Casks/gapless.rb
README.md
.github/workflows/ci.yml
```

### B2. `Casks/gapless.rb`

- [ ] After the release, read the two checksums from the Release's `SHA256SUMS`, then write `Casks/gapless.rb`. Replace `ARM64_SHA256` / `X64_SHA256` with the real values:

```ruby
cask "gapless" do
  arch arm: "arm64", intel: "x64"

  version "0.1.0"

  on_arm do
    sha256 "ARM64_SHA256"
  end
  on_intel do
    sha256 "X64_SHA256"
  end

  url "https://github.com/navnit/gapless/releases/download/v#{version}/Gapless-#{version}-macos-#{arch}-UNNOTARIZED.dmg",
      verified: "github.com/navnit/gapless/"
  name "Gapless"
  desc "Gapless desktop video editor"
  homepage "https://github.com/navnit/gapless"

  livecheck do
    url "https://github.com/navnit/gapless/releases/latest"
    strategy :github_latest
  end

  app "Gapless.app"

  caveats <<~EOS
    Gapless #{version} is ad hoc signed but not notarized by Apple. On first
    launch macOS will block it. To open it, go to
    System Settings > Privacy & Security, scroll to Security, and click
    "Open Anyway", then confirm. Each new version may require this again.
  EOS
end
```

  Notes: `arch arm:/intel:` + `on_arm`/`on_intel` give per-architecture URL and checksum from one cask; `#{arch}` expands to `arm64`/`x64` to match the artifact names. Do NOT add `quarantine: false` — leaving the default quarantine on is what makes the documented Gatekeeper approval the user's deliberate action.

### B3. `README.md`

- [ ] Write a README documenting install/upgrade/uninstall and the unnotarized first-launch approval:

```markdown
# Gapless Homebrew tap

    brew install --cask navnit/gapless/gapless

Installs the latest published [Gapless](https://github.com/navnit/gapless)
macOS build (Apple Silicon or Intel, selected automatically) and verifies its
SHA-256 checksum.

Gapless is ad hoc signed but **not notarized**. On first launch, open
**System Settings > Privacy & Security**, scroll to Security, and click
**Open Anyway**. This tap never scripts that approval, clears quarantine, or
disables Gatekeeper.

    brew upgrade --cask gapless
    brew uninstall --cask gapless
```

### B4. Tap CI `.github/workflows/ci.yml`

- [ ] Add CI that audits/styles the cask and runs a macOS install/uninstall smoke:

```yaml
name: cask
on:
  pull_request:
  push:
    branches: [main]
jobs:
  audit:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - run: brew style --cask Casks/gapless.rb
      - run: brew audit --cask --strict --online Casks/gapless.rb
  install:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - run: brew install --cask "$PWD/Casks/gapless.rb"
      - run: test -d "/Applications/Gapless.app"
      - run: brew uninstall --cask "$PWD/Casks/gapless.rb"
```

  Gatekeeper approval is **documented, not automated** — the install job verifies the app is placed and removable, never that it launches unblocked.

### B5. Release-time procedure (every version, in order)

- [ ] 1. Land release changes on `main`; ensure `pubspec.yaml` version is correct.
- [ ] 2. Tag the reviewed `main` commit `vX.Y.Z`; the macOS workflow builds, ad hoc signs, verifies, smoke-tests, and publishes both `UNNOTARIZED` DMGs + `SHA256SUMS`.
- [ ] 3. **Only after** the public Release exists: update `Casks/gapless.rb` `version` and both `sha256` values from `SHA256SUMS`.
- [ ] 4. Open the tap PR; let `brew audit`/`brew style`/install-smoke pass; merge.
- [ ] 5. `brew upgrade --cask gapless` now serves the new version. The tap update MUST never precede a successful public Release.

---

## Self-review checklist (completed at authoring)

- **Spec coverage:** Objective/UX → Tasks 2, B2–B3; ad hoc signing → Task 1; `UNNOTARIZED` naming → Tasks 1–2; no Apple secrets → Tasks 2–3 + manual settings note; SOURCE_OFFER as asset + in-bundle → Task 1 (bundle) + Task 2 (asset); **GitHub Release description disclosure + Open Anyway steps (Architecture/Verification/Acceptance) → Task 2 Step 4 inline `body:` + the disclosure contract test in Task 2 Step 1**; tap/cask/one-command install → Part B; failure handling (`spctl` not a gate, refuse existing Release, checksum fail-closed) → Task 2 keeps the publish preflight + cask checksum; verification (contract tests, `brew audit`/`style`) → Tasks 1–3 + B4.
- **Placeholders:** the only intentional placeholders are `ARM64_SHA256`/`X64_SHA256` in B2, which cannot exist until the real release publishes — explicitly flagged.
- **Type/name consistency:** DMG name `Gapless-<version>-macos-<arch>-UNNOTARIZED.dmg` is identical across `package_dmg.sh` (Task 1), the workflow (Task 2), the contract test (Task 2), and the cask `url` (B2). SBOM phase strings `pre-sign-embedded`/`post-sign-external` left untouched to match `verify_bundle.dart`.

## Open item for the reviewer

`macos-15-intel` is used as the Intel runner label (pre-existing in the current workflow, not introduced here). Confirm this label resolves to a real GitHub-hosted Intel runner before the first tag run — if it does not, the x64 DMG never builds and the cask's `on_intel` branch has nothing to point at. The conventional free Intel label is `macos-13`.
