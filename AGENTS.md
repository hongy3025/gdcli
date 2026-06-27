# AGENTS.md — gdcli 仓库指南

> 用户文档（命令用法、安装说明）见 [README.md](README.md)。

## 仓库概览

gdcli 是一个与 Godot 编辑器交互的 Rust CLI 工具，通过 LSP 和 HTTP（gdapi addon）两种协议通信。

## 项目结构

```
cli/            → gdcli 二进制（Rust CLI）
gdapi/rust/     → gdapi GDExtension cdylib（编译为 .dll/.so/.dylib）
gdapi/addon/    → Godot 插件（GDScript + .gdextension 配置）
tests/fixture_project/  → 测试用 Godot 项目
scripts/        → 开发脚本
docs/           → 设计文档和规格说明
```

## 常用命令

```bash
# 构建整个 workspace（cli + gdapi）
cargo build --workspace

# 仅构建 gdapi 库
cargo build -p gdapi

# 一键开发环境搭建（构建 + 符号链接 addon 到 fixture_project）
python dev.py          # 跨平台

# 运行所有测试（单元测试 + 集成测试，不需要 Godot）
cargo test --workspace

# 运行单个 crate 的测试
cargo test -p gdcli
cargo test -p gdapi

# Lint 和格式检查（无专用配置，使用默认规则）
cargo clippy --workspace
cargo fmt --check

# E2E 测试（需要 Godot，用 uv 管理 Python venv）
uv run pytest tests/e2e/ -v              # 运行所有 E2E
uv run pytest tests/e2e/ -v -m e2e       # 仅运行 e2e 标记的测试
uv run pytest tests/e2e/ -v -m "not e2e" # 跳过 e2e 测试
```

## 关键架构细节

- `cli/src/main.rs` 是 CLI 入口，使用 clap 解析参数
- `cli/build.rs` 从 workspace Cargo.toml 版本号生成 `version.rs`
- `gdapi/rust/src/lib.rs` 是 GDExtension 入口（cdylib），使用 `godot` crate 0.5 版本
- gdapi addon 通过 HTTP 接收 gdcli 的 `exec` 命令，运行在 Godot 编辑器进程中
- LSP 命令需要 Godot 编辑器运行中（默认端口 6005）

## 开发环境搭建

1. `cargo build --workspace` — 编译所有产物
2. `python dev.py` — 自动创建符号链接：
   - `target/debug/gdapi.dll` → `gdapi/addon/bin/windows/gdapi.dll`
   - `gdapi/addon/` → `tests/fixture_project/addons/gdapi/`
3. 打开 Godot 编辑器加载 fixture_project 即可测试

**注意**：Windows 上符号链接使用 junction（不需要管理员权限），文件使用复制。

## 测试说明

- `cli/tests/` — 集成测试，使用 mock LSP 和 httpmock，不需要 Godot
- `gdapi/rust/tests/` — 需要 Godot 编辑器运行的端到端测试
- `scripts/e2e-ping.py` — 手动端到端验证脚本
- `scripts/e2e-m1-smoke.py` — M1 路由基础设施端到端验证
- `tests/e2e/` — pytest E2E 测试（需要 Godot，用 uv 管理 Python venv）
- 测试用 Godot 项目在 `tests/fixture_project/`，addon 需要先符号链接

## 注意事项

- 版本号统一在 workspace `Cargo.toml` 的 `workspace.package.version` 管理
- `plugin.cfg` 和 `gdapi.gdextension` 中的版本号需要手动同步
- 行列号参数是 1-based（与编辑器一致），内部转换为 0-based
- `--project` 参数用于解析相对路径和发现 LSP 端口
- LSP 端口发现优先级：`--port` > `.godot/gdapi.json` > 默认 6005
- **所有辅助脚本一律使用 Python（.py）**，不使用 .sh 或 .ps1，确保跨平台兼容
