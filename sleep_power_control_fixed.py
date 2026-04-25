#!/usr/bin/env python3
from __future__ import annotations

import os
import time


def find_backlight() -> str:
    return "/sys/class/backlight/backlight@0"


def find_internal_kb(ids: tuple[str, ...] = ("1eaf:0024", "feed:0000", "1eaf:0003")) -> str:
    for device in os.listdir("/sys/bus/usb/devices/"):
        device_path = os.path.join("/sys/bus/usb/devices", device)
        vendor_path = os.path.join(device_path, "idVendor")
        product_path = os.path.join(device_path, "idProduct")

        if not (os.path.isfile(vendor_path) and os.path.isfile(product_path)):
            continue

        with open(vendor_path, "r", encoding="utf-8") as f:
            vid = f.read().strip()

        with open(product_path, "r", encoding="utf-8") as f:
            pid = f.read().strip()

        if f"{vid}:{pid}" in ids:
            return device_path

    return ""


SAVING_CPU_FREQ = os.environ.get("SAVING_CPU_FREQ")
DISABLE_POWER_OFF_KB = os.environ.get("DISABLE_POWER_OFF_KB") == "yes"
DISABLE_CPU_MIN_FREQ = os.environ.get("DISABLE_CPU_MIN_FREQ") == "yes"


def read_text(path: str) -> str:
    with open(path, "r", encoding="utf-8") as f:
        return f.read().strip()


def write_text(path: str, value: str) -> None:
    with open(path, "w", encoding="utf-8") as f:
        f.write(value)


def control_by_state(state: bool) -> None:
    if state:
        if not DISABLE_CPU_MIN_FREQ:
            write_text(os.path.join(cpu_policy_path, "scaling_max_freq"), default_cpu_freq_max)
            print(f"cpu freq max: {default_cpu_freq_max}", flush=True)
            write_text(os.path.join(cpu_policy_path, "scaling_min_freq"), default_cpu_freq_min)
            print(f"cpu freq min: {default_cpu_freq_min}", flush=True)
        if not DISABLE_POWER_OFF_KB:
            write_text(os.path.join(usb_driver_path, "bind"), kb_device_id)
            print("kb power state: bind", flush=True)
        write_text(os.path.join(kb_device_path, "power/control"), "on")
    else:
        write_text(os.path.join(kb_device_path, "power/control"), "auto")
        if not DISABLE_POWER_OFF_KB:
            write_text(os.path.join(usb_driver_path, "unbind"), kb_device_id)
            print("kb power state: unbind", flush=True)
        if not DISABLE_CPU_MIN_FREQ:
            write_text(os.path.join(cpu_policy_path, "scaling_min_freq"), saving_cpu_freq_min)
            print(f"cpu freq min: {saving_cpu_freq_min}", flush=True)
            write_text(os.path.join(cpu_policy_path, "scaling_max_freq"), saving_cpu_freq_max)
            print(f"cpu freq max: {saving_cpu_freq_max}", flush=True)


backlight_path = find_backlight()
kb_device_path = find_internal_kb()
kb_device_id = os.path.basename(kb_device_path)
usb_driver_path = "/sys/bus/usb/drivers/usb"
cpu_policy_path = "/sys/devices/system/cpu/cpufreq/policy0"

if not backlight_path:
    raise Exception("there's no matched backlight")
if not kb_device_path:
    raise Exception("there's no matched kb")

write_text(os.path.join(kb_device_path, "power/autosuspend_delay_ms"), "0")
print(f"{kb_device_path}/power/autosuspend_delay_ms = 0", flush=True)

if not SAVING_CPU_FREQ:
    saving_cpu_freq_min = read_text(os.path.join(cpu_policy_path, "cpuinfo_min_freq"))
    saving_cpu_freq_max = saving_cpu_freq_min
else:
    saving_cpu_freq_min_raw, saving_cpu_freq_max_raw = SAVING_CPU_FREQ.split(",")
    saving_cpu_freq_min = f"{saving_cpu_freq_min_raw}000"
    saving_cpu_freq_max = f"{saving_cpu_freq_max_raw}000"

print(f"saving_cpu_freq_min: {saving_cpu_freq_min}", flush=True)
print(f"saving_cpu_freq_max: {saving_cpu_freq_max}", flush=True)

default_cpu_freq_min = read_text(os.path.join(cpu_policy_path, "scaling_min_freq"))
default_cpu_freq_max = read_text(os.path.join(cpu_policy_path, "scaling_max_freq"))

print(f"default_cpu_freq_min: {default_cpu_freq_min}", flush=True)
print(f"default_cpu_freq_max: {default_cpu_freq_max}", flush=True)

backlight_bl_path = os.path.join(backlight_path, "bl_power")
last_screen_state = ""

while True:
    try:
        screen_state = read_text(backlight_bl_path)
        if screen_state != last_screen_state:
            last_screen_state = screen_state
            control_by_state(screen_state != "4")
        time.sleep(1.0)
    except Exception as e:
        print(f"Error occurred: {e}", flush=True)
        time.sleep(1.0)
