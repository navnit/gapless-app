# In-App Update — Design

Date: 2026-07-23
Status: Approved (design) — revised after Fable review

## Goal

Give Gapless an in-app way to learn a newer version exists and be guided to
install it, tailored to how the app was installed (Homebrew cask vs. direct
DMG download). The app is macOS-only, ad-hoc signed, and **not notarized**, so
self-replacing the bundle (Sparkle-style) is out of scope for v1. This feature
is *notify + hand-off*, not auto-update.

## Scope (v1)

- **Auto-check on launch** (background, non-blocking, failures silent),
  **throttled to at most once per 24 h** and gated by an **opt-out toggle**
  (default on).
- **Manual "Check for Updates…"** from a native macOS menu.
- **Channel detection** (Homebrew vs. direct DMG) to show the correct update
  path.
- **Skip this version** / **Remind me later** so the launch banner does not nag.

Explicitly out of scope: downloading and self-replacing the bundle; periodic
timer re-checks while running; ETag/304 conditional requests (a future option,
not needed at once-per-day-per-machine).

## Distribution reality (why the design is shaped this way)

- **Homebrew cask** (`navnit/homebrew-gapless`): `brew upgrade --cask gapless`
  replaces the bundle in place. The clean path. The cask's `app "Gapless.app"`
  stanza *moves* (does not symlink) the bundle to `/Applications`.
- **Direct DMG** from GitHub Releases (`navnit/gapless-app`): the user drags
  `Gapless.app` into `/Applications` and must choose **Replace** ("Keep Both"
  leaves a duplicate). Being unnotarized, each replaced copy re-triggers
  Gatekeeper.
- The **same DMG** serves both channels (the cask downloads the release DMG), so
  the channel cannot be baked in at build time — detection must be runtime /
  environment based.

## Environment facts (verified 2026-07-23)

- `macos/Runner/Release.entitlements` is empty (`<dict/>`): the **shipped app is
  not sandboxed**, so outbound HTTPS needs no entitlement.
- `macos/Runner/DebugProfile.entitlements` **is** sandboxed with only
  `network.server`. The check therefore fails under `flutter run` (and Profile
  builds) until `com.apple.security.network.client` is added there. Release
  needs no change.
- `Info.plist` sets `CFBundleShortVersionString = $(FLUTTER_BUILD_NAME)`, so
  `package_info_plus` reports `0.1.1` from `version: 0.1.1+1`.
- Release repo for the API and DMG assets: `navnit/gapless-app`.
  `GET https://api.github.com/repos/navnit/gapless-app/releases/latest` already
  excludes prereleases/drafts — a clean stable channel.

## Architecture

New `update` feature following the existing `domain / application / data /
presentation` split. **All network-, filesystem-, and preference-facing work
sits behind ports** — matching the existing `RecentProjectsPort` convention —
so logic is unit-testable with no real network, brew install, or disk.

```
lib/features/update/
  domain/
    app_version.dart              # semver value type + integer compare
    update_status.dart            # sealed: UpToDate | UpdateAvailable(release) | CheckFailed
    install_channel.dart          # enum: homebrew | directDmg | unknown
    release_info.dart             # version, notes, htmlUrl, dmgAssetUrl
    update_checker_port.dart      # abstract: Future<ReleaseInfo> fetchLatest()
    channel_detector_port.dart    # abstract: Future<InstallChannel> detect()
    update_preferences_port.dart  # abstract: read/write skippedVersion, lastCheckedAt, autoCheckEnabled
  data/
    github_update_checker.dart    # GitHub REST via `http`
    caskroom_channel_detector.dart# receipt/directory check
    json_update_preferences.dart  # atomic JSON store (schemaVersion + tmp + rename)
  application/
    update_coordinator.dart       # read current version, throttle, fetch, compare, apply prefs
  presentation/
    update_banner.dart            # dismissible banner hosted by GaplessApp
    update_dialog.dart            # release notes + channel-specific action
    update_menu.dart              # PlatformMenu items: Check for Updates… + auto-check toggle
```

### New dependencies (2)

- `http` — the network call (chosen over `dart:io` `HttpClient` for `MockClient`
  testability).
- `package_info_plus` — reads `CFBundleShortVersionString` to know the running
  version.
- No `pub_semver` (a 3-integer compare is trivial). No `url_launcher` — links
  open via `Process.run('open', [url])`, always present on macOS and already
  used by `NativeExportRevealInFolder` in `app_dependencies.dart`.

## App wiring

Mirror the existing export-dialog pattern rather than inventing new plumbing:

- Add an `UpdateHost` (analogous to `AppExportDialogHost`) carried on the const
  `AppDependencies` value object. `AppDependencies.production()` constructs the
  coordinator + host; `AppDependencies.empty()` omits it.
- `_GaplessAppState` subscribes to the host and, in `initState`, kicks off
  `UpdateCoordinator.checkOnLaunch()` (non-blocking). The dialog is shown via
  the existing private `_navigatorKey`.
- The **banner is hosted in `GaplessApp`, wrapping `home`** (rendered as an
  overlay), *not* inside `EditorScreen` — this avoids an editor→update coupling
  and the layout shift that would occur when the async check lands mid-session.
- The **menu** is a `PlatformMenuBar` around `home`, adding an application-menu
  group: **Check for Updates…** and a checkbox **Automatically check for
  updates** bound to the pref.

## Data flow

- **On launch:** `checkOnLaunch()` returns early if `autoCheckEnabled` is false
  or `now - lastCheckedAt < 24 h`. Otherwise it runs in the background,
  swallowing every failure. On `UpdateAvailable` with a non-skipped version it
  emits state the banner renders. Records `lastCheckedAt`.
- **Manual:** the menu item runs the same coordinator ignoring the throttle and
  surfaces *every* outcome — up to date, failure, and update available.

## Channel detection (`CaskroomChannelDetector`)

Pure filesystem, `async`, run off the UI. A Homebrew cask *moves* the bundle to
`/Applications`, so a brew install rarely runs from under `/Caskroom/`; the
receipt/directory is the primary signal.

1. Resolve the running bundle: walk up from `Platform.resolvedExecutable` to the
   `.app` directory. If that path is under a `/Caskroom/` directory →
   `homebrew` (covers a staged/rare run-in-place case).
2. Else, for each prefix in `/opt/homebrew` and `/usr/local`, treat as
   `homebrew` if **either** `…/Caskroom/gapless/.metadata/INSTALL_RECEIPT.json`
   exists (modern Homebrew) **or** the `…/Caskroom/gapless/` directory exists
   (older Homebrew predating receipts, which also survives).
3. Else → `directDmg`.
4. Any exception → `unknown`, treated by the UI exactly like `directDmg` (a
   download link always works; a wrong `brew upgrade` instruction does not).

Accepted tradeoffs (documented, not engineered around):
- A DMG user with a lingering gapless brew receipt is told to `brew upgrade`.
  In practice a lingering receipt means brew still manages the install, so the
  command works; if not, the user falls back to downloading. Mild.
- A custom `HOMEBREW_PREFIX` install misdetects as `directDmg`. Fail-safe
  direction (download link works), so acceptable for v1.
- We do **not** shell out to `brew` — it is not on a Finder-launched app's PATH.

## Version comparison (`AppVersion`)

Parse `CFBundleShortVersionString` and the release `tag_name` (strip leading
`v`) into `(major, minor, patch)` integers and compare. `0.10.0 > 0.9.0`
resolves correctly. Build metadata (`+1`) and any suffix (e.g. `-rc1`) fail the
patch-int parse → treated as "no update" (fail safe; never falsely prompt).

## GitHub client (`GithubUpdateChecker`)

`GET api.github.com/repos/navnit/gapless-app/releases/latest`,
`Accept: application/vnd.github+json`, ~5 s timeout. Extract `tag_name`, `body`
(release notes, **length-capped** before rendering), `html_url`, and the
arch-matching DMG `assets[].browser_download_url`. Unauthenticated.

**Arch matching:** select the asset whose name contains the current-arch token —
`-macos-arm64-` or `-macos-x64-` — derived from `Abi.current()`. This name
contract is a **release-process invariant** (a renamed asset silently degrades
everyone to `html_url`). Known limitation: an x64 build running under Rosetta on
Apple Silicon reports x64 and will offer the Intel DMG; detecting
`sysctl.proc_translated` is deferred past v1.

**Backport limitation:** `/releases/latest` is the most recently *published*
stable release, not the highest version. A backport (0.1.2 after 0.2.0) would
not prompt 0.2.x users. The integer compare prevents a downgrade prompt, so this
is safe, just noted.

Any non-200, timeout, or parse error → `CheckFailed`. The manual path
distinguishes **403/429 (rate limit)** — "GitHub rate limit, try again later" —
from transport failure — "Check your connection and try again."

## Preferences (`JsonUpdatePreferences` implements `UpdatePreferencesPort`)

Atomic JSON file under `path_provider`'s app-support dir, reusing the
`schemaVersion` + `.tmp` write + `rename` pattern from `JsonRecentProjectsStore`:

- `autoCheckEnabled` (default `true`) — the opt-out toggle.
- `skippedVersion` — set by "Skip this version"; suppresses the **banner** for
  exactly that version. The manual check still reports it.
- `lastCheckedAt` — drives the 24 h launch throttle.

"Remind me later" dismisses the banner for the session only (no persistence); it
reappears on the next eligible launch.

## URL safety

Before `Process.run('open', [url])`, require the URL scheme is `https` and the
host ∈ {`github.com`, `objects.githubusercontent.com`}. A URL failing the check
opens nothing (never the raw string). The `brew upgrade --cask gapless` copy
string is a compile-time constant, never assembled from API data.

## UI states

**Menu (`update_menu.dart`)** — application menu group:

| Item | Behavior |
|------|----------|
| Check for Updates… | Runs the coordinator (ignoring throttle), surfaces every outcome |
| ☑ Automatically check for updates | Toggles `autoCheckEnabled` |

Manual outcomes: *Checking* (item disabled) · *Up to date* → dialog/snackbar
"Gapless {v} is the latest version." · *Update available* → `UpdateDialog` ·
*Rate limited* → "GitHub rate limit, try again later." · *Failed* → "Check your
connection and try again."

**Launch banner** — dismissible overlay bar hosted by `GaplessApp`, shown only
when the launch check returned `UpdateAvailable` **and** the version ≠
`skippedVersion` **and** not dismissed this session. Content: "Gapless {new} is
available" + **View** (opens `UpdateDialog`) + **Skip this version** + **×**
(remind-later, session-only).

**`UpdateDialog`** — branches on channel:

- Header: "Gapless {new} is available" (current {old} smaller).
- Release notes: capped `body` as plain text, scrollable, height-capped.
- Action row:
  - `homebrew` → primary shows `brew upgrade --cask gapless` (constant) with a
    **Copy** button; secondary **View release** opens `html_url`.
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

- `AppVersion` compare — units incl. `0.10.0 > 0.9.0`, `-rc1`/`+1`/malformed →
  no-update.
- `CaskroomChannelDetector` — inject a fake filesystem root so all branches
  (Caskroom-path, receipt, directory-only, none, exception) are covered without
  a real brew install.
- `AppVersion`/arch — asset selection picks the right DMG per `Abi`, falls back
  to `html_url` when absent.
- URL-safety guard — https+host allowlist accepts GitHub URLs, rejects
  `file://`, other hosts, other schemes.
- `UpdateCoordinator` — fake checker + detector + in-memory prefs port:
  throttle skips within 24 h, opt-out short-circuits, skip suppresses banner,
  up-to-date, failure swallowed on launch, channel routes to correct action.
- `GithubUpdateChecker` — parses a captured sample JSON payload; maps 403/429 to
  the rate-limit status (no live network, via `MockClient`).
- `JsonUpdatePreferences` — round-trips and rejects a wrong `schemaVersion`.
- Widget test: `UpdateDialog` renders the brew command for `homebrew` and the
  Download button for `directDmg`.

## Local-dev note

Add `com.apple.security.network.client` to `DebugProfile.entitlements` so the
check works under `flutter run`. The shipped release is unsandboxed, so
`Release.entitlements` needs no change.

## Docs

Note in the README that Gapless checks GitHub for updates on launch (at most
once per day) and how to turn it off, since it is an open-source app making an
outbound request.
