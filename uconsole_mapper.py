#!/usr/bin/env python3

from __future__ import annotations

import argparse
import asyncio
import logging
import os
import shlex
import shutil
import signal
import subprocess
import sys
import time
import tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from evdev import InputDevice, UInput, ecodes, list_devices


LOGGER = logging.getLogger("uconsole-mapper")
DEFAULT_CONFIG_PATH = Path("~/.config/uconsole-mapper/config.toml").expanduser()
IGNORED_DEVICE_SUBSTRINGS = (
    "uconsole-virtual-mouse",
    "uconsole-virtual-keyboard",
    "input-remapper",
)


def expand_path(value: str) -> str:
    return os.path.expandvars(os.path.expanduser(value))


def code_from_name(name: str) -> int:
    try:
        return int(getattr(ecodes, name))
    except AttributeError as exc:
        raise ValueError(f"unknown input code: {name}") from exc


def match_any(name: str, patterns: list[str]) -> bool:
    if not patterns:
        return True
    lowered = name.lower()
    return any(pattern.lower() in lowered for pattern in patterns)


def is_ignored_device(name: str) -> bool:
    lowered = name.lower()
    return any(pattern in lowered for pattern in IGNORED_DEVICE_SUBSTRINGS)


@dataclass(slots=True)
class Binding:
    buttons: frozenset[int]
    command: str | None = None
    emit_key: int | None = None
    emit_rel: int | None = None
    emit_rel_value: int = 0
    text: str | None = None
    press_enter: bool = False
    hold_ms: int = 0
    repeat_ms: int = 0


@dataclass(slots=True)
class MouseRemap:
    from_code: int
    to_code: int


@dataclass(slots=True)
class Config:
    rescan_seconds: float
    gamepad_patterns: list[str]
    gamepad_debounce_ms: int
    gamepad_bindings: list[Binding]
    keyboard_enabled: bool
    keyboard_grab: bool
    keyboard_patterns: list[str]
    keyboard_debounce_ms: int
    keyboard_bindings: list[Binding]
    mouse_enabled: bool
    mouse_grab: bool
    mouse_patterns: list[str]
    mouse_remaps: list[MouseRemap]


def load_config(path: Path) -> Config:
    raw = tomllib.loads(path.read_text(encoding="utf-8"))

    general = raw.get("general", {})
    gamepad = raw.get("gamepad", {})
    keyboard = raw.get("keyboard", {})
    mouse = raw.get("mouse", {})
    bindings_raw = gamepad.get("bindings", [])
    keyboard_bindings_raw = keyboard.get("bindings", [])
    remaps_raw = mouse.get("remaps", [])

    bindings: list[Binding] = []
    for item in bindings_raw:
        buttons = frozenset(code_from_name(button) for button in item["buttons"])
        bindings.append(
            Binding(
                buttons=buttons,
                command=expand_path(item["command"]) if item.get("command") else None,
                emit_key=code_from_name(item["emit_key"]) if item.get("emit_key") else None,
                emit_rel=code_from_name(item["emit_rel"]) if item.get("emit_rel") else None,
                emit_rel_value=int(item.get("emit_rel_value", 0)),
                text=item.get("text"),
                press_enter=bool(item.get("press_enter", False)),
                hold_ms=int(item.get("hold_ms", 0)),
                repeat_ms=int(item.get("repeat_ms", 0)),
            )
        )

    keyboard_bindings: list[Binding] = []
    for item in keyboard_bindings_raw:
        buttons = frozenset(code_from_name(button) for button in item["buttons"])
        keyboard_bindings.append(
            Binding(
                buttons=buttons,
                command=expand_path(item["command"]) if item.get("command") else None,
                emit_key=code_from_name(item["emit_key"]) if item.get("emit_key") else None,
                emit_rel=code_from_name(item["emit_rel"]) if item.get("emit_rel") else None,
                emit_rel_value=int(item.get("emit_rel_value", 0)),
                text=item.get("text"),
                press_enter=bool(item.get("press_enter", False)),
                hold_ms=int(item.get("hold_ms", 0)),
                repeat_ms=int(item.get("repeat_ms", 0)),
            )
        )

    remaps: list[MouseRemap] = []
    for item in remaps_raw:
        remaps.append(
            MouseRemap(
                from_code=code_from_name(item["from"]),
                to_code=code_from_name(item["to"]),
            )
        )

    return Config(
        rescan_seconds=float(general.get("rescan_seconds", 3.0)),
        gamepad_patterns=list(gamepad.get("device_name_patterns", ["ClockworkPI uConsole"])),
        gamepad_debounce_ms=int(gamepad.get("debounce_ms", 250)),
        gamepad_bindings=bindings,
        keyboard_enabled=bool(keyboard.get("enabled", False)),
        keyboard_grab=bool(keyboard.get("grab", True)),
        keyboard_patterns=list(keyboard.get("device_name_patterns", ["ClockworkPI uConsole Keyboard"])),
        keyboard_debounce_ms=int(keyboard.get("debounce_ms", 250)),
        keyboard_bindings=keyboard_bindings,
        mouse_enabled=bool(mouse.get("enabled", True)),
        mouse_grab=bool(mouse.get("grab", True)),
        mouse_patterns=list(mouse.get("device_name_patterns", [])),
        mouse_remaps=remaps,
    )


class ActionRunner:
    def __init__(self) -> None:
        self._last_run: dict[str, float] = {}
        self._env = os.environ.copy()
        self._env.setdefault("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
        self._env.setdefault("WAYLAND_DISPLAY", "wayland-0")
        self._env.setdefault("DISPLAY", ":0")
        self._wtype_path = shutil.which("wtype")

    def run(self, binding: Binding, debounce_ms: int) -> None:
        key = self._binding_key(binding)
        now = time.monotonic()
        last = self._last_run.get(key, 0.0)
        if (now - last) * 1000 < debounce_ms:
            return
        self._last_run[key] = now
        if binding.command:
            self._run_command(binding.command)
            return
        if binding.text is not None:
            self._run_text(binding.text, binding.press_enter)
            return

    def _binding_key(self, binding: Binding) -> str:
        if binding.command:
            return f"command:{binding.command}"
        if binding.text is not None:
            return f"text:{binding.text}:{int(binding.press_enter)}"
        return f"emit:{binding.emit_key}"

    def _run_command(self, command: str) -> None:
        LOGGER.info("run command: %s", command)
        subprocess.Popen(
            ["sh", "-lc", command],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            env=self._env,
        )

    def _run_text(self, text: str, press_enter: bool) -> None:
        if not self._wtype_path:
            LOGGER.error("text binding requires wtype in PATH")
            return
        quoted_text = shlex.quote(text)
        command = f"{shlex.quote(self._wtype_path)} {quoted_text}"
        if press_enter:
            command += f" && {shlex.quote(self._wtype_path)} -k Return"
        LOGGER.info("type text via wtype: %s", text)
        subprocess.Popen(
            ["sh", "-lc", command],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            env=self._env,
        )


def validate_binding(binding: Binding) -> None:
    action_count = sum(
        (
            binding.command is not None,
            binding.emit_key is not None,
            binding.emit_rel is not None,
            binding.text is not None,
        )
    )
    if action_count != 1:
        raise ValueError("binding must define exactly one of command, emit_key, emit_rel, or text")
    if binding.press_enter and binding.text is None:
        raise ValueError("press_enter requires text")
    if binding.emit_rel is not None and binding.emit_rel_value == 0:
        raise ValueError("emit_rel_value must be non-zero when emit_rel is set")
    if binding.emit_rel is None and binding.emit_rel_value != 0:
        raise ValueError("emit_rel_value requires emit_rel")
    if binding.hold_ms < 0:
        raise ValueError("hold_ms must be >= 0")
    if binding.repeat_ms < 0:
        raise ValueError("repeat_ms must be >= 0")


class GamepadWatcher:
    def __init__(self, device: InputDevice, config: Config, runner: ActionRunner) -> None:
        self.device = device
        self.config = config
        self.runner = runner
        for binding in self.config.gamepad_bindings:
            validate_binding(binding)
        self.pressed: set[int] = set()
        self.active_bindings: set[int] = set()
        self.hold_tasks: dict[int, asyncio.Task[None]] = {}
        self.repeat_tasks: dict[int, asyncio.Task[None]] = {}

    async def run(self) -> None:
        LOGGER.info("watch gamepad: %s (%s)", self.device.name, self.device.path)
        try:
            async for event in self.device.async_read_loop():
                if event.type != ecodes.EV_KEY:
                    continue
                self._handle_key(event.code, event.value)
        except OSError as exc:
            LOGGER.warning("gamepad watcher stopped for %s: %s", self.device.path, exc)
        finally:
            for task in self.hold_tasks.values():
                task.cancel()
            for task in self.repeat_tasks.values():
                task.cancel()
            self.device.close()

    async def _fire_hold(self, index: int, binding: Binding) -> None:
        try:
            await asyncio.sleep(binding.hold_ms / 1000)
        except asyncio.CancelledError:
            return
        if index not in self.active_bindings:
            return
        if not binding.buttons.issubset(self.pressed):
            return
        self._trigger_binding(binding)

    def _trigger_binding(self, binding: Binding) -> None:
        if binding.command or binding.text is not None:
            self.runner.run(binding, self.config.gamepad_debounce_ms)

    async def _repeat_binding(self, index: int, binding: Binding) -> None:
        try:
            while True:
                await asyncio.sleep(binding.repeat_ms / 1000)
                if index not in self.active_bindings:
                    return
                if not binding.buttons.issubset(self.pressed):
                    return
                self._trigger_binding(binding)
        except asyncio.CancelledError:
            return

    def _handle_key(self, code: int, value: int) -> None:
        is_pressed = value != 0
        if is_pressed:
            self.pressed.add(code)
        else:
            self.pressed.discard(code)

        for index, binding in enumerate(self.config.gamepad_bindings):
            matched = binding.buttons.issubset(self.pressed)
            was_active = index in self.active_bindings
            if matched and not was_active:
                self.active_bindings.add(index)
                if binding.hold_ms > 0:
                    self.hold_tasks[index] = asyncio.create_task(self._fire_hold(index, binding))
                else:
                    self._trigger_binding(binding)
                    if binding.repeat_ms > 0:
                        self.repeat_tasks[index] = asyncio.create_task(self._repeat_binding(index, binding))
            elif not matched and was_active:
                self.active_bindings.remove(index)
                task = self.hold_tasks.pop(index, None)
                if task is not None:
                    task.cancel()
                task = self.repeat_tasks.pop(index, None)
                if task is not None:
                    task.cancel()


class VirtualKeyboard:
    def __init__(self, device: InputDevice, extra_keys: set[int] | None = None) -> None:
        capabilities = {
            event_type: list(codes)
            for event_type, codes in device.capabilities().items()
            if event_type != ecodes.EV_SYN
        }
        if extra_keys:
            key_codes = set(capabilities.get(ecodes.EV_KEY, []))
            key_codes.update(extra_keys)
            capabilities[ecodes.EV_KEY] = sorted(key_codes)

        self.ui = UInput(
            capabilities,
            name="uconsole-virtual-keyboard",
            vendor=device.info.vendor,
            product=device.info.product,
            version=device.info.version,
            bustype=device.info.bustype,
            phys=f"{device.phys or 'uconsole'}/virtual",
        )

    def close(self) -> None:
        self.ui.close()

    def write_key(self, code: int, value: int) -> None:
        self.ui.write(ecodes.EV_KEY, code, value)
        self.ui.syn()


class KeyboardWatcher:
    def __init__(
        self,
        device: InputDevice,
        config: Config,
        runner: ActionRunner,
        virtual_mouse: VirtualMouse | None = None,
    ) -> None:
        self.device = device
        self.config = config
        self.runner = runner
        self.virtual_mouse = virtual_mouse
        for binding in self.config.keyboard_bindings:
            validate_binding(binding)

        self.virtual_keyboard: VirtualKeyboard | None = None
        if self.config.keyboard_grab:
            extra_keys = {
                binding.emit_key for binding in self.config.keyboard_bindings if binding.emit_key is not None
            }
            self.virtual_keyboard = VirtualKeyboard(device, extra_keys)
        self.binding_codes = self._binding_codes()
        self.pressed: set[int] = set()
        self.pending_order: list[int] = []
        self.pending_set: set[int] = set()
        self.active_bindings: set[int] = set()
        self.consumed_keys: set[int] = set()
        self.repeat_tasks: dict[int, asyncio.Task[None]] = {}

    async def run(self) -> None:
        grabbed = False
        LOGGER.info("watch keyboard: %s (%s)", self.device.name, self.device.path)
        try:
            if self.config.keyboard_grab:
                self.device.grab()
                grabbed = True
            async for event in self.device.async_read_loop():
                if event.type != ecodes.EV_KEY:
                    continue
                self._handle_key(event.code, event.value)
        except OSError as exc:
            LOGGER.warning("keyboard watcher stopped for %s: %s", self.device.path, exc)
        finally:
            if grabbed:
                try:
                    self.device.ungrab()
                except OSError:
                    pass
            if self.virtual_keyboard is not None:
                self.virtual_keyboard.close()
            for task in self.repeat_tasks.values():
                task.cancel()
            self.device.close()

    def _binding_codes(self) -> set[int]:
        codes: set[int] = set()
        for binding in self.config.keyboard_bindings:
            codes.update(binding.buttons)
        return codes

    def _possible_binding(self) -> bool:
        relevant_pressed = self.pressed & self.binding_codes
        if not relevant_pressed:
            return False
        return any(relevant_pressed.issubset(binding.buttons) for binding in self.config.keyboard_bindings)

    def _queue_pending(self, code: int) -> None:
        if code in self.pending_set:
            return
        self.pending_order.append(code)
        self.pending_set.add(code)

    def _discard_pending(self, code: int) -> None:
        if code not in self.pending_set:
            return
        self.pending_set.remove(code)
        self.pending_order = [item for item in self.pending_order if item != code]

    def _flush_pending(self) -> None:
        for code in list(self.pending_order):
            if code in self.pending_set and code in self.pressed and code not in self.consumed_keys:
                self.virtual_keyboard.write_key(code, 1)
        self.pending_order.clear()
        self.pending_set.clear()

    def _refresh_active_bindings(self) -> None:
        for index, binding in enumerate(self.config.keyboard_bindings):
            matched = binding.buttons.issubset(self.pressed)
            was_active = index in self.active_bindings
            if matched and not was_active:
                self._trigger_binding(binding)
                self.active_bindings.add(index)
                if binding.repeat_ms > 0:
                    self.repeat_tasks[index] = asyncio.create_task(self._repeat_binding(index, binding))
                self.consumed_keys.update(binding.buttons)
                for code in binding.buttons:
                    self._discard_pending(code)
            elif not matched and was_active:
                self.active_bindings.remove(index)
                task = self.repeat_tasks.pop(index, None)
                if task is not None:
                    task.cancel()

        active_codes: set[int] = set()
        for index in self.active_bindings:
            active_codes.update(self.config.keyboard_bindings[index].buttons)
        self.consumed_keys = active_codes

    def _trigger_binding(self, binding: Binding) -> None:
        if binding.emit_key is not None and self.virtual_keyboard is not None:
            self.virtual_keyboard.write_key(binding.emit_key, 1)
            self.virtual_keyboard.write_key(binding.emit_key, 0)
            return
        if binding.emit_rel is not None and self.virtual_mouse is not None:
            self.virtual_mouse.write_event(ecodes.EV_REL, binding.emit_rel, binding.emit_rel_value)
            self.virtual_mouse.syn()
            return
        if binding.command or binding.text is not None:
            self.runner.run(binding, self.config.keyboard_debounce_ms)

    async def _repeat_binding(self, index: int, binding: Binding) -> None:
        try:
            while True:
                await asyncio.sleep(binding.repeat_ms / 1000)
                if index not in self.active_bindings:
                    return
                if not binding.buttons.issubset(self.pressed):
                    return
                self._trigger_binding(binding)
        except asyncio.CancelledError:
            return

    def _handle_key(self, code: int, value: int) -> None:
        if not self.config.keyboard_grab:
            self._handle_key_passthrough(code, value)
            return

        is_pressed = value != 0

        if is_pressed:
            self.pressed.add(code)
            if code in self.binding_codes:
                self._refresh_active_bindings()
                if code in self.consumed_keys:
                    return
                if self._possible_binding():
                    self._queue_pending(code)
                    return
                self._flush_pending()
                self.virtual_keyboard.write_key(code, 1)
                return

            if self.pending_set:
                self._flush_pending()
            self.virtual_keyboard.write_key(code, 1)
            return

        was_consumed = code in self.consumed_keys
        self.pressed.discard(code)
        self._refresh_active_bindings()

        if was_consumed:
            return

        if code in self.pending_set:
            self._discard_pending(code)
            self.virtual_keyboard.write_key(code, 1)
            self.virtual_keyboard.write_key(code, 0)
            return

        self.virtual_keyboard.write_key(code, 0)

    def _handle_key_passthrough(self, code: int, value: int) -> None:
        is_pressed = value != 0
        if is_pressed:
            self.pressed.add(code)
        else:
            self.pressed.discard(code)

        for index, binding in enumerate(self.config.keyboard_bindings):
            matched = binding.buttons.issubset(self.pressed)
            was_active = index in self.active_bindings
            if matched and not was_active:
                self._trigger_binding(binding)
                self.active_bindings.add(index)
                if binding.repeat_ms > 0:
                    self.repeat_tasks[index] = asyncio.create_task(self._repeat_binding(index, binding))
            elif not matched and was_active:
                self.active_bindings.remove(index)
                task = self.repeat_tasks.pop(index, None)
                if task is not None:
                    task.cancel()


class VirtualMouse:
    def __init__(self) -> None:
        capabilities = {
            ecodes.EV_KEY: [
                ecodes.BTN_LEFT,
                ecodes.BTN_RIGHT,
                ecodes.BTN_MIDDLE,
                ecodes.BTN_SIDE,
                ecodes.BTN_EXTRA,
                ecodes.BTN_FORWARD,
                ecodes.BTN_BACK,
                ecodes.BTN_TASK,
            ],
            ecodes.EV_REL: [
                ecodes.REL_X,
                ecodes.REL_Y,
                ecodes.REL_WHEEL,
                ecodes.REL_HWHEEL,
                ecodes.REL_WHEEL_HI_RES,
                ecodes.REL_HWHEEL_HI_RES,
            ],
        }
        self.ui = UInput(capabilities, name="uconsole-virtual-mouse")

    def close(self) -> None:
        self.ui.close()

    def write_event(self, event_type: int, code: int, value: int) -> None:
        self.ui.write(event_type, code, value)

    def syn(self) -> None:
        self.ui.syn()


class MouseWatcher:
    def __init__(self, device: InputDevice, config: Config, virtual_mouse: VirtualMouse) -> None:
        self.device = device
        self.config = config
        self.virtual_mouse = virtual_mouse
        self.remap_to_target = {item.from_code: item.to_code for item in config.mouse_remaps}
        self.target_sources: dict[int, set[int]] = {}
        for source, target in self.remap_to_target.items():
            self.target_sources.setdefault(target, {target}).add(source)
        self.source_state: dict[int, bool] = {}
        self.target_state: dict[int, int] = {}

    async def run(self) -> None:
        grabbed = False
        LOGGER.info("watch mouse: %s (%s)", self.device.name, self.device.path)
        try:
            if self.config.mouse_grab:
                self.device.grab()
                grabbed = True
            async for event in self.device.async_read_loop():
                self._handle_event(event)
        except OSError as exc:
            LOGGER.warning("mouse watcher stopped for %s: %s", self.device.path, exc)
        finally:
            if grabbed:
                try:
                    self.device.ungrab()
                except OSError:
                    pass
            self.device.close()

    def _handle_event(self, event: Any) -> None:
        if event.type == ecodes.EV_REL:
            self.virtual_mouse.write_event(event.type, event.code, event.value)
            return

        if event.type == ecodes.EV_SYN:
            self.virtual_mouse.syn()
            return

        if event.type != ecodes.EV_KEY:
            return

        if event.code in self.remap_to_target:
            target = self.remap_to_target[event.code]
            self.source_state[event.code] = event.value != 0
            self._emit_target_state(target)
            return

        if event.code in self.target_sources:
            self.source_state[event.code] = event.value != 0
            self._emit_target_state(event.code)
            return

        self.virtual_mouse.write_event(event.type, event.code, event.value)

    def _emit_target_state(self, target_code: int) -> None:
        active = any(self.source_state.get(source, False) for source in self.target_sources[target_code])
        value = 1 if active else 0
        if self.target_state.get(target_code) == value:
            return
        self.target_state[target_code] = value
        self.virtual_mouse.write_event(ecodes.EV_KEY, target_code, value)


class MapperDaemon:
    def __init__(self, config: Config) -> None:
        self.config = config
        self.runner = ActionRunner()
        self.virtual_mouse = VirtualMouse() if config.mouse_enabled else None
        self.tasks: dict[str, asyncio.Task[None]] = {}

    async def shutdown(self) -> None:
        for task in list(self.tasks.values()):
            task.cancel()
        if self.tasks:
            await asyncio.gather(*self.tasks.values(), return_exceptions=True)
            self.tasks.clear()
        if self.virtual_mouse is not None:
            self.virtual_mouse.close()

    async def run(self) -> None:
        while True:
            self._prune_tasks()
            self._scan_devices()
            await asyncio.sleep(self.config.rescan_seconds)

    def _prune_tasks(self) -> None:
        finished = [path for path, task in self.tasks.items() if task.done()]
        for path in finished:
            task = self.tasks.pop(path)
            try:
                task.result()
            except asyncio.CancelledError:
                pass
            except Exception as exc:
                LOGGER.exception("device task failed for %s: %s", path, exc)

    def _scan_devices(self) -> None:
        active_paths = set(self.tasks)
        for path in list_devices():
            if path in active_paths:
                continue
            try:
                device = InputDevice(path)
            except OSError:
                continue

            role = self._detect_role(device)
            if role == "gamepad":
                task = asyncio.create_task(GamepadWatcher(device, self.config, self.runner).run())
                self.tasks[path] = task
            elif role == "keyboard":
                task = asyncio.create_task(
                    KeyboardWatcher(device, self.config, self.runner, self.virtual_mouse).run()
                )
                self.tasks[path] = task
            elif role == "mouse":
                if self.virtual_mouse is None:
                    device.close()
                    continue
                task = asyncio.create_task(MouseWatcher(device, self.config, self.virtual_mouse).run())
                self.tasks[path] = task
            else:
                device.close()

    def _detect_role(self, device: InputDevice) -> str | None:
        if is_ignored_device(device.name):
            return None

        try:
            caps = device.capabilities()
        except OSError:
            return None

        key_caps = set(caps.get(ecodes.EV_KEY, []))
        rel_caps = set(caps.get(ecodes.EV_REL, []))

        if (
            match_any(device.name, self.config.gamepad_patterns)
            and any(code in key_caps for code in self._binding_codes())
        ):
            return "gamepad"

        if (
            self.config.keyboard_enabled
            and match_any(device.name, self.config.keyboard_patterns)
            and any(code in key_caps for code in self._keyboard_binding_codes())
        ):
            return "keyboard"

        if self.config.mouse_enabled and self._is_mouse(device.name, key_caps, rel_caps):
            return "mouse"

        return None

    def _binding_codes(self) -> set[int]:
        codes: set[int] = set()
        for binding in self.config.gamepad_bindings:
            codes.update(binding.buttons)
        return codes

    def _keyboard_binding_codes(self) -> set[int]:
        codes: set[int] = set()
        for binding in self.config.keyboard_bindings:
            codes.update(binding.buttons)
        return codes

    def _is_mouse(self, name: str, key_caps: set[int], rel_caps: set[int]) -> bool:
        if ecodes.REL_X not in rel_caps or ecodes.REL_Y not in rel_caps:
            return False
        if ecodes.BTN_MIDDLE not in key_caps:
            return False
        return match_any(name, self.config.mouse_patterns)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG_PATH)
    parser.add_argument("--log-level", default="INFO")
    return parser.parse_args()


async def main_async() -> int:
    args = parse_args()
    logging.basicConfig(
        level=getattr(logging, args.log_level.upper(), logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    config_path = args.config.expanduser()
    if not config_path.exists():
        LOGGER.error("config not found: %s", config_path)
        return 1

    config = load_config(config_path)
    daemon = MapperDaemon(config)

    loop = asyncio.get_running_loop()
    stop_event = asyncio.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop_event.set)

    runner_task = asyncio.create_task(daemon.run())
    stop_task = asyncio.create_task(stop_event.wait())
    done, pending = await asyncio.wait({runner_task, stop_task}, return_when=asyncio.FIRST_COMPLETED)

    for task in pending:
        task.cancel()
    await daemon.shutdown()
    await asyncio.gather(*pending, return_exceptions=True)

    if runner_task in done:
        return runner_task.result() or 0
    return 0


def main() -> int:
    try:
        return asyncio.run(main_async())
    except KeyboardInterrupt:
        return 0
    except Exception as exc:
        print(f"fatal: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
