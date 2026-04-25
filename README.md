# uconsole-mapper

给 uConsole / Raspberry Pi 用的输入守护进程。

当前默认功能：

- `BTN_TRIGGER`（右侧 `X`）管理 `codex-buddy`，新开时自动全屏
- `BTN_TOP`（你说的右侧 `Y`）管理 `QuickTerm`
- `BTN_THUMB`（右侧 `A`）长按 `700ms` 输入 `继续` 并回车
- `KEY_RIGHTSHIFT + KEY_C` 打开 Chromium
- `KEY_RIGHTALT + KEY_L` 优先通过 `uconsole-sleep` 切换内屏电源
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
sudo apt install -y python3-evdev wtype
sudo modprobe uinput
cd ~/WorkSpace/uconsole
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

[keyboard]
enabled = true
grab = true
device_name_patterns = ["ClockworkPI uConsole Keyboard"]
debounce_ms = 250

[[keyboard.bindings]]
buttons = ["KEY_RIGHTSHIFT", "KEY_C"]
command = "~/.local/bin/run-or-raise-chromium"

[[keyboard.bindings]]
buttons = ["KEY_RIGHTALT", "KEY_L"]
command = "~/.local/bin/toggle-display"

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
- 使用 `toggle-display` 时，`uconsole-sleep` 的 FIFO 或 `wlopm`/`wlr-randr` 是否可用
- `/dev/uinput` 是否存在
- 当前用户是否对 `/dev/input/event*` 有读取权限
- `~/.local/bin/toggle-lxterminal` 是否可执行
- Wayland 会话是不是 `wayland-0`

## 用户态切屏

`toggle-display` 是给 `uconsole-mapper` 用的用户态脚本：

- 优先向 `uconsole-sleep` 的控制 FIFO 写入 `toggle`
- 如果控制 FIFO 不存在，再退回 `wlopm --toggle <output>`
- 退回 `wlopm` 时会优先用 `wlr-randr` 找当前连接的内屏输出
- 可以通过环境变量 `WLOPM_OUTPUT` 强制指定输出名

当前默认控制 FIFO 是：

```bash
/run/uconsole-sleep/toggle-display.fifo
```

`sleep_remap_powerkey.py` 现在会在启动时创建并监听这个 FIFO，所以用户态快捷键可以复用电源键短按同一套 `toggle_display()` 逻辑。

uConsole 内屏常见输出名是 `DSI-2`。如果你的合成器暴露的是别的名字，先执行：

```bash
wlr-randr
```

再把 `WLOPM_OUTPUT` 改成实际输出名。

## 长按/文本绑定

`gamepad.bindings` 现在额外支持：

- `hold_ms`：按住多久后触发，单位毫秒；默认 `0`
- `repeat_ms`：触发后按住时的重复间隔，单位毫秒；默认 `0`
- `text`：通过 `wtype` 输入一段文本
- `press_enter`：在 `text` 后补一个回车；默认 `false`

`keyboard.bindings` 额外支持：

- `emit_rel` + `emit_rel_value`：发送鼠标相对事件，比如滚轮
- `repeat_ms`：触发后按住时的重复间隔，单位毫秒；默认 `0`
- `text`：通过 `wtype` 输入一段文本
- `press_enter`：在 `text` 后补一个回车；默认 `false`

对 uConsole 这组右侧按键，当前按键码按实机映射为：

- `BTN_TRIGGER` = `X`
- `BTN_THUMB` = `A`
- `BTN_TOP` = `Y`
