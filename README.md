# uconsole-mapper

`uconsole-mapper` is an input daemon for uConsole. It maps gamepad and mouse events to commands, text input, or virtual input events, and it can still handle keyboard interception in a legacy compatibility mode.

## Default Features

- `BTN_TRIGGER` (right-side `X`) manages `codex-buddy` and makes new windows fullscreen
- `BTN_TOP` (right-side `Y`) manages `QuickTerm`
- `BTN_THUMB` (right-side `A`) types `提交git` on short press
- Desktop keybind integration keeps `RightShift+C` for Chromium, `RightShift+D` for `~/zDesktop`, `RightShift+F` for the file manager, and `RightShift+V` for VS Code through generated `keyd -> session launcher` bindings, installs `Shift+Enter` for terminal-style multiline input, and maps `Ctrl+Alt+Enter` to maximize the focused window
- Mouse `BTN_MIDDLE` is remapped to `BTN_LEFT`

The project uses a "daemon + configuration" design, which makes it easier to add combo bindings or custom actions than continuing to stack more `input-remapper` rules.

## Files

- `uconsole_mapper.py`: main program
- `config.toml.example`: example configuration
- `desktop-keybinds.toml.example`: declarative desktop shortcut config
- `generate_desktop_keybinds.py`: generates direct `keyd` launch bindings plus `labwc` snippets from the desktop shortcut config
- `run-or-raise-chromium.sh`: raises an existing Chromium window or starts a new one
- `run-or-raise-filemanager.sh`: raises an existing file manager window or starts a new one
- `run-or-raise-vscode.sh`: raises an existing VS Code window or starts a new one
- `run-or-raise-zdesktop.sh`: opens `~/zDesktop` in the file manager or focuses that window if it already exists
- `uconsole-launch-in-session.sh`: runs GUI commands from `keyd` inside the active desktop user session
- `sync_labwc_keybinds.py`: installs compositor-side keyboard shortcuts into `labwc`
- `sync_keyd_default_conf.py`: detects the uConsole keyboard id and writes a device-specific `/etc/keyd/default.conf`
- `uconsole-mapper.service`: `systemd --user` service file
- `99-uinput.rules`: grants `/dev/uinput` access to the `input` group
- `install.sh`: installation script

## Installation

Sync this repository to the uConsole, then run:

```bash
sudo apt update
sudo apt install -y python3-evdev wtype wl-clipboard curl jq
sudo modprobe uinput
cd ~/WorkSpace/uconsole-mapper
./install.sh
```

`./install.sh` marks `python3-evdev` as a manual package so a later
`apt autoremove` does not remove the mapper's core runtime dependency.

`RightShift+C` now depends on `keyd`. If your distro packages it, install
`keyd` before running `./install.sh`; the installer will detect the current
uConsole keyboard id and wire `/etc/keyd/default.conf` automatically. The
installer also removes `fcitx5`'s single-Shift toggle when it finds
`Shift_L`, because that hotkey conflicts with `RightShift+...` desktop binds.

The generated desktop launcher config lives at:

```bash
~/.config/uconsole-mapper/desktop-keybinds.toml
```

## Configuration

Default configuration file path:

```bash
~/.config/uconsole-mapper/config.toml
```

Default configuration example:

```toml
[general]
rescan_seconds = 3.0
session_watch_processes = ["wf-panel-pi", "labwc"]
session_watch_settle_ms = 1500

[gamepad]
device_name_patterns = ["ClockworkPI uConsole"]
debounce_ms = 250

[[gamepad.bindings]]
buttons = ["BTN_TRIGGER"]
command = "~/.local/bin/toggle-codex-buddy"

[[gamepad.bindings]]
buttons = ["BTN_TOP"]
command = "~/.local/bin/toggle-lxterminal"

[[gamepad.bindings]]
buttons = ["BTN_THUMB"]
command = "printf '%s' '提交git' | wl-copy && wtype -M ctrl -k v -m ctrl"

# Push-to-talk voice input.
# Replace BTN_THUMB2 with the actual B key code on your device if needed.
# [[gamepad.bindings]]
# buttons = ["BTN_THUMB2"]
# press_command = "~/.local/bin/uconsole-voice-ptt start"
# release_command = "~/.local/bin/uconsole-voice-ptt stop"

[keyboard]
enabled = false
grab = false
device_name_patterns = ["ClockworkPI uConsole Keyboard"]
debounce_ms = 250

[mouse]
enabled = true
grab = true
device_name_patterns = []

[[mouse.remaps]]
from = "BTN_MIDDLE"
to = "BTN_LEFT"
```

## Debugging

```bash
systemctl --user status uconsole-mapper.service
journalctl --user -u uconsole-mapper.service -f
```

Current `toggle-codex-buddy` behavior:

- No `codex-buddy` window: opens a new `codex-buddy uConsole` window and switches it to fullscreen
- A `codex-buddy` window exists but is not focused: raises it to the foreground
- `codex-buddy` is already focused: minimizes or hides it
- `codex-buddy` loses focus: minimizes automatically so it does not remain behind other overlay windows

Current `toggle-lxterminal` behavior:

- No `QuickTerm` window: opens a new `lxterminal --title=QuickTerm` in its own user scope
- A `QuickTerm` window exists but is not focused: raises it to the foreground
- `QuickTerm` is already focused: minimizes or hides it
- Rapid duplicate button events are ignored to avoid toggling the window twice from one press

If the service does not start, check these first:

- Whether `python3-evdev` is installed
- Whether `python3-evdev` was removed by `apt autoremove`
- Whether `wtype` is installed when text-input bindings are used
- Whether `wl-copy` from `wl-clipboard` is installed when paste-style bindings are used
- Whether `/dev/uinput` exists
- Whether the current user has read access to `/dev/input/event*`
- Whether `~/.local/bin/toggle-lxterminal` is executable
- Whether the Wayland session is `wayland-0`

## Hold And Text Bindings

`gamepad.bindings` also supports these fields:

- `hold_ms`: delay before triggering while held, in milliseconds; default `0`
- `repeat_ms`: repeat interval while held after triggering, in milliseconds; default `0`
- `text`: types a string through `wtype`
- `press_enter`: sends Enter after `text`; default `false`
- `press_command`: runs once when the combo becomes active
- `release_command`: runs once when the combo becomes inactive

When a normal `gamepad.bindings` action uses the same `buttons` as a `hold_ms`
binding, the normal action is treated as a short press and runs on release only
if the hold action did not fire.

`press_command` / `release_command` are intended for push-to-talk style actions where press starts and release stops. They cannot be combined with `hold_ms`, `repeat_ms`, `text`, or `emit_*`.

`keyboard.bindings` also supports these fields:

- `repeat_rate`: virtual keyboard repeat rate in keys per second; default `30`
- `repeat_delay_ms`: virtual keyboard repeat delay in milliseconds; default `300`
- `emit_rel` + `emit_rel_value`: sends relative mouse events such as wheel scrolling
- `repeat_ms`: repeat interval while held after triggering, in milliseconds; default `0`
- `text`: types a string through `wtype`
- `press_enter`: sends Enter after `text`; default `false`

The included `shift-enter-newline` helper translates `Shift+Enter` into `Ctrl+J`
when `QuickTerm` is focused. This matches Codex CLI multiline input behavior in
terminal UIs, where plain `Shift+Enter` is often not exposed as a distinct key.

## Desktop Keybinds

By default, keyboard shortcuts are no longer routed through `uconsole-mapper`.
Normal typing stays on the physical keyboard path. `RightShift+...` launchers
are handled directly by `keyd`, while compositor-specific binds stay in
`labwc`.

Default declaration:

```toml
[[rightshift.bindings]]
key = "c"
command = "~/.local/bin/run-or-raise-chromium"

[[rightshift.bindings]]
key = "f"
command = "~/.local/bin/run-or-raise-filemanager"

[[rightshift.bindings]]
key = "d"
command = "~/.local/bin/run-or-raise-zdesktop"

[[rightshift.bindings]]
key = "v"
command = "~/.local/bin/run-or-raise-vscode"

[[labwc.bindings]]
key = "S-Return"
command = "~/.local/bin/shift-enter-newline"

[[labwc.bindings]]
key = "C-A-Return"
action = "Maximize"

[[labwc.bindings]]
key = "C-A-d"
command = "~/.local/bin/uconsole-show-desktop"
```

Generated default behavior:

- `RightShift+C`: `keyd` runs `/usr/local/bin/uconsole-launch-in-session ~/.local/bin/run-or-raise-chromium`
- `RightShift+D`: `keyd` runs `/usr/local/bin/uconsole-launch-in-session ~/.local/bin/run-or-raise-zdesktop`
- `RightShift+F`: `keyd` runs `/usr/local/bin/uconsole-launch-in-session ~/.local/bin/run-or-raise-filemanager`
- `RightShift+V`: `keyd` runs `/usr/local/bin/uconsole-launch-in-session ~/.local/bin/run-or-raise-vscode`
- `Shift+Enter`: `labwc` runs `~/.local/bin/shift-enter-newline`
- `Ctrl+Alt+Enter`: `labwc` maximizes the focused window
- `Ctrl+Alt+D`: `labwc` runs `~/.local/bin/uconsole-show-desktop`

`install.sh` installs these pieces:

- `~/.config/uconsole-mapper/desktop-keybinds.toml`: the declaration you maintain
- `~/.local/share/uconsole-mapper/keyd-uconsole-mapper`: generated `keyd` snippet
- `~/.local/share/uconsole-mapper/labwc-keybinds.xml`: generated `labwc` block
- `/usr/local/bin/uconsole-launch-in-session`: helper that re-enters the active user session from `keyd`
- `~/.config/labwc/rc.xml`: `sync_labwc_keybinds.py` inserts the generated block
- `/etc/keyd/uconsole-mapper`: installed copy of the generated `keyd` snippet
- `/etc/keyd/default.conf`: `sync_keyd_default_conf.py` writes explicit uConsole keyboard ids plus `include uconsole-mapper`

This split is intentional. `keyd` can reliably match a right-only Shift combo,
while `labwc` remains the right place for compositor-facing binds such as
`Shift+Enter`. Launching Chromium directly from `keyd` avoids the previous
bridge-key path, which interacted badly with `fcitx5` single-Shift toggles.

The installer now writes explicit device ids into `/etc/keyd/default.conf`
instead of relying on the `*` wildcard. This is important on uConsole because
`keyd` may otherwise ignore the built-in keyboard entirely.

If you use `fcitx5`, avoid binding plain `Shift_L` as an input-method toggle.
That hotkey can steal or distort `RightShift+...` launchers because `keyd`
needs Shift-layer semantics to distinguish side-specific combos.

Legacy `[keyboard]` interception mode still exists for compatibility, but it is
disabled in the example config because it puts normal typing on top of the
mapper's grab-and-reemit path.

Current right-side button mapping on uConsole:

- `BTN_TRIGGER` = `X`
- `BTN_THUMB` = `A`
- `BTN_TOP` = `Y`

## Voice Input

The repository includes a standalone script, `uconsole-voice-ptt`, intended to be called from `uconsole-mapper` via `press_command` / `release_command`:

```toml
[[gamepad.bindings]]
buttons = ["BTN_THUMB2"]
press_command = "~/.local/bin/uconsole-voice-ptt start"
release_command = "~/.local/bin/uconsole-voice-ptt stop"
```

Default configuration files:

```bash
~/.config/uconsole-mapper/voice.env
~/.config/uconsole-mapper/voice-glossary.txt
```

`voice-glossary.txt` accepts one term per line. Blank lines and lines starting with `#` are ignored. The default example includes `git`.

Example `voice.env`:

```bash
WHISPER_URL=http://127.0.0.1:3300/api/asr/transcriptions
WHISPER_MODEL=faster-whisper-small
WHISPER_MODEL_FIELD=modelId
WHISPER_LANGUAGE=zh
WHISPER_CORRECTION_MODE=auto
WHISPER_CORRECTION_PROFILE_ID=technical_development
VOICE_OUTPUT_MODE=fcitx_commit
VOICE_TMUX_OUTPUT_MODE=type
VOICE_TYPE_BACKEND=auto
VOICE_TMUX_TYPE_BACKEND=wtype
VOICE_PASTE_SHORTCUT=shift_insert
VOICE_PASTE_BACKEND=auto
VOICE_NOTIFY_USE_MARKUP=0
VOICE_NOTIFY_FONT_SIZE=22
VOICE_NOTIFY_PADDING_LINES=1
```

Optional ASR request variables:

```bash
# Optional short ASR hint sent to the upstream transcription model.
# WHISPER_PROMPT=
# Multipart field name for the ASR prompt. Defaults to prompt.
# WHISPER_PROMPT_FIELD=prompt
# Multipart field name for request-level glossary JSON. Defaults to promptGlossary.
# WHISPER_PROMPT_GLOSSARY_FIELD=promptGlossary
# User glossary file, one term per line.
# VOICE_GLOSSARY_FILE=~/.config/uconsole-mapper/voice-glossary.txt
# Multipart field name for tmux context sent to correction. Defaults to contextText.
# WHISPER_CONTEXT_FIELD=contextText
# Multipart field name for the transcription model id. Use modelId for FlashAI asr_server.
# WHISPER_MODEL_FIELD=modelId
# ASR correction mode: off | on | auto. Auto keeps normal text fast and corrects code/command mixed input.
# WHISPER_CORRECTION_MODE=auto
# Server preset correction profile id. Empty disables profile selection. Defaults to technical_development.
# WHISPER_CORRECTION_PROFILE_ID=technical_development
# Multipart field name for correction profile id. Defaults to correctionProfileId.
# WHISPER_CORRECTION_PROFILE_FIELD=correctionProfileId
# Legacy compatibility only; prefer WHISPER_CORRECTION_MODE.
# WHISPER_ENABLE_CORRECTION=0
# ASR request timeout in seconds. Defaults to 30; use 0 to disable.
# WHISPER_TIMEOUT=30
# Include the current tmux active pane visible text when a tmux terminal is focused.
VOICE_TMUX_CONTEXT=1
# If the visible area is too short, fall back to at least this many recent lines.
# VOICE_TMUX_CONTEXT_LINES=30
# VOICE_TMUX_CONTEXT_MAX_CHARS=1200
```

Script behavior:

- `start`: starts recording
- `stop`: stops recording, uploads the audio to Whisper, retrieves the transcript, and injects it into the currently focused input field
- `cancel`: stops the active recording and deletes the audio without sending it to ASR
- if the focused input is a tmux terminal window, the script captures the current active tmux pane visible text; if that is shorter than the minimum line budget, it falls back to the most recent lines before sending the context multipart field for correction

Supported output modes:

- `type`: types the text directly through `wtype`
- `type_enter`: types the text and then presses Enter
- `clipboard`: writes only to the clipboard
- `paste`: writes to the clipboard first, then simulates a configurable paste shortcut
- `fcitx_commit`: writes the text to a pending file and asks an `fcitx5-lua` bridge to commit it into the currently focused input context

Window-specific behavior:

- non-tmux windows use `VOICE_OUTPUT_MODE`; `fcitx_commit` is the most input-method-like path when `wtype` / `ydotool` are not accepted by the target app
- tmux / QuickTerm use `VOICE_TMUX_OUTPUT_MODE`; the default is `type`, so shell apps still receive direct text input and tmux context correction keeps working
- `VOICE_TYPE_BACKEND=auto` prefers `ydotool` when its socket is available, otherwise falls back to `wtype`
- `VOICE_TMUX_TYPE_BACKEND` defaults to `wtype`, so tmux keeps the previous direct-text path unless you explicitly change it
- `VOICE_PASTE_SHORTCUT` defaults to `shift_insert`, which is more reliable than synthetic `Ctrl+V` in some Wayland browser setups
- `VOICE_PASTE_BACKEND=auto` prefers `ydotool` when its socket is available, otherwise falls back to `wtype`
- this also avoids the Chromium-side issue where direct virtual-keyboard typing can land as key positions such as `1234567890`

Notification behavior:

- while recording / transcribing, the script updates a single persistent status notification
- after successful transcription injection, the notification is closed instead of showing the recognized text
- `VOICE_NOTIFY_USE_MARKUP` defaults to `0`; enable it only if the notification daemon correctly renders Pango markup
- `VOICE_NOTIFY_FONT_SIZE` defaults to `22` and only applies when markup is enabled
- `VOICE_NOTIFY_PADDING_LINES` defaults to `1` to make the notification taller

If the `B` button on the device is not `BTN_THUMB2`, check the service logs or temporarily run `evtest` / `libinput debug-events` to confirm the actual key code before updating the configuration.

## Failure Recovery

- `uconsole-mapper.service` uses `Restart=always`, so systemd restarts the daemon if the main process exits
- if a keyboard watcher task dies unexpectedly, the daemon now treats that as fatal and lets systemd restart the whole service immediately
- if keyboard grab is enabled but the virtual keyboard write path breaks at runtime, the keyboard watcher drops out of grab mode and falls back to direct passthrough instead of keeping the physical keyboard locked
- by default the daemon also watches `wf-panel-pi` and `labwc`; if either process restarts and the PID change stays stable for `1500ms`, the daemon exits so systemd can recreate the virtual keyboard path cleanly
- the default desktop shortcut path no longer depends on `uconsole-mapper`, so taskbar or compositor churn no longer takes normal typing or `RightShift+C` down with it
