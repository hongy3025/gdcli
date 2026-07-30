#!/usr/bin/env python3
"""Format every tracked GDScript source file with gdformat.

Run from any directory with:
    python scripts/format-gd.py
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path


SKIP_DIRECTORIES = {
    ".git",
    ".godot",
    ".pytest-m5",
    "__pycache__",
    "target",
}
SKIP_FILES = {
    "tests/fixtures/m2_project/scripts/broken.gd",
    "tests/fixtures/m5_project/fixtures/broken.gd",
    "tests/fixtures/e2e_project/fixtures/broken.gd",
    "tests/fixtures/e2e_project/scripts/broken.gd",
}
MAX_BATCH_FILES = 10


def repository_root() -> Path:
    return Path(__file__).resolve().parent.parent


def gdscript_files(root: Path) -> list[Path]:
    return sorted(
        path
        for path in root.rglob("*.gd")
        if not any(
            part in SKIP_DIRECTORIES or part.startswith(".")
            for part in path.relative_to(root).parts
        )
        and path.relative_to(root).as_posix() not in SKIP_FILES
    )


def batches(files: list[Path], root: Path) -> list[list[Path]]:
    result: list[list[Path]] = []
    current: list[Path] = []
    for path in files:
        if len(current) == MAX_BATCH_FILES:
            result.append(current)
            current = []
        current.append(path)
    if current:
        result.append(current)
    return result


def gdformat_environment() -> dict[str, str]:
    """Avoid passing a different Python runtime into gdformat.exe."""
    environment = os.environ.copy()
    environment.pop("PYTHONHOME", None)
    environment.pop("PYTHONPATH", None)
    return environment


def run_gdformat(
    gdformat: str, root: Path, files: list[Path], *, check: bool
) -> subprocess.CompletedProcess[str]:
    arguments = [gdformat, "--fast"]
    if check:
        arguments.append("--check")
    arguments.extend(str(path.relative_to(root)) for path in files)
    return subprocess.run(
        arguments,
        cwd=root,
        check=False,
        capture_output=True,
        text=True,
        env=gdformat_environment(),
    )


def main() -> int:
    if set(sys.argv[1:]) - {"--check"}:
        print("usage: python scripts/format-gd.py [--check]", file=sys.stderr)
        return 2
    check = "--check" in sys.argv[1:]
    gdformat = shutil.which("gdformat")
    if gdformat is None:
        print("error: gdformat is not available on PATH", file=sys.stderr)
        return 127

    root = repository_root()
    files = gdscript_files(root)
    failures: list[Path] = []
    for batch in batches(files, root):
        result = run_gdformat(gdformat, root, batch, check=check)
        if result.returncode == 0:
            continue
        for path in batch:
            single = run_gdformat(gdformat, root, [path], check=check)
            if single.returncode != 0:
                failures.append(path)
                sys.stderr.write(single.stdout)
                sys.stderr.write(single.stderr)

    if failures:
        print("gdformat failed for:", file=sys.stderr)
        for path in failures:
            print(f"  {path.relative_to(root)}", file=sys.stderr)
        return 1

    action = "check passed" if check else "completed"
    print(f"gdformat {action} for {len(files)} GDScript files.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
