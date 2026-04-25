# uconsole-mapper

`uconsole-mapper` is an input daemon for uConsole. It maps gamepad, keyboard, and mouse events to commands, text input, or virtual input events.

## Default Features

- `BTN_TRIGGER` (right-side `X`) manages `codex-buddy` and makes new windows fullscreen
- `BTN_TOP` (right-side `Y`) manages `QuickTerm`
- `BTN_THUMB` (right-side `A`) types `继续` and presses Enter after a `700ms` hold
- `KEY_RIGHTSHIFT + KEY_C` opens Chromium
- `KEY_LEFTCTRL + KEY_J/K` maps to mouse wheel down/up with repeat while held
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

[[keyboard.bindings]]
buttons = ["KEY_RIGHTSHIFT", "KEY_C"]
command = "~/.local/bin/run-or-raise-chromium"

[[keyboard.bindings]]
buttons = ["KEY_LEFTCTRL", "KEY_J"]
emit_rel = "REL_WHEEL"
emit_rel_value = -1
repeat_ms = 60

[[keyboard.bindings]]
buttons = ["KEY_LEFTCTRL", "KEY_K"]
emit_rel = "REL_WHEEL"
emit_rel_value = 1
repeat_ms = 60

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

Current `toggle-lxterminal` behavior:

- No `QuickTerm` window: opens a new `lxterminal --title=QuickTerm`
- A `QuickTerm` window exists but is not focused: raises it to the foreground
- `QuickTerm` is already focused: minimizes or hides it

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

- `emit_rel` + `emit_rel_value`: sends relative mouse events such as wheel scrolling
- `repeat_ms`: repeat interval while held after triggering, in milliseconds; default `0`
- `text`: types a string through `wtype`
- `press_enter`: sends Enter after `text`; default `false`

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
WHISPER_URL=http://127.0.0.1:9000/v1/audio/transcriptions
VOICE_OUTPUT_MODE=type
```

Script behavior:

- `start`: starts recording
- `stop`: stops recording, uploads the audio to Whisper, retrieves the transcript, and injects it into the currently focused input field

Supported output modes:

- `type`: types the text directly through `wtype`
- `type_enter`: types the text and then presses Enter
- `clipboard`: writes only to the clipboard
- `paste`: writes to the clipboard first, then simulates `Ctrl+V`

If the `B` button on the device is not `BTN_THUMB2`, check the service logs or temporarily run `evtest` / `libinput debug-events` to confirm the actual key code before updating the configuration.
