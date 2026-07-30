"""Debug script to test network/http_request with various URLs."""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import time
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from e2e.m2.helpers import gdcli_bin, repo_root, resolve_godot_bin, require_godot_47

godot_bin = resolve_godot_bin()
require_godot_47(godot_bin)

tmpdir = Path(tempfile.mkdtemp("gdcli-debug"))
project = tmpdir / "project"
fixture = repo_root() / "tests" / "fixtures" / "m6_project"
shutil.copytree(fixture, project)

policy = {
    "version": 1,
    "capabilities": {
        "network": {
            "enabled": True, "schemes": ["http"], "hosts": ["127.0.0.1", "localhost"],
            "ports": [80, 443, 18923], "allow_private": True, "max_redirects": 5,
            "max_timeout_ms": 5000, "max_response_bytes": 1048576,
        },
    },
}
pdir = project / ".godot"
pdir.mkdir(parents=True, exist_ok=True)
(pdir / "gdapi-policy.json").write_text(json.dumps(policy), encoding="utf-8")
print("Policy file:", (pdir / "gdapi-policy.json").read_text())

install = subprocess.run(
    [str(gdcli_bin()), "install", "--project", str(project), "--force"],
    capture_output=True, encoding="utf-8", errors="replace",
)
print("Install:", install.returncode, install.stderr[:200] if install.stderr else "ok")

log_path = pdir / "godot.log"
log_handle = log_path.open("w", encoding="utf-8")
godot = subprocess.Popen(
    [godot_bin, "--editor", "--headless", "--path", str(project)],
    stdout=log_handle, stderr=subprocess.STDOUT,
)

time.sleep(25)

for url in ["http://127.0.0.1:18923/ok", "http://localhost:18923/ok"]:
    r = subprocess.run(
        [str(gdcli_bin()), "--json", "exec", "network/http_request",
         "--project", str(project), "--data",
         json.dumps({"url": url, "force": True})],
        capture_output=True, timeout=30, encoding="utf-8", errors="replace",
    )
    print(f"\nURL: {url}")
    print(f"  exit: {r.returncode}")
    print(f"  stdout: {r.stdout.strip()}")
    print(f"  stderr: {r.stderr.strip()}")
    payload = None
    for raw in (r.stderr, r.stdout):
        if not raw: continue
        for c in (raw.strip(), raw.split(": ", 1)[-1].strip()):
            try:
                p = json.loads(c)
                if isinstance(p, dict): payload = p; break
            except: continue
        if payload: break
    if payload:
        print(f"  parsed: {json.dumps(payload, indent=2)}")

# Also test a simpler route to ensure editor is responsive
r2 = subprocess.run(
    [str(gdcli_bin()), "--json", "exec", "gdapi/health/ping",
     "--project", str(project)],
    capture_output=True, timeout=10, encoding="utf-8", errors="replace",
)
print(f"\nPing: exit={r2.returncode}, stdout={r2.stdout.strip()}")

godot.terminate()
try: godot.wait(timeout=10)
except: godot.kill()
log_handle.close()

print(f"\nGodot log tail:")
print(log_path.read_text(encoding="utf-8", errors="replace").splitlines()[-40:])
