"""E2E test fixtures — Godot editor lifecycle management."""
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

import pytest


E2E_DEADLOCK_TIMEOUT_SECONDS = 180


def pytest_collection_modifyitems(items):
    """Bound deadlocks; operation-specific tests keep their own readiness limits."""
    timeout_marker = pytest.mark.timeout(E2E_DEADLOCK_TIMEOUT_SECONDS)
    for item in items:
        item.add_marker(timeout_marker)


def parse_godot_version(output: str) -> tuple[int, int, int]:
    match = re.search(r"(?:v)?(\d+)\.(\d+)(?:\.(\d+))?", output)
    if match is None:
        raise RuntimeError(f"Godot 4.7.x is required; cannot parse version: {output!r}")
    return int(match.group(1)), int(match.group(2)), int(match.group(3) or 0)


def require_godot_47(godot_bin: str) -> tuple[int, int, int]:
    try:
        result = subprocess.run(
            [godot_bin, "--version"],
            capture_output=True,
            encoding="utf-8",
            errors="replace",
            timeout=15,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired) as exc:
        raise RuntimeError(f"Godot 4.7.x is required: {exc}") from exc
    version = parse_godot_version(result.stdout or result.stderr)
    if version[:2] != (4, 7):
        raise RuntimeError(
            f"Godot 4.7.x is required; found {version[0]}.{version[1]}.{version[2]}"
        )
    return version


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


def _fixture_runtime_root(fixture: Path) -> Path:
    fixture = fixture.resolve()
    godot_dir = (fixture / ".godot").resolve()
    if godot_dir.parent != fixture or godot_dir.name != ".godot":
        raise RuntimeError(f"unexpected fixture metadata root: {godot_dir}")
    runtime_root = (godot_dir / "gdapi_runtime").resolve()
    if runtime_root.parent != godot_dir or runtime_root.name != "gdapi_runtime":
        raise RuntimeError(f"unexpected fixture runtime root: {runtime_root}")
    return runtime_root


def _cleanup_fixture_runtime(fixture: Path) -> None:
    """Remove only the source fixture's known runtime transport root."""
    runtime_root = _fixture_runtime_root(fixture)
    if runtime_root.exists():
        shutil.rmtree(runtime_root)


def _teardown_godot_fixture(godot: subprocess.Popen, fixture: Path) -> None:
    """Stop the fixture editor before removing its exact runtime transport root."""
    try:
        godot.terminate()
        try:
            godot.wait(timeout=10)
        except subprocess.TimeoutExpired:
            godot.kill()
            godot.wait(timeout=10)
    finally:
        _cleanup_fixture_runtime(fixture)


@pytest.fixture(scope="session")
def godot_env():
    """Build, install addon, start Godot headless, yield metadata, stop Godot.

    Skips the entire test session if GODOT_BIN is not available or build fails.
    """
    godot_bin = os.environ.get("GODOT_BIN", "godot")
    try:
        godot_version = require_godot_47(godot_bin)
    except RuntimeError as exc:
        pytest.fail(str(exc), pytrace=False)
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

    # Setup bin links + link addon to fixture
    subprocess.run(
        [sys.executable, str(root / "scripts" / "setup-dev.py"), "--no-build"],
        capture_output=True,
    )

    # Copy GDExtension lib on Windows
    if sys.platform == "win32" and gdapi_lib.exists():
        dest_dir = addon_bin / "windows"
        dest_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy2(gdapi_lib, dest_dir / gdapi_lib.name)

    # Remove stale metadata and the exact file-transport root before startup.
    meta.unlink(missing_ok=True)
    _cleanup_fixture_runtime(fixture)

    # Start Godot
    godot = subprocess.Popen(
        [godot_bin, "--editor", "--headless", "--path", str(fixture)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    # Wait for meta
    ready = False
    for _ in range(45):
        if meta.exists():
            ready = True
            break
        time.sleep(1)

    if not ready:
        _teardown_godot_fixture(godot, fixture)
        pytest.skip("gdapi.json never appeared within 45s")

    meta_data = json.loads(meta.read_text(encoding="utf-8"))

    yield {
        "godot_bin": godot_bin,
        "godot_version": godot_version,
        "root": root,
        "fixture": fixture,
        "meta": meta_data,
        "gdcli": _gdcli_bin(),
    }

    _teardown_godot_fixture(godot, fixture)


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


def run_godot_script(
    env: dict,
    script: str,
    *,
    editor: bool = False,
    extra_env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess:
    """Run a Godot GDScript test through --headless --script."""
    command = [env["godot_bin"], "--headless", "--path", str(env["fixture"])]
    if editor:
        command.append("--editor")
    command += ["--script", script]
    process_env = os.environ.copy()
    process_env.update(extra_env or {})
    return subprocess.run(
        command,
        capture_output=True,
        encoding="utf-8",
        errors="replace",
        env=process_env,
        timeout=45,
    )
