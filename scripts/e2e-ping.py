#!/usr/bin/env python3
"""端到端验证：启动 Godot 编辑器，运行 gdcli exec ping，验证响应。

用法：
  python scripts/e2e-ping.py

环境变量：
  GODOT_BIN  — Godot 可执行文件路径（默认: godot）
"""
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def main() -> int:
    godot_bin = os.environ.get("GODOT_BIN", "godot")
    root = repo_root()
    fixture = root / "tests" / "fixture_project"
    addon_dir = fixture / "addons" / "gdapi"
    gdcli_bin = root / "target" / "debug" / ("gdcli.exe" if sys.platform == "win32" else "gdcli")
    meta = fixture / ".godot" / "gdapi.json"

    # 1. Install addon via gdcli
    subprocess.run([str(gdcli_bin), "install", "--project", str(fixture), "--force"], check=True)

    # 2. Setup bin links
    subprocess.run([sys.executable, str(root / "scripts" / "setup-dev.py")], check=True)

    # 3. Remove stale meta
    meta.unlink(missing_ok=True)

    # 4. Start Godot
    print("Starting Godot editor...")
    godot = subprocess.Popen(
        [godot_bin, "--editor", "--headless", "--path", str(fixture)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    try:
        # 5. Wait for meta
        ready = False
        for _ in range(30):
            if meta.exists():
                ready = True
                print(f"gdapi meta appeared: {meta}")
                print(meta.read_text())
                break
            time.sleep(1)

        if not ready:
            print("ERROR: gdapi.json never appeared", file=sys.stderr)
            return 1

        # 6. Call ping
        print(f"Calling: gdcli exec ping --project {fixture}")
        result = subprocess.run(
            [str(gdcli_bin), "exec", "ping", "--project", str(fixture)],
            capture_output=True, encoding="utf-8", errors="replace",
        )
        output = result.stdout.strip()
        print(f"Response: {output}")

        # 7. Verify
        if '"ok":true' in output:
            print("PASS: e2e ping succeeded")
            return 0
        else:
            print("FAIL: unexpected response", file=sys.stderr)
            return 1
    finally:
        godot.terminate()
        godot.wait(timeout=10)


if __name__ == "__main__":
    sys.exit(main())
