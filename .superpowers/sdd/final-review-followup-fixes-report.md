# Final review follow-up fixes report

## Scope

Resolved every finding in `.superpowers/sdd/final-rereview-findings.md` while
preserving the prior security remediation. The release remains version
`0.1.0+1`, with the same two macOS targets, action pins, secret names,
candidate isolation, and tag-only publication boundary. No GitHub settings
were configured, workflow was dispatched, tag was created or pushed, or GitHub
Release was created or modified.

## RED/GREEN evidence

### 1. Mandatory protected-environment deployment rules

Added workflow/documentation contracts requiring the `macos-release`
environment to document GitHub deployment rules for `Selected branches and
tags`, only `main` and `v0.1.0`, at least one reviewer, and `Prevent
self-review`.

RED: `flutter test test/tool/release/macos_release_workflow_test.dart
test/tool/release/verify_bundle_test.dart` failed because the guide did not
contain the mandatory deployment rules or the corrected approval timing.

GREEN: `docs/building.md` now makes those GitHub settings mandatory and
explicitly states that the workflow cannot enforce them itself. It also records
the intentionally documented alternative future policy of only `main` and
`v*`.

### 2. Distinct pre-sign and post-sign SBOM namespaces

Added an explicit required `--phase` identity for bundle SBOM generation. The
pre-sign embedded document uses `pre-sign-embedded`; the final external
document uses `post-sign-external`. A namespace is now
`https://gapless.invalid/spdx/<revision>/<target>/<phase>`.

RED: the focused test command failed with the new `phase` API absent, while the
workflow contracts also showed both phase arguments missing.

GREEN: the workflow passes both explicit phase values. External-SBOM
verification continues to require the final `post-sign-external` namespace and
retains exact regular-file coverage plus SHA-256 checks against both the signed
build app and the mounted-DMG app.

### 3. Correct approval timing

The guide now states that `macos-release` approval happens before
credential-bearing matrix builds and signing, because the build matrix itself
uses the protected environment. It separately states that publication also
uses that protected environment and remains approval-gated.

## Verification

- `dart format --output=none --set-exit-if-changed lib test integration_test tool` — 91 files, 0 changed.
- `flutter test test/tool/release` — 26 passed.
- `flutter analyze` — no issues found.
- `flutter test` — 353 passed; 2 intentional Windows-runtime skips.
- `ruby -e "require 'yaml'; YAML.load_file('.github/workflows/release-macos.yml')"` — passed.
- Parsed every `run:` command in `.github/workflows/release-macos.yml`, replaced Actions expressions with inert values, and passed each to `bash -n` — passed.
- `bash -n script/build_and_run.sh tool/testing/build_and_run_test.sh packaging/macos/package_dmg.sh` — passed.
- `bash tool/testing/build_and_run_test.sh` — `build_and_run_test: PASS`.
- `git diff --check` — no whitespace errors.
- Scope audit — `pubspec.yaml` remains `0.1.0+1`; the matrix remains exactly `macos-arm64`/`macos-14` and `macos-x64`/`macos-15-intel`; action pins, all seven secret names, and `overwrite_files: false` are unchanged.

## Self-review

Reviewed the final diff against all three findings. Documentation contracts now
cover every mandatory GitHub environment prerequisite without claiming to
configure remote settings. SBOM document identities cannot collide across the
two signing phases for one revision/target, and external verification is
strictly tied to the post-sign document without weakening integrity checks.
The guide's approval sequence matches the protected-environment placement in
both build and publication jobs. No unrelated release behavior was changed.

## Commit

Committed locally with the concise scoped message
`fix: close macOS release review gaps`. The branch was not pushed.
