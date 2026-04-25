#!/usr/bin/env bash
set -euo pipefail

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export DISPLAY="${DISPLAY:-:0}"

TITLE="QuickTerm"
APP_NAME="quickterm"
APP_CLASS="QuickTerm"
WLRCTL="${HOME}/.local/bin/wlrctl"
WINDOW_SPECS=(
  "app_id:lxterminal"
  "app_id:${APP_CLASS}"
  "app_id:${APP_NAME}"
  "app_id:${TITLE}"
  "title:${TITLE}"
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

if [[ -x "$WLRCTL" ]]; then
  if spec="$(find_window_spec)"; then
    "$WLRCTL" toplevel activate "$spec" >/dev/null 2>&1 || true
    "$WLRCTL" toplevel focus "$spec" >/dev/null 2>&1 || true
    exit 0
  fi
fi

exec lxterminal \
  --no-remote \
  --name="${APP_NAME}" \
  --class="${APP_CLASS}" \
  --title="${TITLE}" \
  >/dev/null 2>&1 &
