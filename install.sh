#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${HOME}/.local/share/uconsole-mapper"
BIN_DIR="${HOME}/.local/bin"
CONFIG_DIR="${HOME}/.config/uconsole-mapper"
SYSTEMD_DIR="${HOME}/.config/systemd/user"
PYTHON_BIN=${PYTHON_BIN:-/usr/bin/python3}

mkdir -p "${APP_DIR}" "${BIN_DIR}" "${CONFIG_DIR}" "${SYSTEMD_DIR}"

if [[ ! -x "${PYTHON_BIN}" ]]; then
  echo "Python interpreter not found: ${PYTHON_BIN}"
  exit 1
fi

if ! "${PYTHON_BIN}" -c 'import evdev' >/dev/null 2>&1; then
  echo "Missing python3-evdev. Install it first:"
  echo "  sudo apt update && sudo apt install -y python3-evdev"
  exit 1
fi

if [[ ! -e /dev/uinput ]]; then
  echo "Missing /dev/uinput. Enable it first:"
  echo "  sudo modprobe uinput"
  exit 1
fi

if [[ ! -w /dev/uinput ]]; then
  echo "Configuring /dev/uinput permissions for group input..."
  sudo install -m 0644 "${SCRIPT_DIR}/99-uinput.rules" /etc/udev/rules.d/99-uinput.rules
  sudo udevadm control --reload-rules
  sudo udevadm trigger --name-match=uinput >/dev/null 2>&1 || true
  sudo chgrp input /dev/uinput
  sudo chmod 0660 /dev/uinput
  if command -v setfacl >/dev/null 2>&1; then
    sudo setfacl -m "u:${USER}:rw" /dev/uinput
  fi
fi

if [[ ! -w /dev/uinput ]]; then
  echo "Unable to get write access to /dev/uinput for ${USER}."
  echo "Add the user to the input group or grant a persistent ACL, then rerun install."
  echo "  sudo usermod -aG input ${USER}"
  exit 1
fi

install -m 0755 "${SCRIPT_DIR}/uconsole_mapper.py" "${APP_DIR}/uconsole_mapper.py"
install -m 0755 "${SCRIPT_DIR}/toggle-codex-buddy.sh" "${BIN_DIR}/toggle-codex-buddy"
install -m 0755 "${SCRIPT_DIR}/toggle-lxterminal.sh" "${BIN_DIR}/toggle-lxterminal"
install -m 0755 "${SCRIPT_DIR}/shift-enter-newline.sh" "${BIN_DIR}/shift-enter-newline"
install -m 0755 "${SCRIPT_DIR}/uconsole-voice-ptt.sh" "${BIN_DIR}/uconsole-voice-ptt"
install -m 0644 "${SCRIPT_DIR}/uconsole-mapper.service" "${SYSTEMD_DIR}/uconsole-mapper.service"

if [[ ! -f "${CONFIG_DIR}/config.toml" ]]; then
  install -m 0644 "${SCRIPT_DIR}/config.toml.example" "${CONFIG_DIR}/config.toml"
fi
if [[ ! -f "${CONFIG_DIR}/voice.env" ]]; then
  install -m 0644 "${SCRIPT_DIR}/voice.env.example" "${CONFIG_DIR}/voice.env"
fi

systemctl --user daemon-reload
systemctl --user enable --now uconsole-mapper.service
systemctl --user restart uconsole-mapper.service

echo
echo "Installed uconsole-mapper."
echo "Config:   ${CONFIG_DIR}/config.toml"
echo "Service:  systemctl --user status uconsole-mapper.service"
echo "Logs:     journalctl --user -u uconsole-mapper.service -f"
