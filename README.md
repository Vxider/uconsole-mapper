# uconsole-mapper

`uconsole-mapper` is an input daemon for uConsole. It maps gamepad, keyboard, and mouse events to commands, text input, or virtual input events.

## Default Features

- `BTN_TRIGGER` (right-side `X`) manages `codex-buddy` and makes new windows fullscreen
- `BTN_TOP` (right-side `Y`) manages `QuickTerm`
- `BTN_THUMB` (right-side `A`) types `继续` and presses Enter after a `700ms` hold
- `KEY_RIGHTSHIFT + KEY_C` opens Chromium
- Mouse `BTN_MIDDLE` is remapped to `BTN_LEFT`

The project uses a "daemon + configuration" design, which makes it easier to add combo bindings or custom actions than continuing to stack more `input-remapper` rules.

## Files

- `uconsole_mapper.py`: main program
- `config.toml.example`: example configuration
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

## Configuration

Default configuration file path:

```bash
~/.config/uconsole-mapper/config.toml
```

Default configuration example:

```toml
[general]
rescan_seconds = 3.0

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
enabled = true
grab = true
device_name_patterns = ["ClockworkPI uConsole Keyboard"]
debounce_ms = 250
repeat_rate = 30
repeat_delay_ms = 300

[[keyboard.bindings]]
buttons = ["KEY_RIGHTSHIFT", "KEY_C"]
command = "~/.local/bin/run-or-raise-chromium"

[[keyboard.bindings]]
buttons = ["KEY_LEFTSHIFT", "KEY_ENTER"]
command = "~/.local/bin/shift-enter-newline"

[[keyboard.bindings]]
buttons = ["KEY_RIGHTSHIFT", "KEY_ENTER"]
command = "~/.local/bin/shift-enter-newline"

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

If the `B` button on the device is not `BTN_THUMB2`, check the service logs or temporarily run `evtest` / `libinput debug-events` to confirm the actual key code before updating the configuration.
