# uconsole-mapper

`uconsole-mapper` is an input daemon for uConsole. It maps gamepad and mouse events to commands, text input, or virtual input events, and it can still handle keyboard interception in a legacy compatibility mode.

## Default Features

- `BTN_TRIGGER` (right-side `X`) manages `codex-buddy` and makes new windows fullscreen
- `BTN_TOP` (right-side `Y`) manages `QuickTerm`
- `BTN_THUMB` (right-side `A`) types `继续` and presses Enter after a `700ms` hold
- Desktop keybind integration keeps `RightShift+C` for Chromium through generated `keyd -> bridge keysym -> labwc` bindings, and installs `Shift+Enter` for terminal-style multiline input
- Mouse `BTN_MIDDLE` is remapped to `BTN_LEFT`

The project uses a "daemon + configuration" design, which makes it easier to add combo bindings or custom actions than continuing to stack more `input-remapper` rules.

## Files

- `uconsole_mapper.py`: main program
- `config.toml.example`: example configuration
- `desktop-keybinds.toml.example`: declarative desktop shortcut config
- `generate_desktop_keybinds.py`: generates `keyd` and `labwc` snippets from the desktop shortcut config
- `run-or-raise-chromium.sh`: raises an existing Chromium window or starts a new one
- `sync_labwc_keybinds.py`: installs compositor-side keyboard shortcuts into `labwc`
- `sync_keyd_default_conf.py`: installs the `keyd` include into `/etc/keyd/default.conf`
- `uconsole-mapper.service`: `systemd --user` service file
- `99-uinput.rules`: grants `/dev/uinput` access to the `input` group
- `install.sh`: installation script

## Installation

Sync this repository to the uConsole, then run:

```bash
sudo apt update
sudo apt install -y python3-evdev wtype curl jq
sudo modprobe uinput
cd ~/WorkSpace/uconsole-mapper
./install.sh
```

`RightShift+C` now depends on `keyd`. If your distro packages it, install
`keyd` before running `./install.sh`; the installer will then wire
`/etc/keyd/default.conf` automatically.

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
hold_ms = 700
text = "继续"
press_enter = true

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

- No `QuickTerm` window: opens a new `lxterminal --title=QuickTerm`
- A `QuickTerm` window exists but is not focused: raises it to the foreground
- `QuickTerm` is already focused: minimizes or hides it
- `QuickTerm` loses focus: minimizes automatically so the next toggle returns to the desktop

If the service does not start, check these first:

- Whether `python3-evdev` is installed
- Whether `wtype` is installed when text-input bindings are used
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
Normal typing stays on the physical keyboard path, while desktop shortcuts are
split across `keyd` and `labwc`.

Default declaration:

```toml
[keyd]
bridge_keysyms = ["F13", "F14", "...", "F35"]

[[rightshift.bindings]]
key = "c"
command = "~/.local/bin/run-or-raise-chromium"

[[labwc.bindings]]
key = "S-Return"
command = "~/.local/bin/shift-enter-newline"
```

Generated default behavior:

- `RightShift+C`: generator assigns a bridge keysym such as `F13`, `keyd` emits it, then `labwc` runs `~/.local/bin/run-or-raise-chromium`
- `Shift+Enter`: `labwc` runs `~/.local/bin/shift-enter-newline`

`install.sh` installs these pieces:

- `~/.config/uconsole-mapper/desktop-keybinds.toml`: the declaration you maintain
- `~/.local/share/uconsole-mapper/keyd-uconsole-mapper`: generated `keyd` snippet
- `~/.local/share/uconsole-mapper/labwc-keybinds.xml`: generated `labwc` block
- `~/.config/labwc/rc.xml`: `sync_labwc_keybinds.py` inserts the generated block
- `/etc/keyd/uconsole-mapper`: installed copy of the generated `keyd` snippet
- `/etc/keyd/default.conf`: `sync_keyd_default_conf.py` inserts `include uconsole-mapper`

This split is intentional. `labwc` keybinds can safely express rare bridge
keysyms such as `F13-F35` and `Shift+Enter`, but they cannot safely express a
right-only Shift modifier for `C`. `keyd` handles the side-specific remap
first, so `labwc` only sees the rare bridge key.

The safe default bridge pool is `F13-F35`, so the generated setup supports 23
`RightShift+...` launchers before you need to extend the pool. That covers many
common launcher sets without you manually tracking which bridge key each app
uses.

If you do not want this on every keyboard, move `include uconsole-mapper` from
`/etc/keyd/default.conf` into a device-specific `keyd` config instead.

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

Default configuration file path:

```bash
~/.config/uconsole-mapper/voice.env
```

Example:

```bash
WHISPER_URL=http://127.0.0.1:3300/api/asr/transcriptions
VOICE_OUTPUT_MODE=type
VOICE_NOTIFY_USE_MARKUP=0
VOICE_NOTIFY_FONT_SIZE=16
VOICE_NOTIFY_PADDING_LINES=1
```

Optional context-related variables:

```bash
# Optional short ASR hint sent to the upstream transcription model.
# WHISPER_PROMPT=
# Multipart field name for the ASR prompt. Defaults to prompt.
# WHISPER_PROMPT_FIELD=prompt
# Multipart field name for tmux context sent to correction. Defaults to contextText.
# WHISPER_CONTEXT_FIELD=contextText
# Ask the ASR service to run correction. Defaults to 1.
# WHISPER_ENABLE_CORRECTION=1
# Include the current tmux active pane visible text when a tmux terminal is focused.
VOICE_TMUX_CONTEXT=1
# If the visible area is too short, fall back to at least this many recent lines.
# VOICE_TMUX_CONTEXT_LINES=30
# VOICE_TMUX_CONTEXT_MAX_CHARS=1200
```

Script behavior:

- `start`: starts recording
- `stop`: stops recording, uploads the audio to Whisper, retrieves the transcript, and injects it into the currently focused input field
- if the focused input is a tmux terminal window, the script captures the current active tmux pane visible text; if that is shorter than the minimum line budget, it falls back to the most recent lines before sending the context multipart field for correction

Supported output modes:

- `type`: types the text directly through `wtype`
- `type_enter`: types the text and then presses Enter
- `clipboard`: writes only to the clipboard
- `paste`: writes to the clipboard first, then simulates `Ctrl+V`

Notification behavior:

- while recording / transcribing, the script updates a single persistent status notification
- after successful transcription injection, the notification is closed instead of showing the recognized text
- `VOICE_NOTIFY_USE_MARKUP` defaults to `0`; enable it only if the notification daemon correctly renders Pango markup
- `VOICE_NOTIFY_FONT_SIZE` defaults to `16` and only applies when markup is enabled
- `VOICE_NOTIFY_PADDING_LINES` defaults to `1` to make the notification taller

If the `B` button on the device is not `BTN_THUMB2`, check the service logs or temporarily run `evtest` / `libinput debug-events` to confirm the actual key code before updating the configuration.

## Failure Recovery

- `uconsole-mapper.service` uses `Restart=always`, so systemd restarts the daemon if the main process exits
- if a keyboard watcher task dies unexpectedly, the daemon now treats that as fatal and lets systemd restart the whole service immediately
- if keyboard grab is enabled but the virtual keyboard write path breaks at runtime, the keyboard watcher drops out of grab mode and falls back to direct passthrough instead of keeping the physical keyboard locked
- by default the daemon also watches `wf-panel-pi` and `labwc`; if either process restarts and the PID change stays stable for `1500ms`, the daemon exits so systemd can recreate the virtual keyboard path cleanly
- the default desktop shortcut path no longer depends on `uconsole-mapper`, so taskbar or compositor churn no longer takes normal typing or `RightShift+C` down with it
