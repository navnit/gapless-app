# Gapless MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and package the approved Gapless MVP: a FOSS Flutter desktop app that opens one local video, analyzes it with bundled Auto-Editor, previews and edits keep/remove segments, autosaves the project, and exports an exact MP4.

**Architecture:** Implement an inward-pointing Flutter architecture: immutable domain types at the center, application coordinators around them, and file/process/playback adapters at the edge. Keep Auto-Editor v3 and command syntax inside one versioned adapter; both Edited preview and MP4 export consume the same app-owned effective timeline.

**Tech Stack:** Flutter 3.44.4, Dart 3.12.2, `media_kit` 1.2.6, `media_kit_video` 2.0.1, `media_kit_libs_video` 1.0.7, Flutter desktop plugins, Auto-Editor 31.2.0, JSON project files, GitHub Actions.

## Global Constraints

- License all Gapless source as GPL-3.0-or-later and include complete third-party notices.
- Target macOS 12+ on Apple Silicon and Intel, Windows 10+ x64, and Linux x64 AppImage.
- Core import, analysis, playback, project persistence, and export must work offline.
- Process exactly one local source video per project; do not add batch or multitrack support.
- Export MP4 only; do not expose NLE/timeline formats in the MVP UI.
- Use native platform window controls where custom controls reduce accessibility or correctness.
- Never invoke a shell for Auto-Editor; pass every argument as a discrete process argument.
- Keep source media read-only and write exports through a partial file followed by promotion.
- Use integer microseconds for all app-owned source-time ranges.
- Keep Auto-Editor representations out of domain and presentation libraries.
- Preserve the approved Gapless Studio UX, with Gapless naming and `.gapless` project files.
- Do not add a plugin system, cloud services, telemetry, accounts, automatic updates, or URL import.

## Planned File Structure

```text
lib/
  main.dart                              app entry point
  app/
    gapless_app.dart                     MaterialApp, theme, top-level routing
    app_dependencies.dart                production adapter wiring
  core/
    errors/app_failure.dart              typed user-actionable failures
    process/process_runner.dart          safe direct-process abstraction
    process/io_process_runner.dart       dart:io implementation and cancellation
    time/source_time_range.dart          integer source-time primitives
  features/
    project/
      domain/project_document.dart       project aggregate
      domain/source_reference.dart       relocation identity
      data/project_codec.dart            versioned JSON codec/migrations
      data/project_repository.dart       atomic file persistence
      application/autosave_controller.dart
    editor/
      domain/analysis_settings.dart
      domain/timeline_segment.dart
      domain/effective_timeline.dart
      presentation/editor_screen.dart
      presentation/editor_view_model.dart
      presentation/widgets/studio_toolbar.dart
      presentation/widgets/settings_sidebar.dart
      presentation/widgets/video_preview.dart
      presentation/widgets/timeline_view.dart
      presentation/widgets/timeline_painter.dart
      presentation/widgets/status_bar.dart
    engine/
      domain/engine_port.dart             typed engine contract
      domain/engine_models.dart
      data/auto_editor/auto_editor_adapter.dart
      data/auto_editor/auto_editor_locator.dart
      data/auto_editor/auto_editor_parsers.dart
      data/auto_editor/v3_codec.dart
    analysis/
      application/analysis_coordinator.dart
      data/analysis_cache.dart
    playback/
      domain/playback_port.dart
      data/media_kit_playback_adapter.dart
      application/edited_playback_controller.dart
    export/
      application/export_coordinator.dart
      presentation/export_dialog.dart
assets/
  engine/manifest.json                   exact engine versions/checksums
test/
  core/                                  domain/process unit tests
  features/                              feature unit/widget/contract tests
  fixtures/                              tiny media and Auto-Editor outputs
integration_test/
  editor_workflow_test.dart              installed-app workflow
tool/
  engine/fetch_engine.dart               verified engine acquisition
  release/verify_bundle.dart             artifact/SBOM/notices checks
.github/workflows/
  verify.yml                             analyze/test/contract jobs
  release.yml                            native package jobs
```

---

### Task 1: Bootstrap a Runnable GPL Flutter Desktop Shell

**Files:**
- Create: Flutter-generated `android`-free desktop scaffold in the repository root
- Verify: `LICENSE` contains the canonical GPL-3.0 text and README declares GPL-3.0-or-later
- Create: `lib/app/gapless_app.dart`
- Create: `lib/app/app_dependencies.dart`
- Modify: `lib/main.dart`
- Modify: `pubspec.yaml`
- Modify: `.gitignore`
- Test: `test/app/gapless_app_test.dart`

**Interfaces:**
- Produces: `GaplessApp({required AppDependencies dependencies})`
- Produces: `AppDependencies.empty()` as the temporary wiring seam used by later tasks

- [ ] **Step 1: Scaffold only desktop platforms without replacing existing docs**

Run:

```bash
flutter create --platforms=macos,windows,linux --org org.gapless --project-name gapless .
```

Expected: Flutter creates macOS, Windows, Linux, `lib`, and `test` files while preserving `docs/`. Restore `.superpowers/` in `.gitignore` if Flutter rewrites the file.

- [ ] **Step 2: Pin the approved dependency set and GPL metadata**

Set `pubspec.yaml` dependencies to:

```yaml
environment:
  sdk: ^3.12.0

dependencies:
  flutter:
    sdk: flutter
  collection: ^1.19.1
  crypto: ^3.0.6
  file_selector: ^1.0.4
  media_kit: 1.2.6
  media_kit_video: 2.0.1
  media_kit_libs_video: 1.0.7
  path: ^1.9.1
  path_provider: ^2.1.5

dev_dependencies:
  flutter_test:
    sdk: flutter
  integration_test:
    sdk: flutter
  flutter_lints: ^6.0.0
```

Add the complete GPL-3.0-or-later text to `LICENSE`, then run `flutter pub get` and commit `pubspec.lock`.

- [ ] **Step 3: Write the failing app-shell test**

```dart
testWidgets('shows the Gapless empty workspace', (tester) async {
  await tester.pumpWidget(
    GaplessApp(dependencies: AppDependencies.empty()),
  );

  expect(find.text('Gapless'), findsOneWidget);
  expect(find.text('Open Video'), findsOneWidget);
  expect(find.text('Drop a video here'), findsOneWidget);
});
```

Run: `flutter test test/app/gapless_app_test.dart`

Expected: FAIL because `GaplessApp` and `AppDependencies` do not exist.

- [ ] **Step 4: Implement the minimal production entry and empty Studio shell**

```dart
final class AppDependencies {
  const AppDependencies.empty();
}

final class GaplessApp extends StatelessWidget {
  const GaplessApp({required this.dependencies, super.key});
  final AppDependencies dependencies;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Gapless',
        debugShowCheckedModeBanner: false,
        themeMode: ThemeMode.system,
        home: const Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [Text('Gapless'), Text('Drop a video here'), Text('Open Video')],
            ),
          ),
        ),
      );
```

Initialize media playback once in `main.dart` with `MediaKit.ensureInitialized()` before `runApp`.

- [ ] **Step 5: Verify the scaffold and commit**

Run:

```bash
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build macos --debug
```

Expected: formatting, analysis, tests, and the native debug build all exit 0.

Commit:

```bash
git add LICENSE pubspec.yaml pubspec.lock lib test macos windows linux .gitignore
git commit -m "feat: bootstrap Flutter desktop application"
```

---

### Task 2: Implement Timeline Domain Semantics

**Files:**
- Create: `lib/core/time/source_time_range.dart`
- Create: `lib/features/editor/domain/analysis_settings.dart`
- Create: `lib/features/editor/domain/timeline_segment.dart`
- Create: `lib/features/editor/domain/effective_timeline.dart`
- Test: `test/core/time/source_time_range_test.dart`
- Test: `test/features/editor/domain/effective_timeline_test.dart`
- Test: `test/features/editor/domain/timeline_clock_test.dart`

**Interfaces:**
- Produces: `SourceTimeRange(startUs, endUs)`
- Produces: `TimelineSegment(range, action, rate, origin)`
- Produces: `EffectiveTimeline.compose({durationUs, detected, overrides})`
- Produces: `sourceUsForEditedUs(int)` and `editedUsForSourceUs(int)`

- [ ] **Step 1: Write failing range normalization tests**

```dart
test('rejects inverted ranges and clips overlaps', () {
  expect(() => SourceTimeRange(10, 9), throwsArgumentError);
  expect(
    SourceTimeRange(0, 10).intersection(SourceTimeRange(8, 15)),
    SourceTimeRange(8, 10),
  );
});
```

Run: `flutter test test/core/time/source_time_range_test.dart`

Expected: FAIL because `SourceTimeRange` is undefined.

- [ ] **Step 2: Implement the immutable time primitive**

```dart
final class SourceTimeRange {
  SourceTimeRange(this.startUs, this.endUs) {
    if (startUs < 0 || endUs <= startUs) throw ArgumentError.value([startUs, endUs]);
  }
  final int startUs;
  final int endUs;
  int get durationUs => endUs - startUs;

  SourceTimeRange? intersection(SourceTimeRange other) {
    final start = max(startUs, other.startUs);
    final end = min(endUs, other.endUs);
    return start < end ? SourceTimeRange(start, end) : null;
  }
}
```

Add value equality and `hashCode`; do not introduce floating-point seconds in this library.

- [ ] **Step 3: Write failing override-precedence and clock tests**

```dart
test('manual keep splits and overrides a detected cut', () {
  final timeline = EffectiveTimeline.compose(
    durationUs: 10_000_000,
    detected: [segment(0, 10, SegmentAction.cut)],
    overrides: [override(3, 6, SegmentAction.keep)],
  );
  expect(actions(timeline), ['cut:0-3', 'keep:3-6', 'cut:6-10']);
});

test('maps edited time across removed source ranges', () {
  final timeline = timelineWithCut(sourceSeconds: 10, cutStart: 3, cutEnd: 5);
  expect(timeline.sourceUsForEditedUs(4_000_000), 6_000_000);
  expect(timeline.editedDurationUs, 8_000_000);
});
```

Expected: FAIL because timeline composition and clock mapping are undefined.

- [ ] **Step 4: Implement normalization, precedence, and time mapping**

Use these domain declarations exactly:

```dart
enum SegmentAction { keep, cut, fastForward }
enum SegmentOrigin { detected, manual }
enum AnalysisMethod { audio, motion }
enum InactiveBehavior { cut, fastForward }

final class AnalysisSettings {
  const AnalysisSettings({
    required this.method,
    required this.thresholdDb,
    required this.marginBeforeUs,
    required this.marginAfterUs,
    required this.inactiveBehavior,
    this.fastForwardRate = 4.0,
  });
  final AnalysisMethod method;
  final double thresholdDb;
  final int marginBeforeUs;
  final int marginAfterUs;
  final InactiveBehavior inactiveBehavior;
  final double fastForwardRate;
}

final class TimelineSegment {
  const TimelineSegment({
    required this.range,
    required this.action,
    this.rate = 1.0,
    required this.origin,
  });
  final SourceTimeRange range;
  final SegmentAction action;
  final double rate;
  final SegmentOrigin origin;
}
```

`EffectiveTimeline.compose` must collect every boundary, evaluate the last matching manual override before detection, merge adjacent identical effective actions, clip to `[0, durationUs)`, and reject non-finite or out-of-range rates. A cut contributes zero edited duration; fast-forward contributes `sourceDuration / rate`.

- [ ] **Step 5: Verify and commit**

Run: `flutter test test/core/time test/features/editor/domain`

Expected: all domain tests pass with no Flutter binding required.

Commit:

```bash
git add lib/core/time lib/features/editor/domain test/core/time test/features/editor/domain
git commit -m "feat: add normalized editing timeline domain"
```

---

### Task 3: Add Versioned Project JSON, Relocation, and Atomic Autosave

**Files:**
- Create: `lib/core/errors/app_failure.dart`
- Create: `lib/features/project/domain/source_reference.dart`
- Create: `lib/features/project/domain/project_document.dart`
- Create: `lib/features/project/data/project_codec.dart`
- Create: `lib/features/project/data/project_repository.dart`
- Create: `lib/features/project/application/autosave_controller.dart`
- Test: `test/features/project/data/project_codec_test.dart`
- Test: `test/features/project/data/project_repository_test.dart`
- Test: `test/features/project/application/autosave_controller_test.dart`
- Test fixture: `test/fixtures/projects/v1_audio_cut.gapless`

**Interfaces:**
- Consumes: Task 2 domain types
- Produces: `ProjectDocument`, `ProjectCodec.decode/encode`, `ProjectRepository.load/saveAtomic`
- Produces: `AutosaveController.markChanged(ProjectDocument)` and `flush()`

- [ ] **Step 1: Write a failing v1 project round-trip test**

```dart
test('round trips v1 without losing source-time decisions', () {
  final decoded = ProjectCodec().decode(fixture('v1_audio_cut.gapless'));
  final encoded = ProjectCodec().encode(decoded);
  final again = ProjectCodec().decode(encoded);
  expect(again, decoded);
  expect(again.schemaVersion, 1);
});
```

Expected: FAIL because project types and codec do not exist.

- [ ] **Step 2: Implement explicit project models and JSON codec**

```dart
final class ProjectDocument {
  const ProjectDocument({
    required this.schemaVersion,
    required this.appVersion,
    required this.source,
    required this.settings,
    required this.detectedSegments,
    required this.manualOverrides,
    required this.ui,
  });
  static const currentSchemaVersion = 1;
  // fields use concrete immutable value objects; no Map leaks beyond ProjectCodec
}
```

`ProjectCodec.decode` must reject missing required keys, unsupported future schema versions, non-integer microseconds, invalid actions, and invalid rates with `ProjectFormatFailure`. Encode JSON with two-space indentation and a trailing newline for readable diffs.

Define these supporting values in the same step:

```dart
sealed class AppFailure implements Exception {
  const AppFailure();
}
final class ProjectFormatFailure extends AppFailure {
  const ProjectFormatFailure(this.reason);
  final String reason;
}
final class ProjectSaveFailure extends AppFailure {
  const ProjectSaveFailure(this.path, this.cause);
  final Uri path;
  final Object cause;
}

final class SourceReference {
  const SourceReference({
    required this.relativePath,
    required this.absolutePath,
    required this.fingerprint,
  });
  final String relativePath;
  final String absolutePath;
  final SourceFingerprint fingerprint;
}

enum PreviewMode { original, edited }
final class ProjectUiState {
  const ProjectUiState({
    required this.previewMode,
    required this.timelineZoom,
    required this.sidebarWidth,
    required this.waveformHeight,
  });
  final PreviewMode previewMode;
  final double timelineZoom;
  final double sidebarWidth;
  final double waveformHeight;
}

final class RecoveryCandidate {
  const RecoveryCandidate(this.uri, this.savedAtUtc, this.document);
  final Uri uri;
  final DateTime savedAtUtc;
  final ProjectDocument document;
}
```

Implement value equality for every project/domain value used in tests. When resolving a moved source, use file size plus sampled SHA-256 as identity; modified time is a cheap change hint but must not reject an otherwise identical copied file.

- [ ] **Step 3: Write failing atomic-save and recovery tests**

```dart
test('failed replacement leaves the previous project readable', () async {
  final fs = FaultInjectingFileSystem(failOnPromote: true);
  final repository = ProjectRepository(fileSystem: fs);
  await repository.seed(path, oldProject);
  await expectLater(repository.saveAtomic(path, newProject), throwsA(isA<ProjectSaveFailure>()));
  expect(await repository.load(path), oldProject);
});
```

Also test relative-path-first resolution, absolute-path fallback, fingerprint mismatch, one previous revision, and recovery selection.

- [ ] **Step 4: Implement source fingerprinting and atomic repository behavior**

Define:

```dart
abstract interface class SourceFingerprinter {
  Future<SourceFingerprint> fingerprint(Uri source);
}

final class SourceFingerprint {
  const SourceFingerprint({
    required this.size,
    required this.modifiedAtUtc,
    required this.sampledSha256,
  });
  final int size;
  final DateTime modifiedAtUtc;
  final String sampledSha256;
}

abstract interface class ProjectFileSystem {
  Future<List<int>> readBytes(Uri file);
  Future<void> writeAndFlush(Uri file, List<int> bytes);
  Future<void> rename(Uri from, Uri to);
  Future<void> copy(Uri from, Uri to);
  Future<bool> exists(Uri file);
  Future<void> deleteIfExists(Uri file);
}

abstract interface class ProjectStore {
  Future<ProjectDocument> load(Uri project);
  Future<void> saveAtomic(Uri project, ProjectDocument document);
  Future<RecoveryCandidate?> recoveryFor(Uri project);
}
```

Sample fixed-size blocks from the beginning, middle, and end plus file size; hash the framed bytes with SHA-256. Save to the target path plus `.tmp-` and 32 cryptographically random hexadecimal characters, flush, retain the target path plus `.previous`, and rename. Do not hash an entire media file during import.

- [ ] **Step 5: Implement and test debounced autosave**

`AutosaveController` accepts an injected `Duration delay`, `ProjectStore`, and clock/timer factory. `markChanged` increments a revision; only mark `saved` when the same revision finishes writing. `flush` bypasses the debounce. A failure exposes `AutosaveStatus.failed(failure)` without dropping the in-memory document.

```dart
sealed class AutosaveStatus { const AutosaveStatus(); }
final class AutosaveIdle extends AutosaveStatus { const AutosaveIdle(); }
final class AutosaveSaving extends AutosaveStatus { const AutosaveSaving(this.revision); final int revision; }
final class AutosaveSaved extends AutosaveStatus { const AutosaveSaved(this.revision); final int revision; }
final class AutosaveFailed extends AutosaveStatus { const AutosaveFailed(this.revision, this.failure); final int revision; final AppFailure failure; }
```

Run: `flutter test test/features/project`

Expected: codec, atomic-write, recovery, relocation, and fake-time debounce tests all pass.

- [ ] **Step 6: Commit**

```bash
git add lib/core/errors lib/features/project test/features/project test/fixtures/projects
git commit -m "feat: add project persistence and autosave"
```

---

### Task 4: Define the Engine Port and Safe Process Runner

**Files:**
- Modify: `lib/core/errors/app_failure.dart`
- Create: `lib/core/process/process_runner.dart`
- Create: `lib/core/process/io_process_runner.dart`
- Create: `lib/features/engine/domain/engine_models.dart`
- Create: `lib/features/engine/domain/engine_port.dart`
- Create: `test/fixtures/process/capture_args.dart`
- Test: `test/core/process/io_process_runner_test.dart`
- Test helper: `test/helpers/fake_process_runner.dart`

**Interfaces:**
- Produces: `ProcessRequest(executable, arguments, workingDirectory, environment)`
- Produces: `RunningProcess.stdoutLines`, `stderrLines`, `exitCode`, `cancel()`
- Produces: `EngineTask<T>` and `EnginePort`

- [ ] **Step 1: Write failing argument-safety and cancellation tests**

```dart
test('passes hostile-looking paths as one argument without a shell', () async {
  final capturePath = temp.childFile('arguments.json').path;
  final request = ProcessRequest(
    executable: Platform.resolvedExecutable,
    arguments: [captureScriptPath, capturePath, '--', '/tmp/a; echo pwned "quoted".mp4'],
  );
  final running = await runner.start(request);
  expect(await running.exitCode, 0);
  expect(jsonDecode(await File(capturePath).readAsString()), request.arguments.skip(2).toList());
});
```

The fixture script is complete and platform-neutral:

```dart
import 'dart:convert';
import 'dart:io';

void main(List<String> arguments) {
  final output = File(arguments.first);
  output.writeAsStringSync(jsonEncode(arguments.skip(1).toList()), flush: true);
}
```

Add a cancellation test that starts the fixture process, calls `cancel`, observes a cancelled typed result, and confirms no success exit is emitted.

- [ ] **Step 2: Implement direct process contracts**

```dart
final class ProcessRequest {
  const ProcessRequest({
    required this.executable,
    required this.arguments,
    this.workingDirectory,
    this.environment = const {},
  });
  final String executable;
  final List<String> arguments;
  final String? workingDirectory;
  final Map<String, String> environment;
}

abstract interface class ProcessRunner {
  Future<RunningProcess> start(ProcessRequest request);
}

abstract interface class RunningProcess {
  int get pid;
  Stream<String> get stdoutLines;
  Stream<String> get stderrLines;
  Future<int> get exitCode;
  Future<void> cancel();
}
```

`IoProcessRunner` must call `Process.start(executable, arguments, runInShell: false)`, decode lines with replacement for invalid UTF-8, bound captured diagnostics, and make `cancel()` idempotent. On Windows, start `taskkill.exe` directly with `['/PID', process.pid.toString(), '/T', '/F']` for tree cleanup; on POSIX, terminate then force-kill after a bounded grace period.

- [ ] **Step 3: Define typed engine tasks**

```dart
abstract interface class EngineTask<T> {
  Stream<EngineProgress> get progress;
  Future<T> get result;
  Future<void> cancel();
}

abstract interface class EnginePort {
  EngineTask<MediaMetadata> probe(Uri source);
  EngineTask<AnalysisLevels> levels(Uri source, AnalysisMethod method);
  EngineTask<DetectedTimeline> detect(Uri source, AnalysisSettings settings);
  EngineTask<Uri> render(RenderRequest request);
}
```

Define the engine models in the same task:

```dart
final class SizeInt {
  const SizeInt(this.width, this.height);
  final int width;
  final int height;
}

final class MediaMetadata {
  const MediaMetadata({
    required this.durationUs,
    required this.timebaseNumerator,
    required this.timebaseDenominator,
    required this.resolution,
    required this.videoCodec,
    required this.hasAudio,
    required this.sampleRate,
    required this.audioLayout,
  });
  final int durationUs;
  final int timebaseNumerator;
  final int timebaseDenominator;
  final SizeInt resolution;
  final String videoCodec;
  final bool hasAudio;
  final int sampleRate;
  final String audioLayout;
}

final class AnalysisLevels {
  const AnalysisLevels({required this.samples, required this.samplePeriodUs});
  final List<int> samples; // normalized unsigned 16-bit values
  final int samplePeriodUs;
}

final class DetectedTimeline {
  const DetectedTimeline({required this.durationUs, required this.segments});
  final int durationUs;
  final List<TimelineSegment> segments;
}

enum RenderPreset { smaller, balanced, higherQuality }

final class RenderRequest {
  const RenderRequest({
    required this.source,
    required this.metadata,
    required this.timeline,
    required this.partialDestination,
    required this.preset,
  });
  final Uri source;
  final MediaMetadata metadata;
  final EffectiveTimeline timeline;
  final Uri partialDestination;
  final RenderPreset preset;
}

enum EngineStage { probing, analyzing, buildingTimeline, rendering, writing }

final class EngineProgress {
  const EngineProgress({required this.stage, this.percent, this.eta});
  final EngineStage stage;
  final double? percent;
  final Duration? eta;
}
```

Extend the existing `AppFailure` hierarchy with concrete `SourceMissingFailure`, `SourceChangedFailure`, `EngineMissingFailure`, `EngineChecksumFailure`, `EngineContractFailure`, `MediaReadFailure`, `DiskFullFailure`, and `OperationCancelled` types; each carries only structured fields, never preformatted UI copy.

Implement value equality for `SizeInt`, `MediaMetadata`, `AnalysisLevels`, `DetectedTimeline`, `RenderRequest`, and `EngineProgress`; tests must not compare object identity.

- [ ] **Step 4: Verify and commit**

Run:

```bash
flutter test test/core/process
flutter analyze
```

Expected: process tests pass on the current OS; CI will run the same contract on every target OS.

Commit:

```bash
git add lib/core lib/features/engine/domain test/core test/helpers test/fixtures/process
git commit -m "feat: add secure engine process contracts"
```

---

### Task 5: Implement the Pinned Auto-Editor 31.2.0 Adapter

**Files:**
- Create: `assets/engine/manifest.json`
- Create: `lib/features/engine/data/auto_editor/auto_editor_locator.dart`
- Create: `lib/features/engine/data/auto_editor/auto_editor_parsers.dart`
- Create: `lib/features/engine/data/auto_editor/v3_codec.dart`
- Create: `lib/features/engine/data/auto_editor/auto_editor_adapter.dart`
- Create: `tool/engine/fetch_engine.dart`
- Create: `third_party/auto-editor/NOTICE.md`
- Test: `test/features/engine/data/auto_editor_parsers_test.dart`
- Test: `test/features/engine/data/v3_codec_test.dart`
- Test: `test/features/engine/data/auto_editor_adapter_test.dart`
- Fixtures: `test/fixtures/auto_editor/31.2.0/*`

**Interfaces:**
- Consumes: `ProcessRunner`, `EnginePort`, Task 2 domain types
- Produces: `AutoEditorAdapter implements EnginePort`
- Produces: `V3Codec.decodeDetected` and `encodeEffective`

- [ ] **Step 1: Record the exact engine manifest and fixture outputs**

Use this schema:

```json
{
  "engine": "auto-editor",
  "version": "31.2.0",
  "targets": {
    "macos-arm64": {
      "asset": "auto-editor-macos-arm64",
      "url": "https://github.com/WyattBlue/auto-editor/releases/download/31.2.0/auto-editor-macos-arm64",
      "installedFile": "auto-editor",
      "sha256": "12cad2d0887bf44e6406e13b2cb7f32bd20d7aafb46b495c4b38eea2af590b27"
    },
    "macos-x64": {
      "asset": "auto-editor-macos-x86_64",
      "url": "https://github.com/WyattBlue/auto-editor/releases/download/31.2.0/auto-editor-macos-x86_64",
      "installedFile": "auto-editor",
      "sha256": "124db9cbe80b980d527f3d16fb50fed4133064887227aa4d1f0ad5adb3a8e65e"
    },
    "windows-x64": {
      "asset": "auto-editor-windows-x86_64.exe",
      "url": "https://github.com/WyattBlue/auto-editor/releases/download/31.2.0/auto-editor-windows-x86_64.exe",
      "installedFile": "auto-editor.exe",
      "sha256": "ab7457f67dc41396841777cc4af625bb6372973af99ba2e43dac416cda07aadc"
    },
    "linux-x64": {
      "asset": "auto-editor-linux-x86_64",
      "url": "https://github.com/WyattBlue/auto-editor/releases/download/31.2.0/auto-editor-linux-x86_64",
      "installedFile": "auto-editor",
      "sha256": "4065f5c83210dcad2f53bda8160b7e147b9732ae6e1e9bceb62b0ea256181d6e"
    }
  }
}
```

These digests come from the GitHub release asset metadata. `fetch_engine.dart` downloads only the matching configured URL, verifies SHA-256, and refuses redirects to a different host.

- [ ] **Step 2: Write failing metadata and levels parser tests**

```dart
test('parses machine-readable media metadata', () {
  final metadata = AutoEditorParsers.parseInfoJson(fixtureText('info.json'));
  expect(metadata.resolution, const SizeInt(1920, 1080));
  expect(metadata.durationUs, 494000000);
  expect(metadata.videoCodec, 'h264');
});

test('parses @start levels without accepting non-finite values', () {
  expect(
    AutoEditorParsers.parseLevels('@start\n0.0\n0.5\n1.0\n', samplePeriodUs: 33_367).samples,
    [0, 32768, 65535],
  );
  expect(
    () => AutoEditorParsers.parseLevels('@start\nnan\n', samplePeriodUs: 33_367),
    throwsFormatException,
  );
});
```

The adapter derives `samplePeriodUs` from the detected timeline timebase and passes it explicitly; the text parser never guesses timing.

- [ ] **Step 3: Write failing v3 decode/encode fidelity tests**

Decode the fixture generated by `auto-editor source.mp4 --export v3`, reconstruct omitted source gaps as cut segments, and verify timebase conversion. Encode an effective keep/cut/fast-forward timeline and assert that a decode produces equivalent source-time actions within one timebase tick.

```dart
expect(
  V3Codec().decodeDetected(V3Codec().encodeEffective(timeline, metadata)),
  equivalentTimeline(timeline, toleranceUs: metadata.frameDurationUs),
);
```

- [ ] **Step 4: Implement version-contained parsing and serialization**

`V3Codec` must accept only `version == '3'`, one source, and base audio/video layers required by the MVP. Convert rational timebase ticks using integer numerator/denominator arithmetic. Omit cut ranges from v3 tracks and emit effects such as `speed:4.0` using the validated segment rate for fast-forward ranges. Reject overlapping/multisource inputs with `EngineContractFailure` rather than leaking v3 objects.

- [ ] **Step 5: Write failing adapter request tests**

With `FakeProcessRunner`, assert exact argument arrays:

```dart
expect(fake.lastRequest.arguments, [
  source.toFilePath(), '--edit', 'audio:-19dB', '--margin', '0.2s,0.2s',
  '--export', 'v3', '-o', temporaryV3.toFilePath(),
]);
```

Probe must use `['info', sourcePath, '--json']`; levels must use `['levels', sourcePath, '--edit', methodExpression]`; render must use `[v3Path, '-o', partialMp4Path]` plus validated encoding arguments.

- [ ] **Step 6: Implement adapter, locator, diagnostics, and verify**

The locator checks the platform-specific installed path, executable permission, manifest version, SHA-256, and `--version` output. Progress regexes are private to the 31.2.0 adapter and fall back to stage-only progress.

Run:

```bash
flutter test test/features/engine
dart run tool/engine/fetch_engine.dart --verify-only
flutter analyze
```

Expected: parser, round-trip, request, checksum, error-mapping, and cancellation tests pass.

Commit:

```bash
git add assets/engine lib/features/engine/data tool/engine third_party test/features/engine test/fixtures/auto_editor
git commit -m "feat: integrate pinned Auto-Editor engine"
```

---

### Task 6: Coordinate Analysis, Debouncing, and Disposable Cache

**Files:**
- Create: `lib/features/analysis/data/analysis_cache.dart`
- Create: `lib/features/analysis/application/analysis_coordinator.dart`
- Test: `test/features/analysis/data/analysis_cache_test.dart`
- Test: `test/features/analysis/application/analysis_coordinator_test.dart`

**Interfaces:**
- Consumes: `EnginePort`, `ProjectDocument`, `EffectiveTimeline`
- Produces: `AnalysisCoordinator.states` and `request(project)`
- Produces: `AnalysisCacheKey(sourceFingerprint, engineVersion, settings)`

- [ ] **Step 1: Write failing stale-result and debounce tests**

```dart
test('publishes only the newest requested analysis', () async {
  coordinator.request(projectWithThreshold(-30));
  coordinator.request(projectWithThreshold(-19));
  engine.completeFirst(oldTimeline);
  engine.completeSecond(newTimeline);
  expect(await coordinator.states.lastWhere(isReady), readyWith(newTimeline));
});
```

Use a fake timer to prove rapid slider changes cause one detection call after 250 ms and that the last successful timeline remains available during re-analysis.

- [ ] **Step 2: Implement content-addressed cache behavior**

Cache `AnalysisLevels` and detected v3 output separately. Key with sampled source fingerprint, exact engine version, method, threshold, margin, and inactive action. Write cache entries atomically. A corrupt cache entry is deleted and treated as a miss, never as a project failure.

```dart
final class AnalysisCacheKey {
  const AnalysisCacheKey({
    required this.sampledSha256,
    required this.engineVersion,
    required this.settings,
  });
  final String sampledSha256;
  final String engineVersion;
  final AnalysisSettings settings;
  String canonicalJson() => jsonEncode({
        'sampledSha256': sampledSha256,
        'engineVersion': engineVersion,
        'method': settings.method.name,
        'thresholdDb': settings.thresholdDb,
        'marginBeforeUs': settings.marginBeforeUs,
        'marginAfterUs': settings.marginAfterUs,
        'inactiveBehavior': settings.inactiveBehavior.name,
        'fastForwardRate': settings.fastForwardRate,
      });
  String get stableKey => sha256.convert(utf8.encode(canonicalJson())).toString();
}
```

The standard Dart JSON encoder round-trips finite doubles and map insertion order is fixed by the literal above.

- [ ] **Step 3: Implement coordinator state machine**

```dart
sealed class AnalysisState {
  const AnalysisState();
}
final class AnalysisIdle extends AnalysisState {}
final class AnalysisRunning extends AnalysisState {
  const AnalysisRunning(this.previous, this.progress);
  final EffectiveTimeline? previous;
  final EngineProgress progress;
}
final class AnalysisReady extends AnalysisState {
  const AnalysisReady(this.timeline, this.levels);
  final EffectiveTimeline timeline;
  final AnalysisLevels levels;
}
final class AnalysisFailed extends AnalysisState {
  const AnalysisFailed(this.failure, this.previous);
  final AppFailure failure;
  final EffectiveTimeline? previous;
}
```

Generation IDs must prevent cancelled/stale tasks from publishing. Apply manual overrides locally after detection.

- [ ] **Step 4: Verify and commit**

Run: `flutter test test/features/analysis`

Commit:

```bash
git add lib/features/analysis test/features/analysis
git commit -m "feat: coordinate cached video analysis"
```

---

### Task 7: Implement media_kit Playback and Edited-Time Scheduling

**Files:**
- Create: `lib/features/playback/domain/playback_port.dart`
- Create: `lib/features/playback/data/media_kit_playback_adapter.dart`
- Create: `lib/features/playback/application/edited_playback_controller.dart`
- Test: `test/features/playback/application/edited_playback_controller_test.dart`
- Test: `test/features/playback/data/media_kit_playback_adapter_test.dart`

**Interfaces:**
- Consumes: `EffectiveTimeline`
- Produces: `PlaybackPort.open/play/pause/seek/setRate`
- Produces: `EditedPlaybackController.setMode`, `seekEdited`, and position streams

- [ ] **Step 1: Write failing cut-skip and rate-transition tests**

```dart
test('seeks to the next kept boundary when playback enters a cut', () async {
  final player = FakePlaybackPort(positionUs: 2_900_000, playing: true);
  final controller = EditedPlaybackController(player: player, timeline: cutFrom3To5);
  player.emitPosition(3_010_000);
  expect(player.lastSeekUs, 5_000_000);
});

test('sets and resets rate around a fast-forward segment', () async {
  player.emitPosition(3_010_000);
  expect(player.lastRate, 4.0);
  player.emitPosition(5_010_000);
  expect(player.lastRate, 1.0);
});
```

- [ ] **Step 2: Define a player-independent playback port**

```dart
abstract interface class PlaybackPort {
  Stream<int> get positionUs;
  Stream<bool> get playing;
  Future<void> open(Uri source);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(int sourceUs);
  Future<void> setRate(double rate);
  Future<void> dispose();
}
```

- [ ] **Step 3: Implement EditedPlaybackController**

Serialize position reactions so repeated events do not race. In Original mode always use rate 1 and never skip. In Edited mode, skip cuts, set fast-forward rates, expose edited and source clocks, and pause at the effective end. Guard seeks with one-frame tolerance to prevent feedback loops.

- [ ] **Step 4: Implement the media_kit adapter**

Own one `Player` and `VideoController`. Convert `Duration` to integer microseconds. Configure local-file playback, hardware decoding, no network protocols beyond `file`, and custom controls disabled because Gapless renders its own transport row. Dispose every stream subscription.

- [ ] **Step 5: Verify and commit**

Run:

```bash
flutter test test/features/playback
flutter analyze
```

Commit:

```bash
git add lib/features/playback test/features/playback
git commit -m "feat: add original and edited video playback"
```

---

### Task 8: Build the Interactive Waveform Timeline

**Files:**
- Create: `lib/features/editor/presentation/widgets/timeline_view.dart`
- Create: `lib/features/editor/presentation/widgets/timeline_painter.dart`
- Create: `lib/features/editor/presentation/timeline_view_model.dart`
- Test: `test/features/editor/presentation/timeline_view_model_test.dart`
- Test: `test/features/editor/presentation/timeline_view_test.dart`
- Golden: `test/goldens/timeline_dark.png`
- Golden: `test/goldens/timeline_light.png`

**Interfaces:**
- Consumes: `AnalysisLevels`, `EffectiveTimeline`, source position, theme tokens
- Produces: `TimelineIntent.seek(sourceUs)`, `toggle(range)`, `setZoom(zoom)`

Define the intent contract before the widget:

```dart
sealed class TimelineIntent { const TimelineIntent(); }
final class SeekTimelineIntent extends TimelineIntent { const SeekTimelineIntent(this.sourceUs); final int sourceUs; }
final class ToggleSegmentIntent extends TimelineIntent { const ToggleSegmentIntent(this.range); final SourceTimeRange range; }
final class SetTimelineZoomIntent extends TimelineIntent { const SetTimelineZoomIntent(this.zoom, this.anchorSourceUs); final double zoom; final int anchorSourceUs; }
```

- [ ] **Step 1: Write failing geometry and hit-test tests**

```dart
test('maps x coordinates through zoom and scroll into source time', () {
  final model = TimelineViewModel(durationUs: 10_000_000, viewportWidth: 1000, zoom: 2, scrollPx: 500);
  expect(model.sourceUsAtX(500), 5_000_000);
});

testWidgets('clicking a cut emits its exact source range', (tester) async {
  await tester.pumpWidget(timelineHarness(cutFrom3To5));
  await tester.tapAt(const Offset(400, 80));
  expect(intents.single, ToggleSegmentIntent(SourceTimeRange(3_000_000, 5_000_000)));
});
```

- [ ] **Step 2: Implement immutable timeline geometry**

Keep geometry, ticks, waveform downsampling, source-time conversion, and segment rectangles in `TimelineViewModel`. The painter receives already-computed drawing primitives; it does not read application controllers.

- [ ] **Step 3: Implement painter and interaction surface**

Paint bottom-aligned waveform bars, dashed amber threshold, kept/cut/fast-forward segment styles, manual markers, adaptive ruler, and red playhead. Use `Listener`/`GestureDetector` for scrub, segment toggle, wheel zoom anchored beneath the pointer, and horizontal scroll. Provide semantic labels such as `Removed segment, 3.0 to 5.0 seconds, activate to keep`.

- [ ] **Step 4: Add golden and resize tests**

Test dark/light themes at 1280×832 and the 960×640 minimum. Verify waveform heights 28, 52, and 170 px and sidebar-independent timeline layout.

Run:

```bash
flutter test test/features/editor/presentation --update-goldens
flutter test test/features/editor/presentation
```

Only the first command creates reviewed baseline images; the second must pass without rewriting them.

- [ ] **Step 5: Commit**

```bash
git add lib/features/editor/presentation test/features/editor/presentation test/goldens
git commit -m "feat: add editable waveform timeline"
```

---

### Task 9: Assemble the Approved Studio UI and Project Workflow

**Files:**
- Create: `lib/features/editor/presentation/editor_screen.dart`
- Create: `lib/features/editor/presentation/editor_view_model.dart`
- Create: `lib/features/editor/presentation/widgets/studio_toolbar.dart`
- Create: `lib/features/editor/presentation/widgets/settings_sidebar.dart`
- Create: `lib/features/editor/presentation/widgets/video_preview.dart`
- Create: `lib/features/editor/presentation/widgets/status_bar.dart`
- Create: `assets/fonts/InstrumentSans-VariableFont_wdth,wght.ttf`
- Create: `assets/fonts/OFL.txt`
- Create: `assets/fonts/SHA256SUMS`
- Modify: `lib/app/gapless_app.dart`
- Modify: `lib/app/app_dependencies.dart`
- Modify: `pubspec.yaml`
- Test: `test/features/editor/presentation/editor_screen_test.dart`
- Golden: `test/goldens/editor_dark_1280x832.png`
- Golden: `test/goldens/editor_light_1280x832.png`

**Interfaces:**
- Consumes: project, autosave, analysis, playback, and timeline interfaces
- Produces: approved empty/import/analyzing/ready/save-failed states

- [ ] **Step 1: Write a failing complete-screen widget test**

```dart
testWidgets('shows approved controls for a ready project', (tester) async {
  await tester.pumpWidget(editorHarness(readyProject));
  expect(find.text('Audio'), findsOneWidget);
  expect(find.text('Motion'), findsOneWidget);
  expect(find.text('THRESHOLD'), findsOneWidget);
  expect(find.text('MARGIN'), findsOneWidget);
  expect(find.text('Cut out'), findsOneWidget);
  expect(find.text('Fast-forward'), findsOneWidget);
  expect(find.text('Original'), findsOneWidget);
  expect(find.text('Edited'), findsOneWidget);
  expect(find.text('Export…'), findsOneWidget);
  expect(find.text('Saved'), findsOneWidget);
});
```

- [ ] **Step 2: Implement the Gapless-derived theme tokens and layout**

Use approved tokens: amber `#E3A63B`, dark background `#121316`, dark panel `#1A1C20`, light background `#E6E7E9`, light panel `#F5F5F6`, red playhead `#E25C4A`.

Bundle Instrument Sans and its OFL license from the official Google Fonts repository:

```bash
mkdir -p assets/fonts
curl -fL 'https://raw.githubusercontent.com/google/fonts/main/ofl/instrumentsans/InstrumentSans%5Bwdth%2Cwght%5D.ttf' -o 'assets/fonts/InstrumentSans-VariableFont_wdth,wght.ttf'
curl -fL 'https://raw.githubusercontent.com/google/fonts/main/ofl/instrumentsans/OFL.txt' -o assets/fonts/OFL.txt
shasum -a 256 assets/fonts/InstrumentSans-VariableFont_wdth,wght.ttf assets/fonts/OFL.txt > assets/fonts/SHA256SUMS
```

Commit these files so builds remain offline and reproducible. Register the variable font in `pubspec.yaml` as family `InstrumentSans`; set `ThemeData.fontFamily` to that exact name and add the OFL entry to third-party notices.

Build the fixed title/toolbar/status heights and resizable sidebar/timeline bounds from the spec. Persist pane sizes in project UI state.

- [ ] **Step 3: Wire one-video import and project lifecycle**

Use `file_selector` with a broad media filter, then let Auto-Editor validate support. On import: fingerprint, create draft, probe, open playback, request analysis, and autosave. If audio is absent while Audio is selected, present `Use Motion` instead of failing the whole project.

- [ ] **Step 4: Wire controls, undo/redo, Save As, and Recent Projects**

Threshold changes debounce analysis; manual segment toggles do not re-run the engine. Save As uses a `.gapless` extension. Store recent project URIs in a small versioned JSON preferences file, remove inaccessible entries lazily, and never delete project files from the Recent menu.

Implement an application-command stack containing settings changes and manual overrides. File import/export is excluded from undo.

- [ ] **Step 5: Add empty, analyzing, ready, and save-failed tests/goldens**

Verify keyboard focus order, Space play/pause suppression while typing, Ctrl/Cmd+S, Ctrl/Cmd+Shift+S, Ctrl/Cmd+Z, Ctrl/Cmd+Shift+Z, and Ctrl/Cmd+E. Test visible Saving…, Saved, and Saving failed with Retry/Save As states.

- [ ] **Step 6: Verify and commit**

Run:

```bash
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test test/features/editor test/app
```

Commit:

```bash
git add lib/app lib/features/editor test/app test/features/editor test/goldens
git commit -m "feat: assemble Gapless Studio workflow"
```

---

### Task 10: Render Exact MP4 Exports

**Files:**
- Create: `lib/features/export/application/export_coordinator.dart`
- Create: `lib/features/export/presentation/export_dialog.dart`
- Test: `test/features/export/application/export_coordinator_test.dart`
- Test: `test/features/export/presentation/export_dialog_test.dart`

**Interfaces:**
- Consumes: `EnginePort.render`, `EffectiveTimeline`, `MediaMetadata`
- Produces: `ExportCoordinator.start(ExportRequest)`, `cancel()`, and states

```dart
final class ExportRequest {
  const ExportRequest({
    required this.source,
    required this.metadata,
    required this.timeline,
    required this.destination,
    required this.preset,
  });
  final Uri source;
  final MediaMetadata metadata;
  final EffectiveTimeline timeline;
  final Uri destination;
  final RenderPreset preset;
}
```

- [ ] **Step 1: Write failing exact-snapshot and promotion tests**

```dart
test('renders the frozen effective timeline and promotes only after success', () async {
  final task = coordinator.start(request(timeline: originalTimeline, destination: output));
  project.applyOverride(laterEdit);
  engine.completeRender(partialOutput);
  await task;
  expect(engine.lastRender.timeline, originalTimeline);
  expect(fileSystem.exists(output), isTrue);
  expect(fileSystem.exists(partialOutput), isFalse);
});
```

Also prove failure/cancel preserves an existing destination and removes only the operation-owned partial file.

- [ ] **Step 2: Implement immutable export requests and coordinator states**

```dart
sealed class ExportState {}
final class ExportChoosing extends ExportState {}
final class ExportRunning extends ExportState {
  ExportRunning(this.stage, this.percent, this.eta);
  final EngineStage stage;
  final double? percent;
  final Duration? eta;
}
final class ExportComplete extends ExportState { ExportComplete(this.output); final Uri output; }
final class ExportFailed extends ExportState { ExportFailed(this.failure); final AppFailure failure; }
```

Freeze project metadata and effective segments before launching. Serialize to a unique operation directory, render to a sibling name such as `interview.edited.partial-550e8400-e29b-41d4-a716-446655440000.mp4`, fsync/close, then replace the user-approved target. Never silently overwrite without the platform save dialog confirming the target.

- [ ] **Step 3: Implement the three-phase MP4-only dialog**

Choose state: destination, one beginner quality choice (`Smaller`, `Balanced`, `Higher quality`) mapped to validated CRF/preset combinations under Advanced, Cancel, Export. Running state: stage, progress or indeterminate bar, ETA when available, Cancel. Complete state: output path, Show in Folder, Done.

- [ ] **Step 4: Verify and commit**

Run: `flutter test test/features/export`

Commit:

```bash
git add lib/features/export test/features/export
git commit -m "feat: export exact edited timeline to MP4"
```

---

### Task 11: Add Failure UX, Accessibility, and End-to-End Proof

**Files:**
- Create: `lib/core/errors/failure_presenter.dart`
- Create: `integration_test/editor_workflow_test.dart`
- Create: `integration_test/recovery_workflow_test.dart`
- Create: `test/accessibility/editor_accessibility_test.dart`
- Modify: feature presentation files to consume typed failure presentations
- Modify: `README.md`

**Interfaces:**
- Consumes: all feature states
- Produces: stable user-facing failure copy and installed-app workflows

- [ ] **Step 1: Write the failure mapping table as tests**

```dart
test('source missing offers relocation without discarding edits', () {
  final message = FailurePresenter.present(const SourceMissingFailure());
  expect(message.title, 'Source video not found');
  expect(message.primaryAction, FailureAction.relocate);
  expect(message.destructive, isFalse);
});
```

Cover corrupt media, no audio, source changed, engine missing/checksum mismatch, analysis failure with previous timeline, export destination, disk full, cancelled, and autosave failure.

- [ ] **Step 2: Implement concise failure presentation and diagnostics export**

Use these presentation-only types:

```dart
enum FailureAction { retry, relocate, useMotion, chooseDestination, saveAs, copyDiagnostics, reinstall }

final class FailurePresentation {
  const FailurePresentation({
    required this.title,
    required this.body,
    required this.primaryAction,
    this.secondaryAction,
    this.destructive = false,
  });
  final String title;
  final String body;
  final FailureAction primaryAction;
  final FailureAction? secondaryAction;
  final bool destructive;
}

abstract final class FailurePresenter {
  static FailurePresentation present(AppFailure failure) => switch (failure) {
        SourceMissingFailure() => const FailurePresentation(
            title: 'Source video not found',
            body: 'Locate the original video to continue editing this project.',
            primaryAction: FailureAction.relocate,
          ),
        OperationCancelled() => throw StateError('Cancellation is handled as a ready state'),
        _ => const FailurePresentation(
            title: 'Gapless could not finish this operation',
            body: 'Your project is safe. Retry or copy diagnostics for more detail.',
            primaryAction: FailureAction.retry,
            secondaryAction: FailureAction.copyDiagnostics,
          ),
      };
}
```

Expand the switch with one explicit branch for every tested failure; the fallback is only for forward-compatible unknown failures.

Keep raw stderr out of ordinary dialogs. `Copy Diagnostics` includes app/engine versions, platform, stage, bounded redacted output, and no environment dump. Cancellation maps back to Ready, not Failed.

- [ ] **Step 3: Write the end-to-end workflow test**

```dart
testWidgets('import analyze override save reopen and export', (tester) async {
  await app.launchWithFixtureEngine();
  await app.openVideo(fixtureVideo);
  await app.waitForAnalysisReady();
  await app.toggleFirstCut();
  await app.saveAs(projectPath);
  await app.restart();
  await app.openProject(projectPath);
  await app.exportTo(outputPath);
  expect(await probe(outputPath), hasExpectedStreamsAndDuration);
});
```

Use the real pinned Auto-Editor on native CI and tiny committed/generated fixtures. A fake engine may cover widget tests but cannot satisfy the integration job.

- [ ] **Step 4: Add accessibility tests and README user/build instructions**

Assert semantic labels for every transport/timeline control, logical traversal order, visible focus, minimum contrast, minimum interactive hit areas, and reduced-motion behavior. Document supported platforms, offline behavior, GPL license, manual engine-fetch step, development commands, and third-party notices.

- [ ] **Step 5: Run the complete local verification gate and commit**

Run:

```bash
dart format --output=none --set-exit-if-changed lib test integration_test tool
flutter analyze
flutter test
flutter test integration_test -d macos
git diff --check
```

Expected: every command exits 0. The matching CI jobs run `flutter test integration_test -d windows` on Windows and `flutter test integration_test -d linux` on Linux.

Commit:

```bash
git add lib test integration_test README.md
git commit -m "test: cover recovery accessibility and editor workflow"
```

---

### Task 12: Package Reproducible Native Releases

**Files:**
- Create: `tool/release/verify_bundle.dart`
- Create: `tool/release/tool_manifest.json`
- Create: `third_party/THIRD_PARTY_NOTICES.md`
- Create: `docs/building.md`
- Create: `.github/workflows/verify.yml`
- Create: `.github/workflows/release.yml`
- Create: `packaging/macos/package_dmg.sh`
- Create: `packaging/windows/gapless.iss`
- Create: `packaging/linux/AppRun`
- Create: `packaging/linux/gapless.desktop`
- Create: `packaging/linux/package_appimage.sh`
- Modify: `macos/Runner.xcodeproj/project.pbxproj` for nested engine copy/signing
- Modify: `windows/CMakeLists.txt` for engine installation
- Modify: `linux/CMakeLists.txt` for engine/lib installation
- Test: `test/tool/release/verify_bundle_test.dart`

**Interfaces:**
- Consumes: engine manifest, Flutter bundle, license inventory
- Produces: signed/notarized DMGs, signed Windows installer, Linux AppImage, SHA-256 sums, SBOM, and notices

- [ ] **Step 1: Write failing bundle-manifest tests**

```dart
test('release bundle contains the exact executable and notices', () async {
  final report = await BundleVerifier(manifest).verify(bundleRoot);
  expect(report.engineVersion, '31.2.0');
  expect(report.engineChecksumMatches, isTrue);
  expect(report.hasGplSourceOffer, isTrue);
  expect(report.hasThirdPartyNotices, isTrue);
});
```

- [ ] **Step 2: Install engine binaries at deterministic native paths**

- macOS: `Gapless.app/Contents/Resources/engine/auto-editor`; preserve executable mode, sign the nested Mach-O before signing the app, then notarize/staple.
- Windows: `%ProgramFiles%\Gapless\engine\auto-editor.exe`; include it in the installer manifest and sign both engine/app artifacts as required.
- Linux AppImage: `usr/lib/gapless/engine/auto-editor`; include compatible libmpv runtime libraries and record their licenses.

Update `AutoEditorLocator` tests to use these exact paths relative to `Platform.resolvedExecutable`.

Use built-in `hdiutil` in `package_dmg.sh`, Inno Setup 6 through `ISCC.exe` with `gapless.iss`, and `appimagetool` with the explicit AppDir assembled by `package_appimage.sh`. Store the chosen Inno Setup and appimagetool versions plus download SHA-256 values in `tool/release/tool_manifest.json`; the release scripts refuse tools that do not match that committed manifest.

- [ ] **Step 3: Add verification CI**

`verify.yml` runs format check, analyze, unit/widget/golden tests, engine fixture contracts, native debug build, and `git diff --check` on macOS, Windows, and Ubuntu. Cache only Flutter/pub and verified engine downloads keyed by manifest checksum.

- [ ] **Step 4: Add tagged release CI and compliance outputs**

`release.yml` triggers only on `v*` tags, builds natively, runs installed-artifact smoke tests, signs with environment-provided CI secrets, notarizes macOS, generates CycloneDX/SPDX SBOM, produces `SHA256SUMS`, and uploads source/build instructions alongside binaries. Secrets are never printed or made available to pull-request jobs.

Use four release matrix entries: `macos-arm64` with `auto-editor-macos-arm64`, `macos-x64` with `auto-editor-macos-x86_64`, `windows-x64`, and `linux-x64`. Publish separate Apple Silicon and Intel DMGs rather than a universal bundle so each signed app contains exactly one matching Auto-Editor executable.

- [ ] **Step 5: Run the release-candidate gate**

Run the common checks on each native runner:

```bash
flutter analyze
flutter test
```

Then run the platform-specific bundle check:

```bash
# macOS runner
flutter build macos --release
dart run tool/release/verify_bundle.dart --bundle build/macos/Build/Products/Release/Gapless.app

# Windows runner (PowerShell)
flutter build windows --release
dart run tool/release/verify_bundle.dart --bundle build/windows/x64/runner/Release

# Linux runner
flutter build linux --release
dart run tool/release/verify_bundle.dart --bundle build/linux/x64/release/bundle
```

Then install the artifact on a clean runner and execute the integration workflow against a tiny fixture. Expected: app launches, bundled engine checksum/version pass, analysis completes, MP4 renders, notices/SBOM exist, and no dependency installation is required.

- [ ] **Step 6: Commit**

```bash
git add tool/release third_party docs/building.md .github packaging macos windows linux test/tool
git commit -m "build: package reproducible desktop releases"
```

---

## Final MVP Verification

After Task 12, run the common gate from a clean clone on each target OS:

```bash
dart format --output=none --set-exit-if-changed lib test integration_test tool
flutter analyze
flutter test
git diff --check
git status --short
```

Run the native integration and bundle gate on its matching OS:

```bash
# macOS
flutter test integration_test -d macos
flutter build macos --release
dart run tool/release/verify_bundle.dart --bundle build/macos/Build/Products/Release/Gapless.app

# Windows (PowerShell)
flutter test integration_test -d windows
flutter build windows --release
dart run tool/release/verify_bundle.dart --bundle build/windows/x64/runner/Release

# Linux
flutter test integration_test -d linux
flutter build linux --release
dart run tool/release/verify_bundle.dart --bundle build/linux/x64/release/bundle
```

Expected:

- Every command exits 0.
- `git status --short` is empty.
- The installed app works without a separate Auto-Editor or libmpv installation.
- Import → analysis → manual override → autosave → reopen → MP4 export passes.
- The rendered MP4 matches the effective timeline within one source timebase tick.
- Cancelling or failing analysis/export leaves no corrupt final output and no lost project edits.
- Release artifacts contain checksums, SBOM, GPL source/build offer, and third-party notices.
