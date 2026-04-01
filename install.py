#!/usr/bin/env python3
"""Install NickTagger addon into the WoW AddOns directory."""

import shutil
import sys
from pathlib import Path

ADDON_NAME = "NickTagger"
WOW_ADDONS_DIR = Path("/Applications/World of Warcraft/_retail_/Interface/AddOns")

INCLUDE = [
    "NickTagger.toc",
    "NickTagger.lua",
]


def main():
    project_root = Path(__file__).resolve().parent
    target_dir = WOW_ADDONS_DIR / ADDON_NAME

    if not WOW_ADDONS_DIR.exists():
        print(f"Error: WoW AddOns directory not found: {WOW_ADDONS_DIR}", file=sys.stderr)
        sys.exit(1)

    if target_dir.exists():
        shutil.rmtree(target_dir)
        print(f"Removed old install: {target_dir}")

    target_dir.mkdir()

    for entry in INCLUDE:
        src = project_root / entry
        dst = target_dir / entry
        if not src.exists():
            print(f"Warning: {entry} not found, skipping", file=sys.stderr)
            continue
        if src.is_dir():
            shutil.copytree(src, dst)
        else:
            shutil.copy2(src, dst)

    print(f"Installed {ADDON_NAME} to {target_dir}")


if __name__ == "__main__":
    main()
