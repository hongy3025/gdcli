#!/usr/bin/env python3
"""设置开发环境：创建 bin/ 符号链接指向编译产物。

用法：
  python scripts/setup-dev.py          # 设置当前平台
  python scripts/setup-dev.py --all    # 设置所有平台
"""
import argparse
import os
import platform
import shutil
import sys
from pathlib import Path


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def detect_platform() -> str:
    s = platform.system().lower()
    if s == "linux":
        return "linux"
    if s == "darwin":
        return "macos"
    if s == "windows":
        return "windows"
    return "unknown"


LIB_NAMES = {
    "linux": "libgdapi.so",
    "macos": "libgdapi.dylib",
    "windows": "gdapi.dll",
}


def create_link(platform_name: str, addon_bin: Path, target_debug: Path) -> None:
    lib = LIB_NAMES.get(platform_name)
    if not lib:
        print(f"  WARN unknown platform: {platform_name}")
        return

    dest = addon_bin / platform_name / lib
    src = target_debug / lib

    gitkeep = dest.parent / ".gitkeep"
    if gitkeep.exists():
        gitkeep.unlink()

    if not src.exists():
        print(f"  WARN {platform_name}: {lib} not found in {target_debug}")
        return

    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists() or dest.is_symlink():
        dest.unlink()

    if platform_name == "windows":
        shutil.copy2(src, dest)
        print(f"  OK {platform_name}: {lib} -> {src} (copy)")
    else:
        dest.symlink_to(src)
        print(f"  OK {platform_name}: {lib} -> {src}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Setup gdapi dev environment")
    parser.add_argument("--all", action="store_true", help="Create links for all platforms")
    args = parser.parse_args()

    root = repo_root()
    addon_bin = root / "gdapi" / "addon" / "bin"
    target_debug = root / "target" / "debug"

    print("Setting up gdapi dev environment...")
    print(f"  Repo root: {root}")
    print(f"  Addon bin: {addon_bin}")
    print(f"  Target debug: {target_debug}")
    print()

    if not target_debug.exists():
        print(f"Warning: {target_debug} does not exist. Run 'cargo build' first.")

    if args.all:
        print("Creating symlinks for all platforms:")
        for p in ("linux", "macos", "windows"):
            create_link(p, addon_bin, target_debug)
    else:
        p = detect_platform()
        if p == "unknown":
            print("Error: Could not detect platform. Use --all to create all links.")
            return 1
        print(f"Creating link for platform: {p}")
        create_link(p, addon_bin, target_debug)

    print()
    print("Done! You can now link the addon to your Godot project:")
    print(f"  ln -s {root / 'gdapi' / 'addon'} /path/to/your/project/addons/gdapi")
    return 0


if __name__ == "__main__":
    sys.exit(main())
