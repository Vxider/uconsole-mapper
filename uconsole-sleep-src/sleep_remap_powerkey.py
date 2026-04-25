#!/usr/bin/env python3
from __future__ import annotations

import os
import select
import stat
import threading
import time

from evdev import InputDevice, UInput, ecodes, list_devices

from sleep_display_control import toggle_display


KEY_POWER = ecodes.KEY_POWER
HOLD_TRIGGER_SEC = float(os.environ.get("HOLD_TRIGGER_SEC") or 0.7)
LOCK_KEY_ENABLED = os.environ.get("LOCK_KEY_ENABLED", "yes") == "yes"
LOCK_KEY_DEVICE_NAME = os.environ.get(
    "LOCK_KEY_DEVICE_NAME", "ClockworkPI uConsole Consumer Control"
)
CONTROL_FIFO_PATH = os.environ.get(
    "CONTROL_FIFO_PATH", "/run/uconsole-sleep/toggle-display.fifo"
)


def parse_key_code(raw: str | None, default: int) -> int:
    if not raw:
        return default
    raw = raw.strip()
    if hasattr(ecodes, raw):
        return int(getattr(ecodes, raw))
    return int(raw, 0)


LOCK_KEY_CODE = parse_key_code(os.environ.get("LOCK_KEY_CODE"), ecodes.KEY_SCREENSAVER)
DISPLAY_TOGGLE_LOCK = threading.Lock()


def toggle_display_safe() -> None:
    with DISPLAY_TOGGLE_LOCK:
        toggle_display()


def ensure_control_fifo(path: str) -> None:
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    if os.path.exists(path):
        if not stat.S_ISFIFO(os.stat(path).st_mode):
            raise RuntimeError(f"control path exists and is not a fifo: {path}")
    else:
        os.mkfifo(path, 0o666)
    os.chmod(path, 0o666)


def run_control_fifo_handler() -> None:
    ensure_control_fifo(CONTROL_FIFO_PATH)
    fd = os.open(CONTROL_FIFO_PATH, os.O_RDWR | os.O_NONBLOCK)
    buffer = ""
    try:
        print(f"SRP: control fifo active at {CONTROL_FIFO_PATH}.", flush=True)
        while True:
            readable, _, _ = select.select([fd], [], [])
            if fd not in readable:
                continue
            chunk = os.read(fd, 4096)
            if not chunk:
                continue
            buffer += chunk.decode("utf-8", errors="replace")
            while "\n" in buffer:
                line, buffer = buffer.split("\n", 1)
                command = line.strip().lower()
                if command == "toggle":
                    print("SRP: fifo toggle command received.", flush=True)
                    toggle_display_safe()
    finally:
        os.close(fd)


def find_device_by_name(name: str) -> str:
    for path in list_devices():
        try:
            device = InputDevice(path)
        except OSError:
            continue
        try:
            if device.name == name:
                return path
        finally:
            device.close()
    return ""


def find_power_key() -> str:
    event_path = "/dev/input/by-path"
    for evt in os.listdir(event_path):
        if "axp221-pek" in evt:
            return os.path.join(event_path, evt)
    return ""


def clone_capabilities(device: InputDevice) -> dict[int, list[int]]:
    return {
        event_type: list(codes)
        for event_type, codes in device.capabilities().items()
        if event_type != ecodes.EV_SYN
    }


def timer_input_power_task(device: UInput) -> None:
    device.write(ecodes.EV_KEY, KEY_POWER, 1)
    device.syn()
    device.write(ecodes.EV_KEY, KEY_POWER, 0)
    device.syn()


def run_lock_key_handler() -> None:
    if not LOCK_KEY_ENABLED:
        print("SRP: lock key handler disabled.", flush=True)
        return

    device_path = find_device_by_name(LOCK_KEY_DEVICE_NAME)
    if not device_path:
        print(f"SRP: lock key device not found: {LOCK_KEY_DEVICE_NAME}", flush=True)
        return

    device = InputDevice(device_path)
    if LOCK_KEY_CODE not in set(device.capabilities().get(ecodes.EV_KEY, [])):
        print(
            f"SRP: lock key code {LOCK_KEY_CODE} not present on {LOCK_KEY_DEVICE_NAME}.",
            flush=True,
        )
        device.close()
        return

    device.grab()
    virtual_device = UInput(
        clone_capabilities(device),
        name="uconsole-sleep-consumer-control",
        vendor=device.info.vendor,
        product=device.info.product,
        version=device.info.version,
        bustype=device.info.bustype,
        phys=f"{device.phys or 'uconsole-sleep'}/virtual",
    )

    saw_lock_key_down = False

    try:
        print(
            f"SRP: lock key handler active on {device.path}, code={LOCK_KEY_CODE}.",
            flush=True,
        )
        for event in device.read_loop():
            if event.type == ecodes.EV_SYN:
                virtual_device.syn()
                continue

            if event.type == ecodes.EV_KEY and event.code == LOCK_KEY_CODE:
                if event.value == 1:
                    saw_lock_key_down = True
                    print("SRP: lock key down input detected.", flush=True)
                elif event.value == 0 and saw_lock_key_down:
                    saw_lock_key_down = False
                    print("SRP: lock key up input detected.", flush=True)
                    toggle_display_safe()
                continue

            virtual_device.write(event.type, event.code, event.value)
    finally:
        try:
            device.ungrab()
        except OSError:
            pass
        device.close()
        virtual_device.close()


def main() -> None:
    power_event_device = find_power_key()
    if not power_event_device:
        raise Exception("there's no matched power key")

    fifo_thread = threading.Thread(target=run_control_fifo_handler, daemon=True)
    fifo_thread.start()

    lock_thread = threading.Thread(target=run_lock_key_handler, daemon=True)
    lock_thread.start()

    device = InputDevice(power_event_device)
    device.grab()
    uinput_device = UInput({ecodes.EV_KEY: [KEY_POWER]}, name="uconsole-sleep-powerkey")

    last_key_down_timestamp = 0.0
    input_power_timer: threading.Timer | None = None

    try:
        for event in device.read_loop():
            if event.type != ecodes.EV_KEY or event.code != KEY_POWER:
                continue

            current_time = time.time()
            if event.value == 1:
                print("SRP: power key down input detected.", flush=True)
                last_key_down_timestamp = current_time
                input_power_timer = threading.Timer(
                    HOLD_TRIGGER_SEC,
                    timer_input_power_task,
                    args=(uinput_device,),
                )
                input_power_timer.start()
            elif event.value == 0:
                print("SRP: power key up input detected.", flush=True)
                if input_power_timer is not None and (current_time - last_key_down_timestamp) < HOLD_TRIGGER_SEC:
                    input_power_timer.cancel()
                    toggle_display_safe()
    finally:
        try:
            device.ungrab()
        except OSError:
            pass
        device.close()
        uinput_device.close()


if __name__ == "__main__":
    main()
