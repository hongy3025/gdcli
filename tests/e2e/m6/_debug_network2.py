from __future__ import annotations

import json
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from e2e.m2.helpers import gdcli_bin, repo_root, resolve_godot_bin, require_godot_47

godot_bin = resolve_godot_bin()
require_godot_47(godot_bin)

import tempfile
tmpdir = Path(tempfile.mkdtemp("gdcli-debug2"))
project = tmpdir / "project"
fixture = repo_root() / "tests" / "fixtures" / "m6_project"
shutil.copytree(fixture, project)

policy = {"version": 1, "capabilities": {"network": {
    "enabled": True, "schemes": ["http"], "hosts": ["127.0.0.1", "localhost"],
    "ports": [80, 443, 18923], "allow_private": True, "max_redirects": 5,
    "max_timeout_ms": 5000, "max_response_bytes": 1048576,
}}}
pdir = project / ".godot"
pdir.mkdir(parents=True, exist_ok=True)
(pdir / "gdapi-policy.json").write_text(json.dumps(policy), encoding="utf-8")

install = subprocess.run(
    [str(gdcli_bin()), "install", "--project", str(project), "--force"],
    capture_output=True, encoding="utf-8", errors="replace",
)
print("Install:", install.returncode)

# Patch the target guard AFTER install to add debug logging
guard_file = project / "addons" / "gdapi" / "runtime" / "services" / "network_target_guard.gd"
original = guard_file.read_text(encoding="utf-8")

# Add a debug version of authorize that prints intermediate values
debug_version = original.replace(
    'static func authorize(',
    'static func debug_authorize(',
)

# Insert debug prints before key lines
debug_version = debug_version.replace(
    '\tif not allowed or not policy.get("ports", []).has(port):',
    '\tprint("DEBUG_TG: scheme=", scheme, " host=", host, " port=", port, " allowed=", allowed)\n'
    '\tprint("DEBUG_TG: hosts=", policy.get("hosts", []), " ports=", policy.get("ports", []))\n'
    '\tvar _hosts_check: bool = policy.get("hosts", []).has(host)\n'
    '\tvar _ports_check: bool = policy.get("ports", []).has(port)\n'
    '\tprint("DEBUG_TG: host_in_list=", _hosts_check, " port_in_list=", _ports_check)\n'
    '\tif not allowed or not policy.get("ports", []).has(port):',
)

# Add print at the end too
debug_version = debug_version.replace(
    '\treturn {\n\t\t"ok": true, "url": url, "scheme": scheme, "host": host, "port": port, "addresses": addresses\n\t}',
    '\tprint("DEBUG_TG: SUCCESS host=", host, " port=", port)\n'
    '\treturn {\n\t\t"ok": true, "url": url, "scheme": scheme, "host": host, "port": port, "addresses": addresses\n\t}',
)

guard_file.write_text(debug_version, encoding="utf-8")

# Also patch the route handler to add debug logging
route_file = project / "addons" / "gdapi" / "routes" / "network" / "http_request.gd"
route_original = route_file.read_text(encoding="utf-8")
route_debug = route_original.replace(
    'var checked := Service.validate(req.body, policy.settings("network"))',
    'print("DEBUG: policy.settings=", policy.settings("network"))\n'
    '\tvar checked := Service.validate(req.body, policy.settings("network"))',
)
route_file.write_text(route_debug, encoding="utf-8")

log_path = pdir / "godot.log"
log_handle = log_path.open("w", encoding="utf-8")
godot = subprocess.Popen(
    [godot_bin, "--editor", "--headless", "--path", str(project)],
    stdout=log_handle, stderr=subprocess.STDOUT,
)

time.sleep(25)

# Test URL
r = subprocess.run(
    [str(gdcli_bin()), "--json", "exec", "network/http_request",
     "--project", str(project), "--data",
     json.dumps({"url": "http://127.0.0.1:18923/ok", "force": True})],
    capture_output=True, timeout=10, encoding="utf-8", errors="replace",
)
print(f"\nexit: {r.returncode}")
print(f"stderr: {r.stderr.strip()}")

godot.terminate()
try: godot.wait(timeout=10)
except: godot.kill()
log_handle.close()

# Read full log and grep for DEBUG lines
log_content = log_path.read_text(encoding="utf-8", errors="replace")
print("\nGodot log (DEBUG_TG and DEBUG lines):")
for line in log_content.splitlines():
    if "DEBUG" in line:
        print(line)
