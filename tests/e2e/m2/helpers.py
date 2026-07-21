"""M2 test helpers — shared between conftest and tests."""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

GODOT_BIN_DEFAULT = "D:/app/devel/Godot/v4.7.1/godot_console.exe"


# ── Paths and binaries ─────────────────────────────────────────────────────


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent.parent.parent


def gdcli_bin() -> Path:
    name = "gdcli.exe" if sys.platform == "win32" else "gdcli"
    return repo_root() / "target" / "debug" / name


def resolve_godot_bin() -> str:
    return os.environ.get("GODOT_BIN", GODOT_BIN_DEFAULT)


# ── Godot version helpers ──────────────────────────────────────────────────


def parse_godot_version(output: str) -> tuple[int, int, int]:
    match = re.search(r"(?:v)?(\d+)\.(\d+)(?:\.(\d+))?", output)
    if match is None:
        raise RuntimeError(f"Godot 4.7.x is required; cannot parse version: {output!r}")
    return int(match.group(1)), int(match.group(2)), int(match.group(3) or 0)


def require_godot_47(godot_bin: str) -> tuple[int, int, int]:
    try:
        result = subprocess.run(
            [godot_bin, "--version"],
            capture_output=True, encoding="utf-8", errors="replace", timeout=15,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired) as exc:
        raise RuntimeError(f"Godot 4.7.x is required: {exc}") from exc
    version = parse_godot_version(result.stdout or result.stderr)
    if version[:2] != (4, 7):
        raise RuntimeError(
            f"Godot 4.7.x is required; found {version[0]}.{version[1]}.{version[2]}"
        )
    return version


# ── Native library and metadata ────────────────────────────────────────────


def copy_native_library(root: Path, project: Path) -> None:
    if sys.platform == "win32":
        source = root / "target" / "debug" / "gdapi.dll"
        destination = project / "addons" / "gdapi" / "bin" / "windows" / "gdapi.dll"
    elif sys.platform == "darwin":
        source = root / "target" / "debug" / "libgdapi.dylib"
        destination = project / "addons" / "gdapi" / "bin" / "macos" / "libgdapi.dylib"
    else:
        source = root / "target" / "debug" / "libgdapi.so"
        destination = project / "addons" / "gdapi" / "bin" / "linux" / "libgdapi.so"
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)


def wait_for_metadata(project: Path, timeout: float = 45.0) -> dict:
    meta = project / ".godot" / "gdapi.json"
    deadline = time.time() + timeout
    while time.time() < deadline:
        if meta.exists():
            try:
                return json.loads(meta.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                pass
        time.sleep(1.0)
    raise RuntimeError(f"gdapi metadata never appeared at {meta}")


def wait_for_godot_ready(project: Path, timeout: float = 30.0) -> None:
    """Wait until the editor fully finishes loading (logs include 'Editor layout ready')."""
    log = project / ".godot" / "godot.log"
    deadline = time.time() + timeout
    while time.time() < deadline:
        if log.exists():
            try:
                if "Editor layout ready" in log.read_text(encoding="utf-8", errors="replace"):
                    return
            except OSError:
                pass
        time.sleep(0.2)
    raise RuntimeError("godot never reached 'Editor layout ready' within timeout")


# ── gdcli exec wrappers ────────────────────────────────────────────────────


def gdcli_exec(env: dict, *args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        [str(env["gdcli"]), "--json", *args],
        capture_output=True, encoding="utf-8", errors="replace", check=check,
    )


# keep gdcli_exec as alias for legacy callers



def exec_ok(env: dict, route: str, data: dict | None = None) -> dict[str, Any]:
    args = ["exec", route, "--project", str(env["project"])]
    if data is not None:
        args += ["--data", json.dumps(data)]
    result = subprocess.run(
        [str(env["gdcli"]), "--json", *args],
        capture_output=True, encoding="utf-8", errors="replace",
    )
    if result.returncode != 0:
        print("\n[gdcli failed]", args)
        print("STDOUT:", result.stdout)
        print("STDERR:", result.stderr)
    payload = json.loads(result.stdout)
    assert payload.get("ok") is True, f"{route}: {payload}"
    return payload


def exec_error(env: dict, route: str, data: dict | None = None) -> dict[str, Any]:
    args = ["exec", route, "--project", str(env["project"])]
    if data is not None:
        args += ["--data", json.dumps(data)]
    result = gdcli_exec(env, *args, check=False)
    assert result.returncode != 0, f"expected failure for {route}: {result.stdout}"
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        try:
            return json.loads(result.stderr.split(": ", 1)[1])
        except Exception:
            return {"code": "unknown", "error": result.stderr or result.stdout}


def command_doc(env: dict, route: str) -> dict[str, Any]:
    result = gdcli_exec(
        env,
        "exec", "command/doc", route,
        "--project", str(env["project"]),
    )
    payload = json.loads(result.stdout)
    assert payload.get("ok") is True, f"command/doc {route}: {payload}"
    return payload["doc"]


# ── File-system helpers ────────────────────────────────────────────────────


def tree_digest(project: Path) -> str:
    """Stable digest of project file tree (excluding runtime directories)."""
    skip_dirs = {".godot", "__pycache__"}
    skip_path_prefixes = ("addons/gdapi/bin",)
    digest = hashlib.sha256()
    for path in sorted(project.rglob("*")):
        if not path.is_file():
            continue
        rel = path.relative_to(project)
        rel_str = str(rel).replace("\\", "/")
        parts = rel.parts
        if any(p in skip_dirs for p in parts):
            continue
        if any(rel_str.startswith(p) for p in skip_path_prefixes):
            continue
        digest.update(rel_str.encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


# ── gdapi_test bridge ──────────────────────────────────────────────────────


def wait_for_test_result(env: dict, timeout: float = 2.0) -> dict:
    result_path = env["project"] / ".godot" / "gdapi-test-result.json"
    deadline = time.time() + timeout
    while time.time() < deadline:
        if result_path.exists():
            return json.loads(result_path.read_text(encoding="utf-8"))
        time.sleep(0.05)
    raise RuntimeError("gdapi_test plugin never produced a result")


def editor_undo(env: dict) -> None:
    result_path = env["project"] / ".godot" / "gdapi-test-result.json"
    result_path.unlink(missing_ok=True)
    command = env["project"] / ".godot" / "gdapi-test-command.json"
    command.write_text(json.dumps({"action": "undo"}), encoding="utf-8")
    payload = wait_for_test_result(env)
    assert payload.get("ok") is True, payload


def editor_redo(env: dict) -> None:
    result_path = env["project"] / ".godot" / "gdapi-test-result.json"
    result_path.unlink(missing_ok=True)
    command = env["project"] / ".godot" / "gdapi-test-command.json"
    command.write_text(json.dumps({"action": "redo"}), encoding="utf-8")
    payload = wait_for_test_result(env)
    assert payload.get("ok") is True, payload
