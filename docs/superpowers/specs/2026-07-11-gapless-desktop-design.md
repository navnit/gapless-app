# Gapless Desktop Application Design

**Status:** Approved

**Date:** 2026-07-11

**License:** GPL-3.0-or-later

**Target platforms:** macOS, Windows, and Linux

## 1. Summary

Gapless is a free and open-source desktop application that gives beginners a visual workflow for Auto-Editor. A user opens one local video, lets the bundled Auto-Editor engine detect inactive sections, reviews those decisions on a waveform timeline, manually changes any segment between keep and remove, saves the project automatically, and exports a finished MP4.

The application uses Flutter for its cross-platform interface, `media_kit`/libmpv for playback, and a version-pinned Auto-Editor executable for analysis and rendering. The user interface never constructs raw command lines. A typed engine adapter isolates upstream command and timeline changes from the rest of the application.

The product name is **Gapless**. The approved Gapless UX package supplies the Studio layout, interaction model, visual hierarchy, themes, amber accent, timeline, and export states that form the visual source of truth.

## 2. Goals

- Provide a beginner-friendly, offline editing experience that works immediately after installation.
- Bundle the correct Auto-Editor executable for each supported platform and architecture.
- Show detected keep/remove decisions before rendering.
- Let users override every detected segment non-destructively.
- Make Edited preview and exported MP4 derive from the same normalized timeline.
- Save and recover project work automatically.
- Keep the architecture modular enough to add analysis methods, export formats, batch processing, and alternative engines later.
- Publish reproducible builds, source, checksums, an SBOM, and third-party notices.

## 3. Non-goals for the first release

- Multiple source videos in one project.
- Batch processing.
- A general-purpose multitrack video editor.
- Arbitrary trimming, transitions, titles, overlays, or color grading.
- Premiere Pro, DaVinci Resolve, Final Cut Pro, Shotcut, Kdenlive, or timeline-file export.
- URL import or media downloading.
- Cloud storage, accounts, telemetry, or required network access.
- Automatic application updates.
- Windows ARM or Linux ARM release artifacts.

## 4. Product decisions

| Area | Decision |
| --- | --- |
| Distribution | Free and open source |
| Application license | GPL-3.0-or-later |
| UI stack | Flutter desktop |
| Playback | `media_kit` backed by libmpv |
| Processing | Bundled, version-pinned Auto-Editor executable |
| Project scope | One local video per project |
| Project persistence | Relocatable `.gapless` JSON plus crash-safe autosave |
| Timeline editing | Click segments to toggle keep/remove |
| Export | Finished MP4 only |
| Core connectivity | Fully offline |

## 5. User experience

### 5.1 Visual source of truth

The user-supplied `Desktop app for auto-editor.zip` Gapless UX is the approved visual reference. The application preserves:

- A single resizable Studio window.
- A compact title bar and file toolbar.
- A resizable left tuning panel.
- A large video preview with Original/Edited switching.
- A resizable bottom timeline with waveform, decision strip, ruler, zoom, and playhead.
- Amber as the default restrained accent.
- Dark and light themes following the operating-system preference by default.
- Clear empty, analyzing, ready, exporting, completed, and error states.
- Progressive disclosure through an Advanced section.
- A three-phase export modal: choose destination, render, complete.

### 5.2 Approved adaptations

The reference UX is adapted in these ways:

- The toolbar shows `Saving…`, `Saved`, or an actionable save error.
- The File menu provides New, Open Project, Open Video, Save, Save As, and Recent Projects.
- First import creates an internal draft without interrupting the user with a save dialog.
- Save As produces a relocatable `.gapless` project file that references, but does not embed, the source video.
- The export dialog contains MP4 destination and optional quality controls, not an export-format list.
- The status bar prioritizes cut count and duration reduction. The raw Auto-Editor command and logs move into Advanced diagnostics.
- Manual keep/remove overrides are persisted separately from detected decisions.
- Native platform window controls are used where custom controls would reduce accessibility or platform correctness.

### 5.3 Primary workflow

1. The empty state offers drag-and-drop, Open Video, and recent projects.
2. The user opens one local media file.
3. The app creates an internal draft and probes metadata.
4. Auto-Editor produces analysis levels and an initial v3 timeline while the UI reports progress.
5. The app converts upstream output into its normalized timeline and renders the waveform and segments.
6. The user adjusts method, threshold, margin, and inactive-section behavior.
7. Analysis re-runs after a short debounce. The last completed timeline stays visible until the new result is ready.
8. The user switches between Original and Edited playback, scrubs, zooms, and toggles segments.
9. Changes autosave atomically. Undo/redo covers settings and manual timeline changes.
10. The user exports to a chosen MP4 path.
11. The app serializes the exact effective timeline to a temporary v3 file and asks Auto-Editor to render it.
12. On success, the app atomically promotes the partial output and offers Show in Folder. The project remains open.

### 5.4 Timeline behavior

- Source time is the canonical coordinate system.
- Detected decisions and user overrides are separate layers.
- Manual overrides win over detected decisions.
- Kept sections are full-height amber-tinted blocks.
- Removed sections are shorter, gray, hatched blocks.
- A manually changed segment has an additional outline or marker.
- Clicking a segment toggles its effective action between keep and remove.
- Original mode plays source time linearly and shows all detected decisions at full strength.
- Edited mode jumps removed ranges and applies configured speed to fast-forward ranges.
- Export uses the same effective ranges and actions used by Edited preview.
- Re-analysis preserves manual source-time overrides. Overrides outside the media duration are clipped; empty overrides are removed.
- Zoom ranges from Fit/100% through 1200%, anchored beneath the pointer when using Ctrl/Cmd plus scroll.

## 6. Architecture

### 6.1 Layers

```text
Flutter presentation
  screens, widgets, themes, timeline painter, dialogs
        |
Application workflows
  project lifecycle, autosave, undo/redo, analysis/export tasks
        |
Domain model
  media metadata, settings, segments, overrides, time mapping
        |
Ports
  PlaybackPort, EnginePort, ProjectStore, CacheStore, FileDialogs
        |
Adapters
  media_kit/libmpv, Auto-Editor process, JSON files, OS integration
```

Dependencies point inward. Domain types do not import Flutter, `media_kit`, process APIs, or Auto-Editor representations.

### 6.2 Component responsibilities

#### Presentation

- Renders the approved Gapless Studio layout.
- Converts pointer and keyboard gestures into application commands.
- Draws the waveform and effective segments using immutable view models.
- Does not read files, launch processes, or construct Auto-Editor arguments.

#### Project controller

- Owns the open project and its dirty/saving/error state.
- Serializes edits through a single command queue.
- Maintains bounded undo and redo stacks.
- Coordinates autosave, Save As, recent projects, source relocation, and recovery.

#### Analysis coordinator

- Debounces setting changes.
- Cancels obsolete queued work.
- Allows only one Auto-Editor analysis process per project.
- Retains the last complete result until a new result succeeds.
- Applies manual overrides after detection.

#### Playback controller

- Owns the `media_kit` player.
- Presents Original and Edited clocks.
- Maps edited time to source time and source time to edited time.
- Skips removed ranges and changes rate for fast-forward ranges.
- Never modifies project decisions.

#### Export coordinator

- Freezes an immutable snapshot of the effective project timeline.
- Serializes that snapshot to the pinned upstream v3 representation.
- Renders to a `.partial` destination.
- Reports version-aware progress without making progress parsing correctness-critical.
- Promotes the completed output atomically when the destination filesystem permits it.

#### Auto-Editor adapter

- Locates only the bundled executable described by the release manifest.
- Verifies its version and checksum.
- Maps typed requests to argument arrays.
- Runs processes without a shell.
- Parses `info --json`, `levels`, and v3 timeline output.
- Converts exit status and diagnostic output into typed failures.
- Contains every dependency on a particular Auto-Editor version.

#### Native process ownership host

- Launches an absolute Auto-Editor path behind a small first-party executable resolved only from the application bundle; neither boundary searches `PATH`.
- Establishes a child process group before `execv` on macOS/Linux. On Windows, `STARTUPINFOEXW` creates the suspended target already associated with a kill-on-close Job Object and restricts inherited handles to its three standard handles before resume.
- Owns cancellation through a private versioned stdin control channel; EOF and host termination cannot intentionally orphan the managed process tree.
- Uses one checked monotonic cleanup deadline. The Dart watchdog has a fixed scheduling margin above the complete native budget and cannot return while the host remains live.
- Uses no shell, process-table discovery, WMI, or command-line cleanup utility. Target arguments remain discrete and the target inherits the adapter's sanitized environment and working directory.

## 7. Engine integration

### 7.1 Pinned engine policy

Each Gapless release pins one exact Auto-Editor release and ships the matching executable for every release target. Upgrading Auto-Editor requires adapter contract tests to pass before an app release can use the new version.

The app does not search `PATH` or silently substitute a user-installed executable. An Advanced developer setting may support an explicit override in a later release, but it is not part of the MVP.

### 7.2 Operations

The adapter exposes these operations:

```text
probe(source) -> MediaMetadata
analyzeLevels(source, method) -> AnalysisLevels
detectTimeline(source, settings) -> DetectedTimeline
render(timeline, destination, encoding) -> RenderTask
cancel(taskId)
diagnostics() -> EngineDiagnostics
```

The initial implementation maps them to upstream capabilities:

- Metadata: `auto-editor info <source> --json`
- Waveform/motion levels: `auto-editor levels <source> --edit <method>`
- Detection: `auto-editor <source> ...settings --export v3 -o <temporary.v3>`
- Rendering: `auto-editor <effective.v3> -o <destination.partial.mp4> ...encoding`

Arguments are passed as discrete process arguments. Source and destination paths are never interpolated into a shell command.

### 7.3 Progress and cancellation

Auto-Editor progress text is not a stable machine contract. The adapter therefore reports a stable app-owned stage (`probing`, `analyzing`, `buildingTimeline`, `rendering`, `writing`) and may parse percentage/ETA only for its pinned engine version. If percentage parsing fails, the stage remains visible with an indeterminate progress bar.

Cancellation terminates the child and its descendants, waits for termination, removes incomplete temporary files, and returns a typed cancelled result. Cancellation is not presented as an error.

### 7.4 Upstream timeline stability

Auto-Editor v3 is partially stable. The domain model must not expose v3 objects. Parsing and serialization live exclusively inside a versioned adapter module with fixture-based contract tests.

## 8. Project and cache data

### 8.1 `.gapless` project

The project is UTF-8 JSON with a required schema version. Unknown fields are preserved when practical and ignored when reading. Time ranges use integer microseconds in source time to avoid floating-point drift.

Conceptual schema:

```json
{
  "schemaVersion": 1,
  "appVersion": "0.1.0",
  "source": {
    "relativePath": "media/interview.mp4",
    "absolutePath": "/Users/example/media/interview.mp4",
    "size": 123456789,
    "modifiedAt": "2026-07-11T12:00:00Z",
    "fingerprint": "sha256:..."
  },
  "engine": {
    "name": "auto-editor",
    "version": "pinned-by-app-release"
  },
  "settings": {
    "method": "audio",
    "thresholdDb": -19,
    "marginBeforeUs": 200000,
    "marginAfterUs": 200000,
    "inactiveAction": "cut"
  },
  "detectedSegments": [],
  "manualOverrides": [],
  "ui": {
    "previewMode": "edited",
    "timelineZoom": 1.0,
    "sidebarWidth": 264,
    "waveformHeight": 52
  }
}
```

`fingerprint` is calculated from file metadata plus bounded content samples rather than hashing an entire multi-gigabyte source during import. A full hash is unnecessary for source relocation and would harm the beginner experience.

### 8.2 Path resolution

On open, the app tries the relative path from the project file first, then the saved absolute path. The selected file must match the stored fingerprint. If neither path resolves, the Relocate flow asks the user to choose a source and verifies it before opening the timeline.

### 8.3 Autosave

- First import creates a draft in the platform application-data directory.
- Changes are saved after a short idle debounce and before normal application exit.
- Autosave writes a new temporary file, flushes it, then renames it over the previous revision.
- At least one previous valid revision is retained for recovery.
- Save As writes the portable project and switches future autosaves to it.
- Autosave failures leave the project editable and show a persistent actionable status.

### 8.4 Disposable cache

The cache lives in platform cache storage and is keyed by source fingerprint, engine version, analysis method, and settings. It may contain:

- Full-resolution Auto-Editor levels.
- Downsampled waveform tiles.
- Generated upstream v3 files.
- Preview proxies or thumbnails when required.
- Bounded recent engine logs.

Deleting the cache cannot delete projects, manual decisions, or source media.

## 9. Error handling

Errors are typed and mapped to actionable user messages.

| Failure | User experience | State handling |
| --- | --- | --- |
| Unsupported or corrupt media | Explain that the file could not be read; offer diagnostics | Keep empty/current project unchanged |
| Audio method on a video without audio | Offer Motion analysis | Preserve the imported project |
| Source moved | Open Relocate flow | Do not discard timeline or overrides |
| Source contents changed | Explain that analysis must be refreshed | Keep overrides; invalidate detected/cache data |
| Bundled engine missing or checksum mismatch | Block processing and show reinstall instructions | Project remains readable |
| Analysis failure | Keep last successful timeline and show retry | Do not replace it with partial data |
| Export destination unavailable | Ask for another destination | Do not start rendering |
| Render failure | Show concise reason, Retry, and Copy Diagnostics | Preserve project; remove partial output |
| Disk becomes full | Stop safely and identify affected path | Preserve project and prior output |
| User cancellation | Return to ready state without error styling | Remove temporary analysis/render files |
| Autosave failure | Persistent Saving failed state with Retry/Save As | Keep changes in memory and recovery buffer |

## 10. Security and privacy

- Core features require no network connection.
- Source media never leaves the device.
- No telemetry, accounts, advertising, or analytics are included.
- Processes are launched directly with structured arguments; no shell is invoked.
- The application validates its bundled engine using a release manifest and checksum.
- Engine logs are bounded and redact unrelated environment values.
- Temporary files use private platform temporary directories and unpredictable names.
- Export uses a temporary destination and never truncates an existing target before successful completion is possible.
- File dialogs and drag-and-drop validate regular local files before analysis.

## 11. Packaging and release targets

### 11.1 MVP artifacts

- macOS 12 or newer: Apple Silicon and Intel DMG artifacts, signed and notarized.
- Windows 10 or newer: x64 signed installer.
- Linux x64: AppImage targeting a documented glibc baseline.
- Flatpak follows after MVP packaging is stable.

Each target is built on its native CI runner and contains the matching Auto-Editor binary, the first-party `gapless_process_host`, and playback libraries. The macOS host is nested signed with the application; Windows bundles it beside the app executable and Linux under the bundle `lib/` directory. Release artifacts include SHA-256 checksums, an SBOM, GPL source/build offer, and third-party notices.

### 11.2 Licensing

Gapless is GPL-3.0-or-later. This is the safest default for distributing a libmpv-based application because mpv is GPL by default unless built in its LGPL configuration. Auto-Editor source is public-domain/Unlicense, while its binary artifacts and FFmpeg/libmpv dependencies require per-build license review.

The release process records the exact dependency versions and build flags for every artifact. Codec patent availability is treated separately from copyright license compliance and may affect which encoders are enabled in particular distributions.

### 11.3 Updates

MVP releases use manual download and an optional non-intrusive link to the release page. A later signed automatic updater must verify both signature and version before replacing application files.

## 12. Testing strategy

### 12.1 Domain tests

- Project schema parsing and migrations.
- Integer time-range operations and normalization.
- Detection plus manual-override precedence.
- Original/Edited clock mapping.
- Cut skipping and fast-forward mapping.
- Undo/redo boundaries.
- Source fingerprint and relocation logic.

### 12.2 Engine contract tests

For each bundled Auto-Editor target:

- Probe known audio/video fixtures through `info --json`.
- Parse audio and motion `levels` output.
- Generate and parse v3 timelines for cut and speed actions.
- Serialize an effective v3 timeline and render it.
- Verify paths containing spaces, Unicode, quotes, and leading dashes are safe.
- Verify corrupt input, unsupported output, insufficient disk, non-zero exit, and cancellation mapping.
- Detect any upstream output drift before packaging.

### 12.3 Interface tests

- Widget tests for empty, analyzing, editing, saving, exporting, completed, and error states.
- Golden tests for dark and light themes at default and minimum window sizes.
- Keyboard focus, semantics, contrast, reduced-motion, and screen-reader checks.
- Timeline gesture tests for scrub, zoom, resize, and segment toggling.

### 12.4 End-to-end tests

On macOS, Windows, and Linux:

1. Import a fixture.
2. Complete analysis.
3. Change settings and wait for re-analysis.
4. Toggle at least one segment.
5. Save and close the project.
6. Reopen and verify decisions.
7. Export MP4.
8. Probe the result and verify expected streams and duration.

Additional end-to-end cases cover cancellation, crash recovery, moved sources, changed sources, read-only destinations, and cleanup of partial outputs.

## 13. Extensibility

The MVP keeps these extension seams without implementing their features:

- New analysis methods implement domain settings plus an engine-adapter mapping.
- New export formats implement an `ExportAdapter` without changing project segments.
- Batch processing becomes a queue of independent single-source projects.
- Multiple source videos require a new project schema version and multitrack domain model.
- Alternative playback or processing engines implement existing ports.
- Auto-Editor upgrades add a new versioned adapter and migrations only when domain semantics change.

No plugin system is included in the MVP. Stable internal ports are sufficient until a real external-extension use case exists.

## 14. Acceptance criteria

The MVP is ready for public release when all of the following are true:

- A new user can install the app and process a local video without installing dependencies.
- The app imports one supported local video and reports useful metadata.
- Audio and Motion analysis produce a visible waveform and keep/remove timeline.
- Threshold, margin, Cut out, and Fast-forward controls update the effective timeline.
- Original and Edited playback behave according to the displayed decisions.
- Every displayed segment can be manually changed between keep and remove.
- Projects autosave, Save As to `.gapless`, close, reopen, and recover after interruption.
- Export produces a playable MP4 matching the effective displayed timeline.
- Cancelling analysis or export leaves no misleading success state or corrupt final file.
- The app passes the defined domain, engine-contract, interface, end-to-end, accessibility, and installed-artifact checks on all release targets.
- Published artifacts include signatures where supported, checksums, SBOM, source/build instructions, GPL notices, and third-party notices.

## 15. References

- Auto-Editor repository: <https://github.com/WyattBlue/auto-editor>
- Auto-Editor v3 timeline: <https://auto-editor.com/docs/v3>
- Auto-Editor `levels`: <https://auto-editor.com/docs/subcommands/levels>
- Auto-Editor `info --json`: <https://auto-editor.com/docs/subcommands/info>
- `media_kit`: <https://github.com/media-kit/media-kit>
- mpv: <https://github.com/mpv-player/mpv>
- Approved UX package: `Desktop app for auto-editor.zip` supplied on 2026-07-11
