#!/usr/bin/env bash
# 端到端验证：启动 Godot 编辑器，运行 gdcli exec ping，验证响应。
#
# 要求：
#   - godot 在 PATH 中（或设 GODOT_BIN 环境变量）
#   - 已运行 cargo build -p gdapi 和 cargo build -p gdcli
set -euo pipefail

GODOT_BIN="${GODOT_BIN:-godot}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$REPO_ROOT/tests/fixture_project"
ADDON_DIR="$FIXTURE/addons/gdapi"
GDCLI_BIN="$REPO_ROOT/target/debug/gdcli"

# 1. 安装 addon：使用符号链接
rm -rf "$ADDON_DIR"
mkdir -p "$FIXTURE/addons"
ln -sf "$REPO_ROOT/gdapi/addon" "$ADDON_DIR"

# 设置 bin 符号链接
"$REPO_ROOT/scripts/setup-dev.sh"

# 2. 启动 Godot 编辑器（无头）
echo "Starting Godot editor..."
"$GODOT_BIN" --editor --headless --path "$FIXTURE" &
GODOT_PID=$!
trap 'kill $GODOT_PID 2>/dev/null; wait $GODOT_PID 2>/dev/null' EXIT

# 3. 轮询等待 .godot/gdapi.json 出现
META="$FIXTURE/.godot/gdapi.json"
for i in {1..30}; do
    if [[ -f "$META" ]]; then
        echo "gdapi meta appeared: $META"
        cat "$META"
        break
    fi
    sleep 1
done

if [[ ! -f "$META" ]]; then
    echo "ERROR: gdapi.json never appeared"
    exit 1
fi

# 4. 调 ping
echo "Calling: gdcli exec ping --project $FIXTURE"
OUTPUT=$("$GDCLI_BIN" exec ping --project "$FIXTURE")
echo "Response: $OUTPUT"

# 5. 验证响应
if echo "$OUTPUT" | grep -q '"ok":true'; then
    echo "PASS: e2e ping succeeded"
    RESULT=0
else
    echo "FAIL: unexpected response"
    RESULT=1
fi

exit $RESULT
