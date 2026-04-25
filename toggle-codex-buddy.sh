#!/usr/bin/env bash
set -euo pipefail

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export DISPLAY="${DISPLAY:-:0}"

TITLE="codex-buddy uConsole"
APP_ID="github.com.vxider.codex-buddy.uconsole"
WLRCTL="${HOME}/.local/bin/wlrctl"
WINDOW_SPECS=(
  "app_id:${APP_ID}"
  "app_id:codex-buddy"
  "title:${TITLE}"
  "title:codex-buddy"
)
COMMAND=(
  "${HOME}/.local/bin/codex-buddy"
  "uconsole"
  "--server-url"
  "http://dgx-spark.tail97583.ts.net:8787"
  "--no-led"
)

find_window_spec() {
  local spec
  for spec in "${WINDOW_SPECS[@]}"; do
    if "$WLRCTL" window find "$spec" >/dev/null 2>&1; then
      printf '%s\n' "$spec"
      return 0
    fi
  done

  return 1
}

fullscreen_window() {
  local attempt
  local spec

  [[ -x "$WLRCTL" ]] || return 0

  for attempt in $(seq 1 20); do
    if spec="$(find_window_spec)"; then
      "$WLRCTL" window focus "$spec" >/dev/null 2>&1 || true
      "$WLRCTL" window fullscreen "$spec" >/dev/null 2>&1 || true
      return 0
    fi
    sleep 0.2
  done
}

if [[ -x "$WLRCTL" ]]; then
  if spec="$(find_window_spec)"; then
    "$WLRCTL" toplevel activate "$spec" >/dev/null 2>&1 || true
    "$WLRCTL" toplevel focus "$spec" >/dev/null 2>&1 || true
    "$WLRCTL" toplevel fullscreen "$spec" >/dev/null 2>&1 || true
    exit 0
  fi
fi

"${COMMAND[@]}" >/dev/null 2>&1 &
fullscreen_window &
