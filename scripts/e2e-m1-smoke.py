#!/usr/bin/env python3
"""M1 路由基础设施端到端验证。

用法：
  python scripts/e2e-m1-smoke.py

环境变量：
  GODOT_BIN  — Godot 可执行文件路径（默认: godot）
"""
import json
import os
import subprocess
import sys
import time
from pathlib import Path


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def gdcli_bin() -> Path:
    name = "gdcli.exe" if sys.platform == "win32" else "gdcli"
    return repo_root() / "target" / "debug" / name


def run_json(args: list[str]) -> dict:
    result = subprocess.run(
        [str(gdcli_bin()), "--json"] + args,
        capture_output=True, encoding="utf-8", errors="replace",
    )
    if result.returncode != 0:
        raise RuntimeError(f"gdcli failed: {args}\n{result.stderr or result.stdout}")
    return json.loads(result.stdout)


def assert_exit_nonzero(args: list[str]) -> None:
    result = subprocess.run(
        [str(gdcli_bin()), "--json"] + args,
        capture_output=True, encoding="utf-8", errors="replace",
    )
    if result.returncode == 0:
        raise RuntimeError(f"expected nonzero exit: {args}")


def main() -> int:
    godot_bin = os.environ.get("GODOT_BIN", "godot")
    root = repo_root()
    fixture = root / "tests" / "fixture_project"
    meta = fixture / ".godot" / "gdapi.json"
    addon_bin = fixture / "addons" / "gdapi" / "bin"
    gdapi_lib = root / "target" / "debug" / ("gdapi.dll" if sys.platform == "win32" else "libgdapi.so")

    # Build
    subprocess.run(["cargo", "build", "--workspace"], check=True, cwd=root)

    # Install addon
    subprocess.run(
        [str(gdcli_bin()), "install", "--project", str(fixture), "--force"],
        check=True,
    )

    # Setup bin links
    subprocess.run([sys.executable, str(root / "scripts" / "setup-dev.py")], check=True)

    # Copy GDExtension lib for Windows
    if sys.platform == "win32" and gdapi_lib.exists():
        dest_dir = addon_bin / "windows"
        dest_dir.mkdir(parents=True, exist_ok=True)
        import shutil
        shutil.copy2(gdapi_lib, dest_dir / gdapi_lib.name)

    # Remove stale meta
    meta.unlink(missing_ok=True)

    # Start Godot
    godot = subprocess.Popen(
        [godot_bin, "--editor", "--headless", "--path", str(fixture)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    try:
        # Wait for meta
        ready = False
        for _ in range(45):
            if meta.exists():
                ready = True
                break
            time.sleep(1)
        if not ready:
            print("ERROR: gdapi.json never appeared", file=sys.stderr)
            return 1

        # Ping
        ping = run_json(["exec", "ping", "--project", str(fixture)])
        if not ping.get("ok"):
            raise RuntimeError(f"ping did not return ok:true: {ping}")

        # Routes
        routes = run_json(["exec", "routes", "--project", str(fixture)])
        for name in ("editor/scene/create", "scene/create", "shared/godot/version", "godot/version"):
            if name not in routes["routes"]:
                raise RuntimeError(f"missing route: {name}")
        if routes["aliases"].get("scene/create") != "editor/scene/create":
            raise RuntimeError("scene/create alias metadata missing")

        # Commands metadata
        commands = run_json(["exec", "commands", "--project", str(fixture)])
        scene_create = next(
            (c for c in commands["commands"] if c["path"] == "editor/scene/create"), None,
        )
        if not scene_create:
            raise RuntimeError("commands missing editor/scene/create")
        if scene_create["canonical_path"] != "editor/scene/create":
            raise RuntimeError("canonical_path mismatch")

        # Command-help legacy alias
        help_doc = run_json(["exec", "command-help", "scene/create", "--project", str(fixture)])
        if help_doc["doc"]["canonical_path"] != "editor/scene/create":
            raise RuntimeError("legacy command-help did not resolve canonical path")

        # Path check — safe
        safe = run_json([
            "exec", "project/health/path_check",
            "--project", str(fixture),
            "--data", '{"path":"scenes/test.tscn","mode":"read"}',
        ])
        if safe["path"] != "res://scenes/test.tscn":
            raise RuntimeError(f"path_check did not normalize: {safe['path']}")

        # Path check — traversal rejected
        assert_exit_nonzero([
            "exec", "project/health/path_check",
            "--project", str(fixture),
            "--data", '{"path":"../outside.txt","mode":"read"}',
        ])

        # Audit clear — no force rejected
        assert_exit_nonzero([
            "exec", "project/audit/clear",
            "--project", str(fixture),
            "--data", "{}",
        ])

        # Audit clear — with force
        cleared = run_json([
            "exec", "project/audit/clear",
            "--project", str(fixture),
            "--data", '{"force":true}',
        ])
        if not cleared.get("ok"):
            raise RuntimeError(f"audit clear force failed: {cleared}")

        print("PASS: M1 E2E smoke")
        return 0

    finally:
        godot.terminate()
        godot.wait(timeout=10)


if __name__ == "__main__":
    sys.exit(main())
