# Task 9 report — Approved Studio UI and one-project workflow

## Outcome

Task 9 assembles the approved Gapless Studio screen around the existing project,
analysis, playback, and timeline contracts. The implementation keeps native and
filesystem work behind injected ports, retains a deterministic empty dependency
harness for widget tests, and exposes MP4 export as the Task 9 event boundary.

## TDD evidence

The first focused run was intentionally red:

```text
flutter test test/features/editor/presentation/editor_screen_test.dart --reporter compact
```

It exited 1 because `editor_screen.dart`, `editor_view_model.dart`, and the
expected presentation symbols did not exist. The first green slice rendered the
approved ready-state controls. Subsequent red/green slices added and exercised:

- empty, analyzing, ready, save-failed, and no-audio recovery states;
- import and open-project lifecycle ordering;
- autosave, retry, Save As, versioned recents, and lazy inaccessible-entry pruning;
- settings re-analysis, manual timeline toggles without re-analysis, and undo/redo;
- frozen MP4 export requests without implementing the Task 10 renderer;
- desktop shortcuts and Space suppression while editing text;
- injected application composition, both themes, and the two full-screen goldens.

The golden tests were first run without baseline files and failed, then the
baselines were generated. The final verification below used normal comparison
mode only; it did not use `--update-goldens`.

## Files changed

- `.gitattributes` (preserves the official OFL bytes while excluding that
  vendored file from Git's trailing-whitespace policy)
- `lib/features/editor/presentation/editor_screen.dart`
- `lib/features/editor/presentation/editor_view_model.dart`
- `lib/features/editor/presentation/widgets/studio_toolbar.dart`
- `lib/features/editor/presentation/widgets/settings_sidebar.dart`
- `lib/features/editor/presentation/widgets/video_preview.dart`
- `lib/features/editor/presentation/widgets/status_bar.dart`
- `lib/app/gapless_app.dart`
- `lib/app/app_dependencies.dart`
- `pubspec.yaml`
- `test/features/editor/presentation/editor_screen_test.dart`
- `test/app/gapless_app_test.dart`
- `test/goldens/editor_dark_1280x832.png`
- `test/goldens/editor_light_1280x832.png`
- `assets/fonts/InstrumentSans-VariableFont_wdth,wght.ttf`
- `assets/fonts/OFL.txt`
- `assets/fonts/SHA256SUMS`
- `third_party/instrument-sans/NOTICE.md`

## Verification

Commands were run sequentially:

```text
dart format --output=none --set-exit-if-changed lib test
Formatted 66 files (0 changed).

flutter analyze
No issues found.

flutter test test/features/editor test/app --reporter compact
59 tests passed.

flutter test --reporter compact
226 tests passed; 1 platform-specific test skipped.

git diff --check
Clean (exit 0, no output).
```

The final normal test runs did not rewrite either golden. Their SHA-256 values
were identical before and after verification:

```text
a575c128125e0f7562217581c9c63adfee2b690d283fc445e367df47cd5660b1  test/goldens/editor_dark_1280x832.png
a51ffcab0d823f2067d7c3f6e58e8285021b42dfcb26623489bda5da57be101b  test/goldens/editor_light_1280x832.png
```

## Font source and integrity

Instrument Sans and its OFL were downloaded from the official Google Fonts
repository at `google/fonts/main/ofl/instrumentsans`. They are bundled for
offline runtime use, registered as `InstrumentSans`, recorded in
`assets/fonts/SHA256SUMS`, and documented in the third-party notice.

```text
b24f1812584816958afcf22e22d08e44318c5e51651e25d2438efdde389b33b1  assets/fonts/InstrumentSans-VariableFont_wdth,wght.ttf
9e27a72ed30eb49a08678f6a5d6ed98ec7ba5368f541637ee0683ec9134ef966  assets/fonts/OFL.txt
```

The downloaded files were independently re-fetched from the two official raw
Google Fonts URLs during implementation; both upstream hashes matched the
bundled files exactly. The upstream OFL contains one trailing space; a narrowly
scoped `.gitattributes` rule preserves those official bytes while keeping the
repository's staged whitespace check clean.

## Visual inspection

Both final 1280×832 goldens were inspected at full composition size. The dark
and light themes are unclipped, retain the full-height bounded sidebar, and use
the approved fixed title, toolbar, and status areas. Material control glyphs
render as icons rather than missing-glyph squares. The light-theme amber
`EDITED` chip has readable text, and the preview, settings, transport, timeline,
zoom, save-state, and export surfaces are legible in both themes.

## Known concerns and follow-up boundaries

- `AppDependencies` now supplies real adapter types and injectable factories,
  but `main.dart` still starts with `AppDependencies.empty()`. A production
  native composition root remains follow-up work; the empty composition is
  deliberately safe and does not claim to run media/process APIs.
- Task 9 emits a frozen MP4 export request only. Task 10 owns rendering the MP4
  and reporting export progress/results.
- Changing a detection setting clears manual keep/remove choices before
  re-analysis because the current coordinator contract returns raw detection
  output. The UI states this explicitly, while undo/redo and manual-only edits
  preserve the no-reanalysis behavior.
