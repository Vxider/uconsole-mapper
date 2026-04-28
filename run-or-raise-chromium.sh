#!/usr/bin/env bash
set -euo pipefail

WLRCTL="${HOME}/.local/bin/wlrctl"
CHROMIUM_BIN="${HOME}/.local/bin/chromium"

if [[ ! -x "${CHROMIUM_BIN}" ]]; then
  CHROMIUM_BIN="$(command -v chromium)"
fi

if [[ -x "${WLRCTL}" ]]; then
  if "${WLRCTL}" window focus chromium >/dev/null 2>&1; then
    exit 0
  fi
fi

exec "${CHROMIUM_BIN}" >/dev/null 2>&1 &
