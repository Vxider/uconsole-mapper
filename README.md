# uconsole-mapper

给 uConsole / Raspberry Pi 用的输入守护进程。

当前默认功能：

- `BTN_TRIGGER`（右侧 `X`）管理 `codex-buddy`，新开时自动全屏
- `BTN_TOP`（你说的右侧 `Y`）管理 `QuickTerm`
- `BTN_THUMB`（右侧 `A`）长按 `700ms` 输入 `继续` 并回车
- `KEY_RIGHTSHIFT + KEY_C` 打开 Chromium
- `KEY_LEFTCTRL + KEY_J/K` 映射成鼠标滚轮下/上，按住连续滚动
- 鼠标 `BTN_MIDDLE` 映射成 `BTN_LEFT`

设计上已经按“守护进程 + 配置”的方式写了，后面继续加 `right + key` 这类组合键会比继续堆 `input-remapper` 顺手很多。

## 文件

- `uconsole_mapper.py`：主程序
- `config.toml.example`：默认配置
- `uconsole-mapper.service`：`systemd --user` 服务
- `99-uinput.rules`：给 `input` 组开放 `/dev/uinput`
- `install.sh`：安装脚本

## 在 Pi 上安装

先把这个目录同步到 Pi，然后执行：

```bash
sudo apt update
sudo apt install -y python3-evdev wtype curl jq
sudo modprobe uinput
cd ~/WorkSpace/uconsole-mapper
./install.sh
```

## 配置

默认配置安装到：

```bash
~/.config/uconsole-mapper/config.toml
```

默认内容：

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

## 调试

```bash
systemctl --user status uconsole-mapper.service
journalctl --user -u uconsole-mapper.service -f
```

`toggle-codex-buddy` 现在的行为是：

- 没有 `codex-buddy` 窗口：打开一个新的 `codex-buddy uConsole`，然后切成全屏
- 有 `codex-buddy` 窗口但不在前台：切到前台
- `codex-buddy` 已在前台：最小化隐藏

`toggle-lxterminal` 现在的行为是：

- 没有 `QuickTerm` 窗口：打开一个新的 `lxterminal --title=QuickTerm`
- 有 `QuickTerm` 窗口但不在前台：切到前台
- `QuickTerm` 已在前台：最小化隐藏

如果服务起不来，优先检查：

- `python3-evdev` 是否已安装
- 使用文本输入绑定时，`wtype` 是否已安装
- `/dev/uinput` 是否存在
- 当前用户是否对 `/dev/input/event*` 有读取权限
- `~/.local/bin/toggle-lxterminal` 是否可执行
- Wayland 会话是不是 `wayland-0`

## 长按/文本绑定

`gamepad.bindings` 现在额外支持：

- `hold_ms`：按住多久后触发，单位毫秒；默认 `0`
- `repeat_ms`：触发后按住时的重复间隔，单位毫秒；默认 `0`
- `text`：通过 `wtype` 输入一段文本
- `press_enter`：在 `text` 后补一个回车；默认 `false`
- `press_command`：组合键进入激活态时执行一次
- `release_command`：组合键退出激活态时执行一次

`press_command` / `release_command` 适合 push-to-talk 一类“按下开始，松开结束”的动作。它们不能和 `hold_ms`、`repeat_ms`、`text`、`emit_*` 混用。

`keyboard.bindings` 额外支持：

- `emit_rel` + `emit_rel_value`：发送鼠标相对事件，比如滚轮
- `repeat_ms`：触发后按住时的重复间隔，单位毫秒；默认 `0`
- `text`：通过 `wtype` 输入一段文本
- `press_enter`：在 `text` 后补一个回车；默认 `false`

对 uConsole 这组右侧按键，当前按键码按实机映射为：

- `BTN_TRIGGER` = `X`
- `BTN_THUMB` = `A`
- `BTN_TOP` = `Y`

## 语音输入

仓库里现在带了一个独立脚本 `uconsole-voice-ptt`，适合给 `uconsole-mapper` 的 `press_command` / `release_command` 调用：

```toml
[[gamepad.bindings]]
buttons = ["BTN_THUMB2"]
press_command = "~/.local/bin/uconsole-voice-ptt start"
release_command = "~/.local/bin/uconsole-voice-ptt stop"
```

默认配置文件是：

```bash
~/.config/uconsole-mapper/voice.env
```

示例：

```bash
WHISPER_URL=http://127.0.0.1:9000/v1/audio/transcriptions
VOICE_OUTPUT_MODE=type
```

脚本行为：

- `start`：开始录音
- `stop`：停止录音，上传到 Whisper，取回文本，并注入当前焦点输入框

当前支持的输出模式：

- `type`：直接通过 `wtype` 输入文本
- `type_enter`：输入后再回车
- `clipboard`：只放进剪贴板
- `paste`：先写剪贴板，再模拟 `Ctrl+V`

如果你机器上的 `B` 不是 `BTN_THUMB2`，先看服务日志或临时跑 `evtest`/`libinput debug-events` 确认实际按键码，再改配置。
