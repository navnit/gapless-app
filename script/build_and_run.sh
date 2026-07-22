#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Gapless"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLUTTER_CONFIG_HOME="${GAPLESS_FLUTTER_CONFIG_HOME:-/private/tmp/gapless-flutter-config}"
BUILD_ROOT="${GAPLESS_FLUTTER_BUILD_ROOT:-/private/tmp/gapless-build}"

if [ "$#" -gt 1 ]; then
  echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
  exit 2
fi

relative_build_dir() {
  local remaining="${ROOT_DIR#/}"
  local prefix=""

  while [ -n "$remaining" ]; do
    prefix="../$prefix"
    case "$remaining" in
      */*) remaining="${remaining#*/}" ;;
      *) remaining="" ;;
    esac
  done

  printf '%s%s' "$prefix" "${BUILD_ROOT#/}"
}

prepare_flutter_config() {
  local build_dir="${GAPLESS_FLUTTER_BUILD_DIR_RELATIVE:-$(relative_build_dir)}"

  mkdir -p "$FLUTTER_CONFIG_HOME"
  printf '{\n  "build-dir": "%s"\n}\n' "$build_dir" >"$FLUTTER_CONFIG_HOME/settings"
}

flutter_with_off_volume_build() {
  XDG_CONFIG_HOME="$FLUTTER_CONFIG_HOME" flutter "$@"
}

open_built_app() {
  /usr/bin/open -n "$BUILD_ROOT/macos/Build/Products/Debug/$APP_NAME.app"
}

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
prepare_flutter_config

case "$MODE" in
  run|--debug|debug|--logs|logs)
    flutter_with_off_volume_build run -d macos
    ;;
  --telemetry|telemetry)
    flutter_with_off_volume_build build macos --debug
    open_built_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --verify|verify)
    flutter_with_off_volume_build build macos --debug
    open_built_app
    for _ in {1..20}; do
      if pgrep -x "$APP_NAME" >/dev/null; then
        echo "$APP_NAME is running from $BUILD_ROOT"
        exit 0
      fi
      sleep 0.25
    done
    echo "$APP_NAME did not start within 5 seconds" >&2
    exit 1
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
