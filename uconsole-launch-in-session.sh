#!/usr/bin/env bash
set -euo pipefail

if [[ $# -eq 0 ]]; then
  echo "usage: uconsole-launch-in-session <command> [args...]" >&2
  exit 1
fi

detect_user() {
  if [[ -n "${UCONSOLE_SESSION_USER:-}" ]]; then
    printf '%s\n' "${UCONSOLE_SESSION_USER}"
    return 0
  fi

  if command -v loginctl >/dev/null 2>&1; then
    local user
    user=$(
      loginctl list-sessions --no-legend 2>/dev/null \
        | awk '$3 != "" { print $3; exit }'
    )
    if [[ -n "${user}" ]]; then
      printf '%s\n' "${user}"
      return 0
    fi
  fi

  echo "unable to detect target session user" >&2
  return 1
}

read_user_env() {
  local user=$1
  local uid=$2
  local line

  WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}
  DISPLAY=${DISPLAY:-}
  DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-}

  if command -v runuser >/dev/null 2>&1; then
    while IFS= read -r line; do
      case "${line}" in
        WAYLAND_DISPLAY=*)
          WAYLAND_DISPLAY=${line#WAYLAND_DISPLAY=}
          ;;
        DISPLAY=*)
          DISPLAY=${line#DISPLAY=}
          ;;
        DBUS_SESSION_BUS_ADDRESS=*)
          DBUS_SESSION_BUS_ADDRESS=${line#DBUS_SESSION_BUS_ADDRESS=}
          ;;
      esac
    done < <(runuser -u "${user}" -- systemctl --user show-environment 2>/dev/null || true)
  fi

  WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0}
  DISPLAY=${DISPLAY:-:0}
  DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/${uid}/bus}
}

TARGET_USER=$(detect_user)
TARGET_UID=$(id -u "${TARGET_USER}")
export XDG_RUNTIME_DIR="/run/user/${TARGET_UID}"

read_user_env "${TARGET_USER}" "${TARGET_UID}"

exec runuser -u "${TARGET_USER}" -- env \
  XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" \
  WAYLAND_DISPLAY="${WAYLAND_DISPLAY}" \
  DISPLAY="${DISPLAY}" \
  DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS}" \
  "$@"
