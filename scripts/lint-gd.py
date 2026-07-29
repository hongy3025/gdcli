#!/usr/bin/env python3
"""Run gdlint once per GDScript file in the repository.

gdlint does not provide a repository-wide batch mode, so this script discovers
the files and invokes it separately for each file. A non-zero exit status is
returned when any file fails.
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
    )


def command_environment() -> dict[str, str]:
    environment = os.environ.copy()
    environment.pop("PYTHONHOME", None)
    environment.pop("PYTHONPATH", None)
    return environment


def find_gdlint() -> str:
    command = shutil.which("gdlint")
    if command is not None:
        return command

    print("gdlint is not available; installing gdtoolkit with uv tool...", file=sys.stderr)
    installed = subprocess.run(
        ["uv", "tool", "install", "gdtoolkit"],
        check=False,
        text=True,
        env=command_environment(),
    )
    if installed.returncode != 0:
        raise RuntimeError("uv tool install gdtoolkit failed")

    command = shutil.which("gdlint")
    if command is None:
        raise RuntimeError("gdlint is still unavailable after installing gdtoolkit")
    return command


def main() -> int:
    if sys.argv[1:]:
        print("usage: python scripts/lint-gd.py", file=sys.stderr)
        return 2

    try:
        gdlint = find_gdlint()
    except (FileNotFoundError, RuntimeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 127

    root = repository_root()
    files = gdscript_files(root)
    failures: list[Path] = []
    for path in files:
        result = subprocess.run(
            [gdlint, str(path.relative_to(root))],
            cwd=root,
            check=False,
            text=True,
            capture_output=True,
            env=command_environment(),
        )
        if result.returncode != 0:
            failures.append(path)
            sys.stderr.write(result.stdout)
            sys.stderr.write(result.stderr)

    if failures:
        print(f"gdlint failed for {len(failures)} of {len(files)} GDScript files:", file=sys.stderr)
        for path in failures:
            print(f"  {path.relative_to(root)}", file=sys.stderr)
        return 1

    print(f"gdlint passed for {len(files)} GDScript files.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
