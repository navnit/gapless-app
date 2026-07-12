# Gapless

Gapless is a free and open-source desktop application that makes [Auto-Editor](https://github.com/WyattBlue/auto-editor) accessible through a focused visual workflow.

The planned application will run on macOS, Windows, and Linux. It will let users open one local video, detect silent or inactive sections, review the proposed edits on a waveform timeline, override individual keep/remove decisions, autosave the project, and export a finished MP4.

## Project status

Gapless is currently in the implementation phase. The approved product design and task-by-task implementation plan are available here:

- [Product design](docs/superpowers/specs/2026-07-11-gapless-desktop-design.md)
- [MVP implementation plan](docs/superpowers/plans/2026-07-11-gapless-mvp.md)

## Architecture

- Flutter desktop interface
- `media_kit`/libmpv video playback
- Bundled, version-pinned Auto-Editor processing engine
- Offline-first, non-destructive project workflow

## License

Gapless is licensed under the [GNU General Public License v3.0 or later](LICENSE).
