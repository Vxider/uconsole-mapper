#!/usr/bin/env python3

from __future__ import annotations

import argparse
from datetime import datetime
from pathlib import Path
import re
import sys


BEGIN_MARKER = "<!-- uconsole-mapper:keybinds begin -->"
END_MARKER = "<!-- uconsole-mapper:keybinds end -->"


def managed_block(item_indent: str) -> str:
    action_indent = item_indent + "  "
    return "\n".join(
        [
            f"{item_indent}{BEGIN_MARKER}",
            f'{item_indent}<keybind key="F20">',
            f'{action_indent}<action name="Execute" command="~/.local/bin/run-or-raise-chromium" />',
            f"{item_indent}</keybind>",
            f'{item_indent}<keybind key="S-Return">',
            f'{action_indent}<action name="Execute" command="~/.local/bin/shift-enter-newline" />',
            f"{item_indent}</keybind>",
            f"{item_indent}{END_MARKER}",
        ]
    )


DEFAULT_RC_XML = f"""<?xml version="1.0"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <keyboard>
{managed_block("    ")}
  </keyboard>
</openbox_config>
"""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--config",
        type=Path,
        default=Path("~/.config/labwc/rc.xml").expanduser(),
    )
    return parser.parse_args()


def backup_path(path: Path) -> Path:
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    return path.with_name(f"{path.name}.bak.{stamp}")


def replace_managed_block(text: str) -> tuple[str, str]:
    if BEGIN_MARKER in text and END_MARKER in text:
        marker_match = re.search(rf"(?m)^([ \t]*){re.escape(BEGIN_MARKER)}$", text)
        item_indent = marker_match.group(1) if marker_match else "    "
        pattern = re.compile(
            rf"(?ms)^[ \t]*{re.escape(BEGIN_MARKER)}\n.*?^[ \t]*{re.escape(END_MARKER)}$",
        )
        return pattern.sub(managed_block(item_indent), text, count=1), "updated"

    if "run-or-raise-chromium" in text or "shift-enter-newline" in text:
        return text, "skipped-existing"

    keyboard_close = re.search(r"(?m)^([ \t]*)</keyboard>\s*$", text)
    if keyboard_close:
        keyboard_indent = keyboard_close.group(1)
        item_indent = keyboard_indent + "  "
        replacement = f"{managed_block(item_indent)}\n{keyboard_indent}</keyboard>"
        return text[: keyboard_close.start()] + replacement + text[keyboard_close.end() :], "inserted"

    root_close = re.search(r"(?m)^([ \t]*)</(?:openbox_config|labwc_config)>\s*$", text)
    if root_close:
        root_indent = root_close.group(1)
        keyboard_indent = root_indent + "  "
        item_indent = keyboard_indent + "  "
        insertion = f"{keyboard_indent}<keyboard>\n{managed_block(item_indent)}\n{keyboard_indent}</keyboard>\n"
        return text[: root_close.start()] + insertion + text[root_close.start() :], "inserted"

    raise ValueError("labwc rc.xml has no <keyboard> or root closing tag")


def main() -> int:
    args = parse_args()
    config_path = args.config.expanduser()
    config_path.parent.mkdir(parents=True, exist_ok=True)

    if not config_path.exists():
        config_path.write_text(DEFAULT_RC_XML, encoding="utf-8")
        print(f"created {config_path}")
        return 0

    original = config_path.read_text(encoding="utf-8")
    updated, status = replace_managed_block(original)

    if status == "skipped-existing":
        print(f"skipped {config_path}: existing Chromium or Shift+Enter keybinds detected")
        return 0

    if updated == original:
        print(f"unchanged {config_path}")
        return 0

    backup = backup_path(config_path)
    backup.write_text(original, encoding="utf-8")
    config_path.write_text(updated, encoding="utf-8")
    print(f"{status} {config_path}")
    print(f"backup {backup}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
