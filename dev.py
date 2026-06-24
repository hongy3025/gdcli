#!/usr/bin/env python3
"""
一键构建 + 符号链接安装 addon 到 tests/fixture_project/
跨平台支持：Windows / Linux / macOS
"""
import os
import sys
import shutil
import subprocess
import platform
from pathlib import Path


def get_repo_root() -> Path:
    """获取仓库根目录"""
    return Path(__file__).parent.resolve()


def run_command(cmd: list[str], cwd: Path | None = None) -> int:
    """运行命令并返回退出码"""
    print(f"  $ {' '.join(cmd)}")
    result = subprocess.run(cmd, cwd=cwd)
    return result.returncode


def detect_platform() -> str:
    """检测当前平台"""
    system = platform.system().lower()
    if system == "linux":
        return "linux"
    elif system == "darwin":
        return "macos"
    elif system == "windows":
        return "windows"
    else:
        return "unknown"


def create_symlink(source: Path, target: Path) -> None:
    """创建符号链接，跨平台兼容"""
    # 移除已存在的目标
    if target.is_symlink() or target.exists():
        try:
            target.unlink()
        except OSError:
            if target.is_dir():
                shutil.rmtree(target)
            else:
                raise

    # Windows 上使用 junction（目录）或复制（文件）
    if sys.platform == "win32":
        if source.is_dir():
            # junction 不需要管理员权限，等同于目录符号链接
            subprocess.run(
                ["cmd", "/c", "mklink", "/J", str(target), str(source)],
                check=True,
                capture_output=True,
            )
        else:
            # junction 不支持文件，直接复制
            shutil.copy2(source, target)
    else:
        # Linux / macOS
        if source.is_dir():
            os.symlink(source, target, target_is_directory=True)
        else:
            os.symlink(source, target)


def setup_bin_symlinks(repo_root: Path, platform_name: str | None = None) -> None:
    """设置 bin 符号链接"""
    addon_bin = repo_root / "gdapi" / "addon" / "bin"
    target_debug = repo_root / "target" / "debug"

    print("Setting up gdapi dev environment...")
    print(f"  Repo root: {repo_root}")
    print(f"  Addon bin: {addon_bin}")
    print(f"  Target debug: {target_debug}")
    print()

    if not target_debug.exists():
        print(f"Warning: {target_debug} does not exist. Run 'cargo build' first.")

    # 平台库文件映射
    platform_libs = {
        "linux": "libgdapi.so",
        "macos": "libgdapi.dylib",
        "windows": "gdapi.dll",
    }

    platforms_to_setup = []
    if platform_name:
        platforms_to_setup = [platform_name]
    else:
        detected = detect_platform()
        if detected == "unknown":
            print("Error: Could not detect platform. Specify platform explicitly.")
            sys.exit(1)
        platforms_to_setup = [detected]

    for plat in platforms_to_setup:
        lib_name = platform_libs.get(plat)
        if not lib_name:
            print(f"  [WARN] Unknown platform: {plat}")
            continue

        target_dir = addon_bin / plat
        source_file = target_debug / lib_name

        # 移除 .gitkeep
        gitkeep = target_dir / ".gitkeep"
        if gitkeep.exists():
            gitkeep.unlink()

        if source_file.exists():
            target_dir.mkdir(parents=True, exist_ok=True)
            link_target = target_dir / lib_name
            create_symlink(source_file, link_target)
            print(f"  [OK] {plat}: {lib_name} -> {source_file}")
        else:
            print(f"  [WARN] {plat}: {lib_name} not found in {target_debug}")


def link_addon_to_fixture(repo_root: Path) -> None:
    """链接 addon 到 fixture_project"""
    fixture = repo_root / "tests" / "fixture_project"
    addon_dir = fixture / "addons" / "gdapi"
    addon_source = repo_root / "gdapi" / "addon"

    # 移除已存在的 addon 目录
    if addon_dir.exists() or addon_dir.is_symlink():
        try:
            addon_dir.unlink()
        except OSError:
            shutil.rmtree(addon_dir)

    # 确保 addons 父目录存在
    addons_parent = addon_dir.parent
    addons_parent.mkdir(parents=True, exist_ok=True)

    # 创建符号链接
    create_symlink(addon_source, addon_dir)
    print()
    print(f"Done! addon linked: {addon_dir} -> {addon_source}")


def main() -> None:
    repo_root = get_repo_root()

    # 1. 构建
    print("Building workspace...")
    ret = run_command(["cargo", "build", "--workspace"], cwd=repo_root)
    if ret != 0:
        print("Build failed!")
        sys.exit(ret)

    # 2. 设置 bin 符号链接
    setup_bin_symlinks(repo_root)

    # 3. 符号链接 addon
    link_addon_to_fixture(repo_root)


if __name__ == "__main__":
    main()
