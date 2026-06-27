#!/usr/bin/env python3
"""设置开发环境：编译、创建 bin/ 符号链接、链接 addon 到 fixture_project。

用法：
  python dev.py                    # 构建 + 链接
  python dev.py --no-build         # 仅链接（跳过 cargo build）
  python dev.py --no-link          # 仅构建 + bin 链接（不链接 addon 到 fixture）
  python dev.py --all              # 创建所有平台的 bin 链接
"""
import argparse
import os
import platform
import shutil
import subprocess
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


def _remove_path(p: Path) -> None:
    if p.is_symlink() or p.exists():
        try:
            p.unlink()
        except OSError:
            if p.is_dir():
                shutil.rmtree(p)
            else:
                raise


def _create_link(source: Path, target: Path) -> None:
    """创建符号链接，Windows 目录用 junction（不需要管理员权限），文件用复制。"""
    _remove_path(target)
    if sys.platform == "win32":
        if source.is_dir():
            subprocess.run(
                ["cmd", "/c", "mklink", "/J", str(target), str(source)],
                check=True, capture_output=True,
            )
        else:
            shutil.copy2(source, target)
    else:
        if source.is_dir():
            os.symlink(source, target, target_is_directory=True)
        else:
            os.symlink(source, target)


def setup_bin_links(root: Path, platform_name: str | None = None) -> None:
    """将 target/debug 下的 GDExtension 库链接到 addon/bin/<platform>/。"""
    addon_bin = root / "gdapi" / "addon" / "bin"
    target_debug = root / "target" / "debug"

    if not target_debug.exists():
        print(f"Warning: {target_debug} does not exist. Run 'cargo build' first.")
        return

    platforms = [platform_name] if platform_name else [detect_platform()]
    for plat in platforms:
        lib = LIB_NAMES.get(plat)
        if not lib:
            print(f"  WARN unknown platform: {plat}")
            continue

        dest = addon_bin / plat / lib
        src = target_debug / lib

        gitkeep = dest.parent / ".gitkeep"
        if gitkeep.exists():
            gitkeep.unlink()

        if not src.exists():
            print(f"  WARN {plat}: {lib} not found in {target_debug}")
            continue

        dest.parent.mkdir(parents=True, exist_ok=True)
        _create_link(src, dest)
        print(f"  OK {plat}: {lib} -> {src}")


def link_addon_to_fixture(root: Path) -> None:
    """将 gdapi/addon/ 链接到 tests/fixture_project/addons/gdapi/。"""
    fixture = root / "tests" / "fixture_project"
    addon_dir = fixture / "addons" / "gdapi"
    addon_source = root / "gdapi" / "addon"

    _remove_path(addon_dir)
    addon_dir.parent.mkdir(parents=True, exist_ok=True)
    _create_link(addon_source, addon_dir)
    print(f"  OK addon linked: {addon_dir} -> {addon_source}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Setup gdapi dev environment")
    parser.add_argument("--all", action="store_true", help="Create bin links for all platforms")
    parser.add_argument("--no-build", action="store_true", help="Skip cargo build")
    parser.add_argument("--no-link", action="store_true", help="Skip addon->fixture link")
    args = parser.parse_args()

    root = repo_root()

    # 1. Build
    if not args.no_build:
        print("Building workspace...")
        result = subprocess.run(["cargo", "build", "--workspace"], cwd=root)
        if result.returncode != 0:
            print("Build failed!")
            return result.returncode
    else:
        print("Skipping cargo build (--no-build)")

    # 2. Setup bin links
    print("Setting up bin links...")
    plat = None if args.all else None
    setup_bin_links(root, plat)

    # 3. Link addon to fixture
    if not args.no_link:
        print("Linking addon to fixture...")
        link_addon_to_fixture(root)
    else:
        print("Skipping addon link (--no-link)")

    print()
    print("Done!")
    return 0


if __name__ == "__main__":
    sys.exit(main())
