# Auto-Editor 31.2.0 fixtures

These outputs were captured from the upstream Auto-Editor `31.2.0` release
(tag commit `576d6b1ecc5a86ebf4507e35e44b2f9d6fb824a5`) using the repository's
`example.mp4` fixture.

The macOS arm64 release asset was downloaded from the exact URL in
`assets/engine/manifest.json`. Its SHA-256 was verified as
`12cad2d0887bf44e6406e13b2cb7f32bd20d7aafb46b495c4b38eea2af590b27`, and
`--version` printed `31.2.0`.

Commands were run from the upstream source checkout so paths remain stable:

```text
auto-editor info example.mp4 --json
auto-editor levels example.mp4 --edit audio --timebase 30/1
auto-editor example.mp4 --edit audio:-19dB --margin 0.2s,0.2s --export v3 -o detected.v3
```

Contract references are the same upstream tag's `docs/src/docs/v3.md`,
`src/exports/json.nim`, `src/imports/json.nim`, `src/cmds/info.nim`, and
`src/cmds/levels.nim`.
