"""Inject debug prints into network_service.gd to see what policy dict looks like."""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from e2e.m2.helpers import gdcli_bin, repo_root, resolve_godot_bin, require_godot_47


godot_bin = resolve_godot_bin()
require_godot_47(godot_bin)
tmpdir = Path(tempfile.mkdtemp("gdcli-qtest2"))
project = tmpdir / "project"
shutil.copytree(repo_root() / "tests" / "fixtures" / "m6_project", project)

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
subprocess.run([str(gdcli_bin()), "install", "--project", str(project), "--force"],
               check=True, capture_output=True, encoding="utf-8")

# Patch network_service.gd to add debug prints AFTER install
svc_file = project / "addons" / "gdapi" / "runtime" / "services" / "network_service.gd"
src = svc_file.read_text(encoding="utf-8")

# Insert debug print right before TargetGuard.authorize call
old = '''\tvar target := TargetGuard.authorize(url, policy, resolver)'''
new = '''\tprint("DEBUG: policy_keys=", policy.keys(), " has_hosts=", policy.has("hosts"), " has_ports=", policy.has("ports"))
\tprint("DEBUG: schemes=", policy.get("schemes", "MISSING"), " hosts=", policy.get("hosts", "MISSING"), " ports=", policy.get("ports", "MISSING"))
\tfor k in policy:
\t\tprint("DEBUG_POLICY: ", k, " -> ", policy[k], " (type=", typeof(policy[k]), ")")
\tvar target := TargetGuard.authorize(url, policy, resolver)'''
src = src.replace(old, new)
svc_file.write_text(src, encoding="utf-8")
print("Patched", svc_file)

log = (pdir / "godot.log").open("w")
godot = subprocess.Popen(
    [godot_bin, "--editor", "--headless", "--path", str(project)],
    stdout=log, stderr=subprocess.STDOUT,
)
time.sleep(25)

r = subprocess.run(
    [str(gdcli_bin()), "--json", "exec", "network/http_request",
     "--project", str(project), "--data",
     json.dumps({"url": "http://127.0.0.1:18923/ok", "force": True})],
    capture_output=True, timeout=15, encoding="utf-8", errors="replace",
)
payload = None
for raw in (r.stderr, r.stdout):
    if raw:
        for c in (raw.strip(), raw.split(": ", 1)[-1].strip()):
            try: payload = json.loads(c); break
            except: pass
    if payload: break
print(f"\nexit={r.returncode}, {json.dumps(payload, ensure_ascii=False)}")

godot.terminate()
try: godot.wait(timeout=10)
except: godot.kill(); godot.wait()
log.close()

# Extract DEBUG lines from Godot log file
log_path = pdir / "godot.log"
log_content = log_path.read_text(encoding="utf-8", errors="replace")
print("\n=== DEBUG lines from Godot log ===")
for line in log_content.splitlines():
    if "DEBUG" in line:
        print(line)
if not any("DEBUG" in l for l in log_content.splitlines()):
    print("(no DEBUG lines found - showing last 20 lines of log)")
    for line in log_content.splitlines()[-20:]:
        print(line)
