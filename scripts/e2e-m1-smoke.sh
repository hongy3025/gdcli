#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${GODOT_BIN:-}" ]]; then
  echo "GODOT_BIN is required for M1 E2E smoke" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$REPO_ROOT/tests/fixture_project"
GDCLI_BIN="$REPO_ROOT/target/debug/gdcli"
META="$FIXTURE/.godot/gdapi.json"

json_get() {
  python -c 'import json,sys; data=json.load(sys.stdin); cur=data
for part in sys.argv[1].split("."):
    cur=cur[part]
print(cur)'
}

assert_route() {
  local routes_json="$1"
  local name="$2"
  python -c 'import json,sys; data=json.loads(sys.argv[1]); name=sys.argv[2]
assert name in data["routes"], f"missing route: {name}"' "$routes_json" "$name"
}

cargo build --workspace
"$GDCLI_BIN" install --project "$FIXTURE" --force
"$REPO_ROOT/scripts/setup-dev.sh"
rm -f "$META"

"$GODOT_BIN" --editor --headless --path "$FIXTURE" &
GODOT_PID=$!
trap 'kill "$GODOT_PID" 2>/dev/null || true; wait "$GODOT_PID" 2>/dev/null || true' EXIT

for _ in $(seq 1 45); do
  if [[ -f "$META" ]]; then
    break
  fi
  sleep 1
done
if [[ ! -f "$META" ]]; then
  echo "gdapi.json never appeared" >&2
  exit 1
fi

PING=$("$GDCLI_BIN" --json exec ping --project "$FIXTURE")
[[ "$(printf '%s' "$PING" | json_get ok)" == "True" || "$(printf '%s' "$PING" | json_get ok)" == "true" ]]

ROUTES=$("$GDCLI_BIN" --json exec routes --project "$FIXTURE")
assert_route "$ROUTES" "editor/scene/create"
assert_route "$ROUTES" "scene/create"
assert_route "$ROUTES" "shared/godot/version"
assert_route "$ROUTES" "godot/version"
python -c 'import json,sys; data=json.loads(sys.argv[1]); assert data["aliases"]["scene/create"] == "editor/scene/create"' "$ROUTES"

COMMANDS=$("$GDCLI_BIN" --json exec commands --project "$FIXTURE")
python -c 'import json,sys; data=json.loads(sys.argv[1]); matches=[c for c in data["commands"] if c["path"]=="editor/scene/create"]; assert matches and matches[0]["canonical_path"]=="editor/scene/create"' "$COMMANDS"

HELP=$("$GDCLI_BIN" --json exec command-help scene/create --project "$FIXTURE")
python -c 'import json,sys; data=json.loads(sys.argv[1]); assert data["doc"]["canonical_path"]=="editor/scene/create"' "$HELP"

SAFE=$("$GDCLI_BIN" --json exec project/health/path_check --project "$FIXTURE" --data '{"path":"scenes/test.tscn","mode":"read"}')
python -c 'import json,sys; data=json.loads(sys.argv[1]); assert data["path"]=="res://scenes/test.tscn"' "$SAFE"

if "$GDCLI_BIN" --json exec project/health/path_check --project "$FIXTURE" --data '{"path":"../outside.txt","mode":"read"}'; then
  echo "path traversal was accepted" >&2
  exit 1
fi

if "$GDCLI_BIN" --json exec project/audit/clear --project "$FIXTURE" --data '{}'; then
  echo "audit clear without force was accepted" >&2
  exit 1
fi

"$GDCLI_BIN" --json exec project/audit/clear --project "$FIXTURE" --data '{"force":true}' >/dev/null
echo "PASS: M1 E2E smoke"
