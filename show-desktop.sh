#!/usr/bin/env bash
set -euo pipefail

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export DISPLAY="${DISPLAY:-:0}"

WLRCTL="${HOME}/.local/bin/wlrctl"

if [[ ! -x "$WLRCTL" ]]; then
  exit 0
fi

while "$WLRCTL" toplevel minimize >/dev/null 2>&1; do
  sleep 0.05
done
