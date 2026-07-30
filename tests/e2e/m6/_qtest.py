"""Quick test: test direct /ok and /redirect-ok with Godot editor."""

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


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/redirect-ok":
            self.send_response(302)
            self.send_header("Location", "/ok")
            self.end_headers()
        elif self.path == "/redirect-loop":
            self.send_response(302)
            self.send_header("Location", "/redirect-loop")
            self.end_headers()
        else:
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"ok-" + self.path.encode())
    def log_message(self, *a): pass


s = HTTPServer(("127.0.0.1", 18923), H)
t = threading.Thread(target=s.serve_forever, daemon=True)
t.start()
time.sleep(1)

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

godot_bin = resolve_godot_bin()
require_godot_47(godot_bin)
tmpdir = Path(tempfile.mkdtemp("gdcli-qtest"))
project = tmpdir / "project"
shutil.copytree(repo_root() / "tests" / "fixtures" / "m6_project", project)

pdir = project / ".godot"
pdir.mkdir(parents=True, exist_ok=True)
(pdir / "gdapi-policy.json").write_text(json.dumps(policy), encoding="utf-8")
subprocess.run([str(gdcli_bin()), "install", "--project", str(project), "--force"],
               check=True, capture_output=True, encoding="utf-8")

log = (pdir / "godot.log").open("w")
godot = subprocess.Popen(
    [godot_bin, "--editor", "--headless", "--path", str(project)],
    stdout=log, stderr=subprocess.STDOUT,
)
time.sleep(25)

urls = [
    f"http://127.0.0.1:18923/ok",
    f"http://localhost:18923/ok",
    f"http://127.0.0.1:18923/redirect-ok",
    f"http://127.0.0.1/ok",  # port 80 - should be allowed
    f"http://127.0.0.1:80/ok",  # explicit port 80
]
for url in urls:
    r = subprocess.run(
        [str(gdcli_bin()), "--json", "exec", "network/http_request",
         "--project", str(project), "--data",
         json.dumps({"url": url, "force": True})],
        capture_output=True, timeout=35, encoding="utf-8", errors="replace",
    )
    payload = None
    for raw in (r.stderr, r.stdout):
        if raw:
            for c in (raw.strip(), raw.split(": ", 1)[-1].strip()):
                try:
                    payload = json.loads(c)
                    break
                except Exception:
                    pass
        if payload:
            break
    print(f"URL {url}: exit={r.returncode}, {json.dumps(payload, ensure_ascii=False)}")

godot.terminate()
try:
    godot.wait(timeout=10)
except Exception:
    godot.kill()
    godot.wait()
log.close()
s.shutdown()
