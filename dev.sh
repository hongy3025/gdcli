#!/usr/bin/env bash
# 一键构建 + 符号链接安装 addon 到 tests/fixture_project/
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
FIXTURE="$REPO_ROOT/tests/fixture_project"
ADDON_DIR="$FIXTURE/addons/gdapi"

# 1. 构建
echo "Building workspace..."
cargo build --workspace

# 2. 设置 bin 符号链接
"$REPO_ROOT/scripts/setup-dev.sh"

# 3. 符号链接 addon
rm -rf "$ADDON_DIR"
mkdir -p "$FIXTURE/addons"
ln -sf "$REPO_ROOT/gdapi/addon" "$ADDON_DIR"

echo ""
echo "Done! addon linked: $ADDON_DIR -> $REPO_ROOT/gdapi/addon"
