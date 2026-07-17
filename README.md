# Gapless

Gapless is a free and open-source desktop interface for
[Auto-Editor](https://github.com/WyattBlue/auto-editor). It is focused on one
beginner-friendly job: find inactive parts of a local video, review the
suggested cuts, and export a tighter MP4.

## Project status

Gapless is an early MVP under active development. The repository contains
source and test contracts for the editor workflow, but it does not yet publish
packaged releases. Full Flutter verification and installed native workflows
remain pending; do not treat the current checkout as release-validated.

The intended desktop targets are:

- macOS 12 or later on Apple silicon and Intel;
- Windows 10 or later on x64;
- Linux x64, eventually packaged as an AppImage.

Windows and Linux release validation has not been completed.

## Focused v1 scope

- Open exactly one local video per project.
- Review detected segments on a simple timeline and toggle keep/remove.
- Autosave edits in a local `.gapless` project and support Save As.
- Export MP4 only.
- Keep source media read-only. Rendering uses operation-owned temporary output
  before promotion to the user-approved destination.
- Work offline at runtime once the pinned processing engine is present.

Gapless does not upload media, require an account, or provide cloud services.

## Architecture and bundled-engine intent

- Flutter desktop interface.
- `media_kit`/libmpv playback.
- Auto-Editor 31.2.0 pinned by version and SHA-256 in the
  [engine manifest](assets/engine/manifest.json).
- A bundled-engine release model so installed editing does not depend on a
  system Python or Auto-Editor installation.

The engine acquisition step uses the network during development or packaging;
the editing workflow is intended to remain offline after that verified binary
has been installed into the app assets.

## Development

Prerequisites:

- Flutter with a Dart SDK compatible with `^3.12.0`;
- the native Flutter desktop toolchain for the host platform;
- network access for the explicit engine-fetch step.

From the repository root:

```bash
flutter pub get
dart run tool/engine/fetch_engine.dart
dart run tool/engine/fetch_engine.dart --verify-only
flutter run -d macos # or windows / linux on the matching host
```

The intended verification gate is:

```bash
dart format --output=none --set-exit-if-changed lib test integration_test tool
flutter analyze
flutter test
flutter test integration_test -d macos # matching native target on CI
```

Native integration contracts are currently explicitly skipped because the
public installed-app driver, native fixture injection, restart/reopen
automation, and output-probe hook belong to the next integration tranche. A
fake engine is not accepted as proof of the bundled native workflow.

Release builds will use the matching host command:

```bash
flutter build macos --release
flutter build windows --release
flutter build linux --release
```

These build commands describe the intended workflow; this README does not claim
that release artifacts have been produced or validated.

## Design and implementation material

- [Product design](docs/superpowers/specs/2026-07-11-gapless-desktop-design.md)
- [MVP implementation plan](docs/superpowers/plans/2026-07-11-gapless-mvp.md)
- [Verified engine-fetch tool](tool/engine/fetch_engine.dart)
- [Auto-Editor third-party notice](third_party/auto-editor/NOTICE.md)
- [Instrument Sans third-party notice](third_party/instrument-sans/NOTICE.md)

## License

Gapless source is licensed under the
[GNU General Public License v3.0 or later](LICENSE)
(`GPL-3.0-or-later`). Bundled third-party components retain their own licenses
and notices linked above.
