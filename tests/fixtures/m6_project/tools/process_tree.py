"""Real inherited-pipe descendant used by cross-platform lifecycle regressions."""
from __future__ import annotations

import subprocess
import sys
import time
from pathlib import Path


def main() -> None:
    mode, ready_name, marker_name = sys.argv[1:4]
    ready = Path(ready_name)
    marker = Path(marker_name)
    if mode == "child":
        print("descendant stdout", flush=True)
        print("descendant stderr", file=sys.stderr, flush=True)
        ready.write_text("ready", encoding="utf-8")
        time.sleep(3)
        marker.write_text("descendant survived", encoding="utf-8")
        return
    subprocess.Popen([sys.executable, __file__, "child", str(ready), str(marker)])
    deadline = time.monotonic() + 5
    while not ready.exists():
        if time.monotonic() >= deadline:
            raise RuntimeError("descendant did not start")
        time.sleep(0.01)
    print("parent stdout", flush=True)
    print("parent stderr", file=sys.stderr, flush=True)
    if mode == "wait":
        time.sleep(60)


if __name__ == "__main__":
    main()
