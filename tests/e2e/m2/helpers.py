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
import uuid
from pathlib import Path
from typing import Any

from e2e.timing import positive_seconds, successful_wait

GODOT_BIN_DEFAULT = (
    "D:/app/devel/Godot/v4.7.2/godot_console.exe"
    if sys.platform == "win32"
    else "godot"
)


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


@successful_wait("editor_metadata")
def wait_for_metadata(project: Path, timeout: float = 45.0) -> dict:
    meta = project / ".godot" / "gdapi.json"
    timeout = positive_seconds("GDAPI_E2E_METADATA_TIMEOUT_SECONDS", timeout)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if meta.exists():
            try:
                return json.loads(meta.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                pass
        time.sleep(0.05)
    raise RuntimeError(f"gdapi metadata never appeared at {meta}")


@successful_wait("editor_ready")
def wait_for_godot_ready(project: Path, timeout: float = 30.0) -> None:
    """Wait for the editor initialization markers emitted by the selected mode."""
    log = project / ".godot" / "godot.log"
    layout = project / ".godot" / "editor" / "editor_layout.cfg"
    timeout = positive_seconds("GDAPI_E2E_READY_TIMEOUT_SECONDS", timeout)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if log.exists():
            try:
                content = log.read_text(encoding="utf-8", errors="replace")
                if os.environ.get("GDAPI_E2E_EDITOR_MODE", "headless") == "gui":
                    ready = (
                        layout.is_file()
                        and "OpenGL API" in content
                        and "listening on 127.0.0.1:" in content
                    )
                else:
                    ready = "loading_editor_layout" in content and "DONE" in content
                if ready:
                    return
            except OSError:
                pass
        time.sleep(0.2)
    raise RuntimeError("godot editor did not reach its ready state within timeout")


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


@successful_wait("undo_bridge")
def wait_for_test_result(env: dict, *, request_id: str = "", timeout: float = 10.0) -> dict:
    """Wait for the fixture plugin's next-frame history result.

    给定 `request_id` 时必须匹配该 id，重投命令后不会误读上一次的结果。结果读取容忍
    插件用临时文件 + rename 发布时的 Windows 共享冲突（PermissionError）与半写状态。
    """
    result_path = Path(env["project"]) / ".godot" / "gdapi-test-result.json"
    timeout = positive_seconds("GDAPI_E2E_UNDO_TIMEOUT_SECONDS", timeout)
    deadline = time.monotonic() + timeout
    last_error: OSError | ValueError | None = None
    while time.monotonic() < deadline:
        if result_path.exists():
            try:
                payload = json.loads(result_path.read_text(encoding="utf-8"))
            except (OSError, ValueError) as exc:
                last_error = exc
            else:
                if not request_id or payload.get("request_id") == request_id:
                    return payload
        time.sleep(0.01)
    raise RuntimeError(f"gdapi_test plugin never produced a result (last error: {last_error})")


def history_action(env: dict, action: str) -> dict:
    """Run one editor undo/redo through the fixture plugin's file bridge.

    命令携带 `request_id`；插件对同一 id 只执行一次（重投只重发结果），因此超时后重投
    命令是安全的：既覆盖「命令在编辑器读取前被上一帧的 remove 删除」的竞态，也覆盖
    编辑器短暂卡顿。
    """
    command_path = Path(env["project"]) / ".godot" / "gdapi-test-command.json"
    request_id = uuid.uuid4().hex
    timeout = positive_seconds("GDAPI_E2E_UNDO_TIMEOUT_SECONDS", 10.0)
    last_error: RuntimeError | None = None
    for _attempt in range(3):
        try:
            command_path.write_text(
                json.dumps({"action": action, "request_id": request_id}), encoding="utf-8"
            )
        except OSError as exc:
            last_error = RuntimeError(str(exc))
            continue
        try:
            return wait_for_test_result(env, request_id=request_id, timeout=timeout)
        except RuntimeError as exc:
            last_error = exc
    raise RuntimeError(f"gdapi_test plugin never completed {action}: {last_error}")


def editor_undo(env: dict) -> None:
    payload = history_action(env, "undo")
    assert payload.get("ok") is True, payload


def editor_redo(env: dict) -> None:
    payload = history_action(env, "redo")
    assert payload.get("ok") is True, payload


def editor_clear_undo(env: dict) -> None:
    payload = history_action(env, "clear_undo")
    assert payload.get("ok") is True, payload
