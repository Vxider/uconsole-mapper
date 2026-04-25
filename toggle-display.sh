#!/usr/bin/env bash
set -euo pipefail

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"

CONTROL_FIFO_PATH="${CONTROL_FIFO_PATH:-/run/uconsole-sleep/toggle-display.fifo}"
WLOPM_BIN="${WLOPM_BIN:-$(command -v wlopm || true)}"
WLR_RANDR_BIN="${WLR_RANDR_BIN:-$(command -v wlr-randr || true)}"
PREFERRED_OUTPUT="${WLOPM_OUTPUT:-}"

if [[ -p "${CONTROL_FIFO_PATH}" ]]; then
  printf 'toggle\n' > "${CONTROL_FIFO_PATH}"
  exit 0
fi

if [[ -z "${WLOPM_BIN}" ]]; then
  echo "wlopm not found in PATH" >&2
  exit 1
fi

choose_output() {
  if [[ -n "${PREFERRED_OUTPUT}" ]]; then
    printf '%s\n' "${PREFERRED_OUTPUT}"
    return 0
  fi

  if [[ -n "${WLR_RANDR_BIN}" ]]; then
    local output

    output="$("${WLR_RANDR_BIN}" 2>/dev/null | awk '$2 == "connected" && $1 ~ /^(DSI|eDP|LVDS)/ { print $1; exit }')"
    if [[ -n "${output}" ]]; then
      printf '%s\n' "${output}"
      return 0
    fi

    output="$("${WLR_RANDR_BIN}" 2>/dev/null | awk '$2 == "connected" { print $1; exit }')"
    if [[ -n "${output}" ]]; then
      printf '%s\n' "${output}"
      return 0
    fi
  fi

  # uConsole internal panel is commonly exposed as DSI-2.
  printf '%s\n' "DSI-2"
}

OUTPUT_NAME="$(choose_output)"
exec "${WLOPM_BIN}" --toggle "${OUTPUT_NAME}"
