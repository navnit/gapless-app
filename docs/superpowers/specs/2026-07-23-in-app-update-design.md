# In-App Update — Design

Date: 2026-07-23
Status: Approved (design)

## Goal

Give Gapless an in-app way to learn a newer version exists and be guided to
install it, tailored to how the app was installed (Homebrew cask vs. direct
DMG download). The app is macOS-only, ad-hoc signed, and **not notarized**, so
self-replacing the bundle (Sparkle-style) is out of scope for v1. This feature
is *notify + hand-off*, not auto-update.

## Scope (v1)

- **Auto-check on launch** (background, non-blocking, failures silent) **plus a
  manual "Check for Updates…"** trigger.
- **Channel detection** (Homebrew vs. direct DMG) to show the correct update
  path.
- **Skip this version** / **Remind me later** so the launch banner is not
  nagging.

Explicitly out of scope: downloading and self-replacing the bundle; periodic
timer re-checks while running; a native menu bar item (the app has none).

## Distribution reality (why the design is shaped this way)

- **Homebrew cask** (`navnit/homebrew-gapless`): `brew upgrade --cask gapless`
  replaces the bundle in place. The clean path. The cask's `app "Gapless.app"`
  stanza *moves* (does not symlink) the bundle.
- **Direct DMG** from GitHub Releases (`navnit/gapless-app`): the user drags
  `Gapless.app` into `/Applications` and must choose **Replace** (choosing
  "Keep Both" leaves a duplicate). Being unnotarized, each replaced copy
  re-triggers Gatekeeper.
- The **same DMG** serves both channels (the cask downloads the release DMG), so
  the channel cannot be baked in at build time — detection must be runtime /
  environment based.

## Environment facts (verified 2026-07-23)

- `macos/Runner/Release.entitlements` is empty (`<dict/>`): the **shipped app is
  not sandboxed**, so outbound HTTPS needs no entitlement.
- `macos/Runner/DebugProfile.entitlements` **is** sandboxed with only
  `network.server`. The check therefore fails under `flutter run` until
  `com.apple.security.network.client` is added there. Release needs no change.
- Release repo for the API and DMG assets: `navnit/gapless-app`.
  `GET https://api.github.com/repos/navnit/gapless-app/releases/latest` already
  excludes prereleases/drafts — a clean stable channel.

## Architecture

New `update` feature following the existing `domain / application / data /
presentation` split. All network- and filesystem-facing work sits behind ports
so logic is unit-testable with no real network or brew install.

```
lib/features/update/
  domain/
    app_version.dart            # semver value type + integer compare
    update_status.dart          # sealed: UpToDate | UpdateAvailable(release) | CheckFailed
    install_channel.dart        # enum: homebrew | directDmg | unknown
    release_info.dart           # version, notes, htmlUrl, dmgAssetUrl
    update_checker_port.dart    # abstract: Future<ReleaseInfo> fetchLatest()
    channel_detector_port.dart  # abstract: InstallChannel detect()
  data/
    github_update_checker.dart      # GitHub REST via `http`
    caskroom_channel_detector.dart  # receipt-file check
  application/
    update_coordinator.dart     # read current version, fetch latest, compare, apply prefs
    update_preferences.dart     # persisted skipped-version + last-checked
  presentation/
    update_banner.dart          # dismissible banner in EditorScreen
    update_dialog.dart          # release notes + channel-specific action
    check_for_updates_tile.dart # manual trigger in settings_sidebar
```

### New dependencies (3)

- `http` — the network call.
- `package_info_plus` — reads `CFBundleShortVersionString` to know the running
  version (populated from pubspec at build time).
- No `pub_semver` (a 3-integer compare is trivial). No `url_launcher` — links
  open via `Process.run('open', [url])`, always present on macOS.

## Data flow

- **On launch:** `AppDependencies` fires `UpdateCoordinator.checkOnLaunch()` in
  the background. Non-blocking; every failure swallowed. If it returns
  `UpdateAvailable` and the version is not the skipped version, it sets state
  that `EditorScreen` renders as a banner.
- **Manual:** the "Check for Updates…" tile runs the same coordinator but
  surfaces *every* outcome, including "up to date" and check failures. The
  dialog is shown via the existing `navigatorKey`.

## Channel detection (`CaskroomChannelDetector`)

Pure filesystem, run off the UI:

1. Resolve the running bundle: walk up from `Platform.resolvedExecutable` to the
   `.app` directory.
2. If that path is under a `/Caskroom/` directory → `homebrew` (staged-run
   case).
3. Else if a receipt exists at
   `/opt/homebrew/Caskroom/gapless/.metadata/INSTALL_RECEIPT.json` **or**
   `/usr/local/Caskroom/gapless/.metadata/INSTALL_RECEIPT.json` → `homebrew`.
4. Else → `directDmg`.
5. Any exception → `unknown`, treated by the UI exactly like `directDmg` (a
   download link always works; a wrong `brew upgrade` instruction does not).

Accepted tradeoff: a DMG user who *also* has a stale gapless brew receipt is
told to `brew upgrade`. Rare, and step 2 catches the common case first. We do
not shell out to `brew` — it is not on a Finder-launched app's PATH.

## Version comparison (`AppVersion`)

Parse `CFBundleShortVersionString` and the release `tag_name` (strip leading
`v`) into `(major, minor, patch)` integers and compare. `0.10.0 > 0.9.0`
resolves correctly. Build metadata (`+1`) and suffixes are ignored. Malformed
input → treated as "no update" (fail safe; never falsely prompt).

## GitHub client (`GithubUpdateChecker`)

`GET api.github.com/repos/navnit/gapless-app/releases/latest`,
`Accept: application/vnd.github+json`, ~5 s timeout. Extract `tag_name`, `body`
(release notes), `html_url`, and the arch-matching DMG
`assets[].browser_download_url`. Unauthenticated (60 req/hr/IP is ample for
once-per-launch). Any non-200, timeout, or parse error → `CheckFailed`.

## Preferences (`UpdatePreferences`)

Small JSON file under `path_provider`'s app-support dir:

- `skippedVersion` — set by "Skip this version"; suppresses the **banner** for
  exactly that version. The manual check still reports it.
- `lastCheckedAt` — recorded each check. Not gating v1 (every launch checks) but
  stored so a future once-per-day throttle is a one-line change.

"Remind me later" dismisses the banner for the session only (no persistence); it
reappears next launch.

## UI states

**Manual "Check for Updates…" tile** (in `settings_sidebar`):

| Outcome | UI |
|---------|-----|
| Checking | Inline spinner ("Checking…"), tile disabled |
| Up to date | Snackbar/dialog: "Gapless {v} is the latest version." |
| Update available | `UpdateDialog` |
| Check failed | Snackbar: "Couldn't check for updates. Check your connection and try again." |

**Launch banner** — dismissible bar at the top of `EditorScreen`, shown only
when the launch check returned `UpdateAvailable` **and** the version ≠
`skippedVersion` **and** not dismissed this session. Content: "Gapless {new} is
available" + **View** (opens `UpdateDialog`) + **Skip this version** + **×**
(remind-later, session-only).

**`UpdateDialog`** — branches on channel:

- Header: "Gapless {new} is available" (current {old} smaller).
- Release notes: `body` as plain text, scrollable, height-capped.
- Action row:
  - `homebrew` → primary shows `brew upgrade --cask gapless` with a **Copy**
    button; secondary **View release** opens `html_url`.
  - `directDmg` / `unknown` → primary **Download** opens the arch-matching DMG
    `browser_download_url` (falls back to `html_url` if no matching asset) with
    the reminder "Drag the new Gapless into Applications and choose Replace.";
    secondary **View release**.
- Footer: **Skip this version** / **Close**.

## Error handling principle

The launch path is **silent on every failure** (network, parse, detection) — an
update checker must never interrupt someone's work with an error they did not
ask for. Only the **manual** path reports failures, because there the user
explicitly asked.

## Testing (TDD)

- `AppVersion` compare — units incl. `0.10.0 > 0.9.0`, malformed → no-update.
- `CaskroomChannelDetector` — inject a fake filesystem root/path so all four
  branches are covered with no real brew install.
- `UpdateCoordinator` — fake `UpdateCheckerPort` + `ChannelDetectorPort` +
  in-memory prefs: skip-suppresses-banner, up-to-date, failed-check-swallowed-
  on-launch, channel routes to correct action.
- `GithubUpdateChecker` — parses a captured sample JSON payload (no live
  network).
- Widget test: `UpdateDialog` renders the brew command for `homebrew` and the
  Download button for `directDmg`.

## Local-dev note

Add `com.apple.security.network.client` to `DebugProfile.entitlements` so the
check works under `flutter run`. The shipped release is unsandboxed, so
`Release.entitlements` needs no change.
