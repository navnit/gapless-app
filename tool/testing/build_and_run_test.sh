#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_SCRIPT="$ROOT_DIR/script/build_and_run.sh"
TEST_DIR="$(mktemp -d)"
FAKE_BIN="$TEST_DIR/bin"
CONFIG_HOME="$TEST_DIR/flutter-config"
COMMAND_LOG="$TEST_DIR/flutter-command"
ENV_LOG="$TEST_DIR/flutter-config-home"
PKILL_LOG="$TEST_DIR/pkill-command"

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

mkdir -p "$FAKE_BIN"

cat >"$FAKE_BIN/flutter" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$GAPLESS_TEST_COMMAND_LOG"
printf '%s\n' "$XDG_CONFIG_HOME" >"$GAPLESS_TEST_ENV_LOG"
SH

cat >"$FAKE_BIN/pkill" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$GAPLESS_TEST_PKILL_LOG"
SH

chmod +x "$FAKE_BIN/flutter" "$FAKE_BIN/pkill"

PATH="$FAKE_BIN:$PATH" \
  GAPLESS_FLUTTER_CONFIG_HOME="$CONFIG_HOME" \
  GAPLESS_FLUTTER_BUILD_DIR_RELATIVE="off-volume-build" \
  GAPLESS_TEST_COMMAND_LOG="$COMMAND_LOG" \
  GAPLESS_TEST_ENV_LOG="$ENV_LOG" \
  GAPLESS_TEST_PKILL_LOG="$PKILL_LOG" \
  "$RUN_SCRIPT"

test "$(cat "$COMMAND_LOG")" = "run -d macos"
test "$(cat "$ENV_LOG")" = "$CONFIG_HOME"
test "$(cat "$PKILL_LOG")" = "-x Gapless"
grep -F '"build-dir": "off-volume-build"' "$CONFIG_HOME/settings" >/dev/null

echo "build_and_run_test: PASS"
