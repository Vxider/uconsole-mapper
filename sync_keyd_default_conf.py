#!/usr/bin/env python3

from __future__ import annotations

import argparse
from datetime import datetime
from pathlib import Path
import re
import sys


BEGIN_MARKER = "# uconsole-mapper:keyd begin"
END_MARKER = "# uconsole-mapper:keyd end"
MANAGED_BLOCK = f"""{BEGIN_MARKER}
include uconsole-mapper
{END_MARKER}"""
DEFAULT_CONF = f"""[ids]
*
{MANAGED_BLOCK}
"""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--config",
        type=Path,
        default=Path("/etc/keyd/default.conf"),
    )
    return parser.parse_args()


def backup_path(path: Path) -> Path:
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    return path.with_name(f"{path.name}.bak.{stamp}")


def replace_managed_block(text: str) -> tuple[str, str]:
    if BEGIN_MARKER in text and END_MARKER in text:
        pattern = re.compile(
            re.escape(BEGIN_MARKER) + r".*?" + re.escape(END_MARKER),
            re.DOTALL,
        )
        return pattern.sub(MANAGED_BLOCK, text, count=1), "updated"

    if re.search(r"(?m)^include\s+uconsole-mapper\s*$", text):
        return text, "unchanged"

    lines = text.splitlines()
    ids_index: int | None = None
    first_section: str | None = None

    for index, line in enumerate(lines):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.startswith("[") and stripped.endswith("]"):
            first_section = stripped
            ids_index = index
            break
        raise ValueError("keyd config has content before the first section header")

    if ids_index is None or first_section != "[ids]":
        raise ValueError("keyd config must start with an [ids] section")

    insert_at = len(lines)
    for index in range(ids_index + 1, len(lines)):
        stripped = lines[index].strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            insert_at = index
            break

    new_lines = lines[:insert_at] + MANAGED_BLOCK.splitlines() + lines[insert_at:]
    return "\n".join(new_lines) + "\n", "inserted"


def main() -> int:
    args = parse_args()
    config_path = args.config
    config_path.parent.mkdir(parents=True, exist_ok=True)

    if not config_path.exists():
        config_path.write_text(DEFAULT_CONF, encoding="utf-8")
        print(f"created {config_path}")
        return 0

    original = config_path.read_text(encoding="utf-8")
    updated, status = replace_managed_block(original)

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
