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
install -m 0755 "${SCRIPT_DIR}/run-or-raise-chromium.sh" "${BIN_DIR}/run-or-raise-chromium"
install -m 0755 "${SCRIPT_DIR}/shift-enter-newline.sh" "${BIN_DIR}/shift-enter-newline"
install -m 0755 "${SCRIPT_DIR}/uconsole-voice-ptt.sh" "${BIN_DIR}/uconsole-voice-ptt"
install -m 0755 "${SCRIPT_DIR}/generate_desktop_keybinds.py" "${APP_DIR}/generate_desktop_keybinds.py"
install -m 0755 "${SCRIPT_DIR}/sync_labwc_keybinds.py" "${APP_DIR}/sync_labwc_keybinds.py"
install -m 0755 "${SCRIPT_DIR}/sync_keyd_default_conf.py" "${APP_DIR}/sync_keyd_default_conf.py"
install -m 0644 "${SCRIPT_DIR}/uconsole-mapper.service" "${SYSTEMD_DIR}/uconsole-mapper.service"

if [[ ! -f "${CONFIG_DIR}/config.toml" ]]; then
  install -m 0644 "${SCRIPT_DIR}/config.toml.example" "${CONFIG_DIR}/config.toml"
fi
if [[ ! -f "${CONFIG_DIR}/voice.env" ]]; then
  install -m 0644 "${SCRIPT_DIR}/voice.env.example" "${CONFIG_DIR}/voice.env"
fi
if [[ ! -f "${CONFIG_DIR}/voice-glossary.txt" ]]; then
  install -m 0644 "${SCRIPT_DIR}/voice-glossary.txt.example" "${CONFIG_DIR}/voice-glossary.txt"
fi
if [[ ! -f "${CONFIG_DIR}/desktop-keybinds.toml" ]]; then
  install -m 0644 "${SCRIPT_DIR}/desktop-keybinds.toml.example" "${CONFIG_DIR}/desktop-keybinds.toml"
fi

"${PYTHON_BIN}" "${APP_DIR}/generate_desktop_keybinds.py" --config "${CONFIG_DIR}/desktop-keybinds.toml"
"${PYTHON_BIN}" "${APP_DIR}/sync_labwc_keybinds.py"
if command -v labwc >/dev/null 2>&1; then
  labwc --reconfigure >/dev/null 2>&1 || true
fi

if command -v keyd >/dev/null 2>&1 || [[ -d /etc/keyd ]]; then
  sudo install -d -m 0755 /etc/keyd
  sudo install -m 0644 "${APP_DIR}/keyd-uconsole-mapper" /etc/keyd/uconsole-mapper
  sudo "${PYTHON_BIN}" "${APP_DIR}/sync_keyd_default_conf.py"
  if command -v keyd >/dev/null 2>&1; then
    sudo keyd reload >/dev/null 2>&1 || sudo systemctl restart keyd >/dev/null 2>&1 || true
  fi
fi

systemctl --user daemon-reload
systemctl --user enable --now uconsole-mapper.service
systemctl --user restart uconsole-mapper.service

echo
echo "Installed uconsole-mapper."
echo "Config:   ${CONFIG_DIR}/config.toml"
echo "Voice:    ${CONFIG_DIR}/voice.env"
echo "Glossary: ${CONFIG_DIR}/voice-glossary.txt"
echo "Hotkeys:  ${CONFIG_DIR}/desktop-keybinds.toml"
echo "Labwc:    ~/.config/labwc/rc.xml"
echo "Keyd:     /etc/keyd/default.conf -> explicit uConsole keyboard ids"
echo "Service:  systemctl --user status uconsole-mapper.service"
echo "Logs:     journalctl --user -u uconsole-mapper.service -f"
echo
if ! command -v keyd >/dev/null 2>&1 && [[ ! -d /etc/keyd ]]; then
  echo "RightShift+C requires keyd. Install keyd, then rerun ./install.sh to wire /etc/keyd/default.conf."
fi
echo "Keyboard shortcuts now prefer keyd + labwc."
echo "If ${CONFIG_DIR}/config.toml still has [keyboard] enabled, disable that legacy mode to avoid keyboard grab failures."
