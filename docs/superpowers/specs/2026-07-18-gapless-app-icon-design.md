# Gapless App Icon Design

## Goal

Replace the default Flutter application icon with a recognizable Gapless icon
for macOS and Windows. The icon must match the existing product identity,
remain legible at native desktop icon sizes, and be reproducible without a
proprietary design tool.

## Approved visual direction

The approved direction is **Gap Bars**, derived from the two-bar mark already
shown beside the Gapless name in the application title bar.

- Background: charcoal `#17191D`.
- Foreground: two vertical amber bars using the application accent
  `#E3A63B`.
- The left bar is solid; the right bar uses reduced opacity to match the
  existing in-app mark.
- The artwork contains no letters, words, gradients, photographs, shadows, or
  Flutter branding.
- Generous internal padding and simple geometry keep the mark clear from 16 px
  through 1024 px.
- The outer silhouette is a rounded square suitable for desktop launchers.

The selected design intentionally favors the established in-app mark over a
new waveform illustration or `G` monogram. This keeps the app icon and title
bar visually consistent and avoids detail that would disappear at taskbar and
Finder-list sizes.

## Platform scope

This change covers:

- macOS `AppIcon.appiconset`, including the committed PNG sizes from 16 px
  through 1024 px;
- Windows `windows/runner/resources/app_icon.ico`, with embedded frames from
  16 px through 256 px.

Linux branding remains unchanged and is outside this task.

## Reproducible asset generation

The repository will contain a deterministic, dependency-light icon generator
as the source of truth. It will render the approved geometry into the required
PNG files and assemble the Windows ICO from PNG frames. Generated outputs stay
committed because Xcode and the Windows runner consume those assets directly.

The generator must:

- use exact approved colors and geometry;
- use antialiasing so rounded edges remain clean;
- generate every required macOS size without scaling a small source image;
- generate Windows frames at 16, 32, 48, 64, 128, and 256 px;
- produce identical bytes for identical source and parameters;
- fail with a clear error instead of leaving a partially updated icon set.

## Integration

The existing platform references remain authoritative:

- macOS continues to consume
  `macos/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json`;
- Windows continues to consume
  `windows/runner/resources/app_icon.ico` through `Runner.rc`.

No runtime Flutter widget, application behavior, signing identity, bundle ID,
release version, or release-matrix target changes as part of this work.

## Verification

Automated verification will prove:

- all macOS icon files exist and have the dimensions declared by the asset
  catalog;
- the Windows ICO contains the required frame sizes;
- regenerated output matches the committed platform assets;
- the committed icons no longer contain the default Flutter artwork;
- existing analyzer and Flutter tests still pass.

Platform verification will additionally build the macOS application and
inspect its packaged icon asset. Windows integration is proven by the
committed ICO contract and the existing Windows CI build because the current
host cannot launch a Windows executable.

## Delivery

The icon change will be committed to `codex/macos-0.1.0-release`, pushed to
pull request #2, and held to the same required CI checks as the release
workflow changes. It does not merge the pull request, create `v0.1.0`, dispatch
the release workflow, or create a GitHub Release.
