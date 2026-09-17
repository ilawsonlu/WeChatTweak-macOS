#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="wechattweak"

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  echo "$APP_NAME is already running; refusing to interrupt a possible patch/sign operation." >&2
  exit 1
fi

swift build --package-path "$ROOT_DIR" -c release
BIN_DIR="$(swift build --package-path "$ROOT_DIR" -c release --show-bin-path)"
APP_BINARY="$BIN_DIR/$APP_NAME"
ARGS=(versions --config "$ROOT_DIR/config.json")

case "$MODE" in
  run)
    "$APP_BINARY" "${ARGS[@]}"
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY" "${ARGS[@]}"
    ;;
  --logs|logs|--telemetry|telemetry)
    "$APP_BINARY" "${ARGS[@]}"
    /usr/bin/log show --last 1m --info --style compact --predicate 'process == "wechattweak"'
    ;;
  --verify|verify)
    OUTPUT="$("$APP_BINARY" "${ARGS[@]}")"
    printf '%s\n' "$OUTPUT"
    grep -q 'Supported versions' <<<"$OUTPUT"
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
