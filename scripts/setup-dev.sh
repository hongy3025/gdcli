#!/usr/bin/env bash
# 设置开发环境：创建 bin/ 符号链接指向编译产物
#
# 用法：
#   ./scripts/setup-dev.sh          # 设置当前平台
#   ./scripts/setup-dev.sh --all    # 设置所有平台
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADDON_BIN="$REPO_ROOT/gdapi/addon/bin"
TARGET_DEBUG="$REPO_ROOT/target/debug"

# 平台检测
detect_platform() {
    case "$(uname -s)" in
        Linux*)     echo "linux";;
        Darwin*)    echo "macos";;
        CYGWIN*|MINGW*|MSYS*)  echo "windows";;
        *)          echo "unknown";;
    esac
}

# 创建单个平台的符号链接
create_symlink() {
    local platform="$1"
    local target_dir="$ADDON_BIN/$platform"
    local source_dir="$TARGET_DEBUG"

    # 移除现有的 .gitkeep（如果存在）
    if [[ -f "$target_dir/.gitkeep" ]]; then
        rm "$target_dir/.gitkeep"
    fi

    # 创建符号链接
    case "$platform" in
        linux)
            if [[ -f "$source_dir/libgdapi.so" ]]; then
                ln -sf "$source_dir/libgdapi.so" "$target_dir/libgdapi.so"
                echo "  ✓ $platform: libgdapi.so -> $source_dir/libgdapi.so"
            else
                echo "  ⚠ $platform: libgdapi.so not found in $source_dir"
            fi
            ;;
        macos)
            if [[ -f "$source_dir/libgdapi.dylib" ]]; then
                ln -sf "$source_dir/libgdapi.dylib" "$target_dir/libgdapi.dylib"
                echo "  ✓ $platform: libgdapi.dylib -> $source_dir/libgdapi.dylib"
            else
                echo "  ⚠ $platform: libgdapi.dylib not found in $source_dir"
            fi
            ;;
        windows)
            if [[ -f "$source_dir/gdapi.dll" ]]; then
                ln -sf "$source_dir/gdapi.dll" "$target_dir/gdapi.dll"
                echo "  ✓ $platform: gdapi.dll -> $source_dir/gdapi.dll"
            else
                echo "  ⚠ $platform: gdapi.dll not found in $source_dir"
            fi
            ;;
    esac
}

# 主逻辑
main() {
    echo "Setting up gdapi dev environment..."
    echo "  Repo root: $REPO_ROOT"
    echo "  Addon bin: $ADDON_BIN"
    echo "  Target debug: $TARGET_DEBUG"
    echo ""

    # 确保 target/debug 存在
    if [[ ! -d "$TARGET_DEBUG" ]]; then
        echo "Warning: $TARGET_DEBUG does not exist. Run 'cargo build' first."
    fi

    # 创建符号链接
    if [[ "${1:-}" == "--all" ]]; then
        echo "Creating symlinks for all platforms:"
        create_symlink "linux"
        create_symlink "macos"
        create_symlink "windows"
    else
        local platform
        platform=$(detect_platform)
        if [[ "$platform" == "unknown" ]]; then
            echo "Error: Could not detect platform. Use --all to create all symlinks."
            exit 1
        fi
        echo "Creating symlink for platform: $platform"
        create_symlink "$platform"
    fi

    echo ""
    echo "Done! You can now link the addon to your Godot project:"
    echo "  ln -s $(realpath "$REPO_ROOT/gdapi/addon") /path/to/your/project/addons/gdapi"
}

main "$@"
