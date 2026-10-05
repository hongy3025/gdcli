#!/usr/bin/env python3
"""Build gdapi and install it into the repository's sample Godot project."""

import subprocess
import sys
from pathlib import Path


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def run_step(root: Path, label: str, command: list[str]) -> int:
    print(f"\n== {label} ==", flush=True)
    return subprocess.run(command, cwd=root).returncode


def remove_embedded_temp_files(addon: Path) -> None:
    removed = 0
    for temporary in addon.rglob("*.TMP"):
        temporary.unlink()
        removed += 1
    if removed:
        print(f"Removed {removed} temporary plugin file(s).")


def main() -> int:
    root = repo_root()
    project = root / "godot" / "sample_project"
    if not (project / "project.godot").is_file():
        print(f"Godot sample project not found: {project}", file=sys.stderr)
        return 1

    result = run_step(
        root,
        "Build gdapi and prepare its platform library",
        [sys.executable, str(root / "scripts" / "setup-dev.py"), "--no-link"],
    )
    if result != 0:
        return result

    result = run_step(
        root,
        "Install and enable gdapi in godot/sample_project",
        [
            "cargo",
            "run",
            "--package",
            "gdcli",
            "--",
            "install",
            "--project",
            str(project),
            "--force",
        ],
    )
    if result != 0:
        return result

    remove_embedded_temp_files(project / "addons" / "gdapi")
    return 0


if __name__ == "__main__":
    sys.exit(main())
