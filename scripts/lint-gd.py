#!/usr/bin/env python3
"""Lint the same applicable GDScript files as format-gd.py.

Intentionally malformed diagnostic fixtures follow the formatter's exclusions;
their parse failures are exercised by the E2E diagnostics tests.
"""

from __future__ import annotations

import os
import shutil
import runpy
import subprocess
import sys
from pathlib import Path




def repository_root() -> Path:
    return Path(__file__).resolve().parent.parent


def gdscript_files(root: Path) -> list[Path]:
    formatter = runpy.run_path(str(Path(__file__).with_name("format-gd.py")))
    return formatter["gdscript_files"](root)


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
