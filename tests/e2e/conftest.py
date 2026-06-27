"""E2E test fixtures — Godot editor lifecycle management."""
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

import pytest


def _repo_root() -> Path:
    return Path(__file__).resolve().parent.parent.parent


def _gdcli_bin() -> Path:
    name = "gdcli.exe" if sys.platform == "win32" else "gdcli"
    return _repo_root() / "target" / "debug" / name


def _run_gdcli(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [str(_gdcli_bin()), "--json", *args],
        capture_output=True, encoding="utf-8", errors="replace",
    )


@pytest.fixture(scope="session")
def godot_env():
    """Build, install addon, start Godot headless, yield metadata, stop Godot.

    Skips the entire test session if GODOT_BIN is not available or build fails.
    """
    godot_bin = os.environ.get("GODOT_BIN", "godot")
    root = _repo_root()
    fixture = root / "tests" / "fixture_project"
    meta = fixture / ".godot" / "gdapi.json"
    addon_bin = fixture / "addons" / "gdapi" / "bin"
    gdapi_lib = root / "target" / "debug" / (
        "gdapi.dll" if sys.platform == "win32" else "libgdapi.so"
    )

    # Build workspace
    build = subprocess.run(
        ["cargo", "build", "--workspace"],
        cwd=root, capture_output=True, encoding="utf-8", errors="replace",
    )
    if build.returncode != 0:
        pytest.skip(f"cargo build failed:\n{build.stderr}")

    # Install addon
    install = _run_gdcli("install", "--project", str(fixture), "--force")
    if install.returncode != 0:
        pytest.skip(f"gdcli install failed:\n{install.stderr}")

    # Setup bin links
    subprocess.run(
        [sys.executable, str(root / "scripts" / "setup-dev.py")],
        capture_output=True,
    )

    # Copy GDExtension lib on Windows
    if sys.platform == "win32" and gdapi_lib.exists():
        dest_dir = addon_bin / "windows"
        dest_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy2(gdapi_lib, dest_dir / gdapi_lib.name)

    # Remove stale meta
    meta.unlink(missing_ok=True)

    # Start Godot
    try:
        godot = subprocess.Popen(
            [godot_bin, "--editor", "--headless", "--path", str(fixture)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except FileNotFoundError:
        pytest.skip(f"Godot not found: {godot_bin}")

    # Wait for meta
    ready = False
    for _ in range(45):
        if meta.exists():
            ready = True
            break
        time.sleep(1)

    if not ready:
        godot.terminate()
        godot.wait(timeout=10)
        pytest.skip("gdapi.json never appeared within 45s")

    meta_data = json.loads(meta.read_text(encoding="utf-8"))

    yield {
        "godot_bin": godot_bin,
        "root": root,
        "fixture": fixture,
        "meta": meta_data,
        "gdcli": _gdcli_bin(),
    }

    godot.terminate()
    godot.wait(timeout=10)


def gdcli_json(env: dict, *args: str) -> dict:
    """Run gdcli --json and return parsed response."""
    result = subprocess.run(
        [str(env["gdcli"]), "--json", *args],
        capture_output=True, encoding="utf-8", errors="replace",
    )
    if result.returncode != 0:
        raise AssertionError(
            f"gdcli returned {result.returncode}: {args}\n{result.stderr or result.stdout}"
        )
    return json.loads(result.stdout)


def gdcli_expect_fail(env: dict, *args: str) -> int:
    """Run gdcli and assert nonzero exit code. Returns the exit code."""
    result = subprocess.run(
        [str(env["gdcli"]), "--json", *args],
        capture_output=True, encoding="utf-8", errors="replace",
    )
    assert result.returncode != 0, f"expected nonzero exit: {args}\n{result.stdout}"
    return result.returncode
