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
python scripts/setup-dev.py          # 跨平台

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

## gdapi 路由系统

gdapi 的路由系统基于文件系统目录结构自动扫描注册：

```
gdapi/addon/routes/
  ├── console/output.gd          # 读取编辑器 Output 面板
  ├── gdapi/
  │   ├── audit/clear.gd         # 清除审计日志
  │   ├── audit/list.gd          # 列出审计日志
  │   ├── health/pathcheck.gd    # 路径安全校验
  │   └── loglevel.gd            # 查询/设置日志级别
  ├── godot/version.gd           # Godot 引擎版本信息
  ├── project/
  │   ├── info.gd                # 项目基本信息
  │   ├── run.gd                 # 运行项目场景
  │   └── stop.gd                # 停止运行中的场景
  ├── scene/
  │   ├── add_node.gd            # 添加节点到场景
  │   ├── create.gd              # 创建新场景
  │   ├── export_mesh_library.gd # 导出 MeshLibrary
  │   ├── load_sprite.gd         # 加载精灵纹理
  │   └── save.gd                # 保存场景
  └── uid/
      ├── get.gd                 # 查询资源 UID
      └── update_all.gd          # 批量更新 UID
```

### 路由注册机制

- `gdapi/addon/runtime/router.gd` 在初始化时扫描 `routes/` 目录下的所有 `.gd` 文件
- 目录路径映射为路由名（如 `scene/create.gd` → `scene/create`）
- 内置路由（硬编码）：`gdapi/health/ping`、`gdapi/routes`、`command/list`、`command/doc`
- 所有 route handler 继承 `route_handler.gd`，实现 `handle(req, res)` 和 `doc()` 方法
- 文件修改时间（mtime）变化时自动重新加载

### 共享基础设施

| 模块 | 路径 | 职责 |
|---|---|---|
| `router.gd` | `runtime/router.gd` | 扫描、注册、分发请求 |
| `request.gd` | `runtime/request.gd` | 请求参数解析 |
| `response.gd` | `runtime/response.gd` | 响应构建（json/error） |
| `route_handler.gd` | `runtime/route_handler.gd` | 路由处理器基类 |
| `path_guard.gd` | `runtime/path_guard.gd` | 路径安全校验 |
| `variant_codec.gd` | `runtime/variant_codec.gd` | JSON ↔ Godot Variant 转换 |
| `audit_log.gd` | `runtime/audit_log.gd` | 审计日志记录 |
| `error_codes.gd` | `runtime/error_codes.gd` | 统一错误码 |
| `edit_action.gd` | `runtime/edit_action.gd` | UndoRedo 包装 |
| `param_doc.gd` | `runtime/param_doc.gd` | 参数文档描述 |
| `route_doc.gd` | `runtime/route_doc.gd` | 路由文档描述 |
| `builtin_ping.gd` | `runtime/builtin_ping.gd` | 内置 ping 路由 |
| `builtin_routes.gd` | `runtime/builtin_routes.gd` | 内置路由列表 |
| `builtin_commands.gd` | `runtime/builtin_commands.gd` | 内置命令列表 |
| `builtin_command_help.gd` | `runtime/builtin_command_help.gd` | 内置命令帮助 |

### 内置路由

| 路由 | 说明 |
|---|---|
| `gdapi/health/ping` | 健康检查（硬编码，不在 routes/ 目录中） |
| `gdapi/routes` | 列出所有已注册路由名 |
| `command/list` | 列出所有命令的详细信息（含参数） |
| `command/doc` | 查询单个命令的完整帮助文档（位置参数传命令名） |

### CLI 侧特殊处理

- `command/list` 和 `command/doc` 在 CLI 侧使用 clap 风格格式化输出（而非默认 TOON）
- `command/list` 不接受 `--data` 和位置参数
- `command/doc` 不接受 `--data`，要求恰好 1 个位置参数作为命令路径
- 其余路由通过 `--data` 传 JSON body，不接受位置参数

## 开发环境搭建

1. `cargo build --workspace` — 编译所有产物
2. `python scripts/setup-dev.py` — 自动创建符号链接：
   - `target/debug/gdapi.dll` → `gdapi/addon/bin/windows/gdapi.dll`
   - `gdapi/addon/` → `tests/fixture_project/addons/gdapi/`
3. 打开 Godot 编辑器加载 fixture_project 即可测试

**注意**：Windows 上符号链接使用 junction（不需要管理员权限），文件使用复制。

## 测试说明

- `cli/tests/` — 集成测试，使用 mock LSP 和 httpmock，不需要 Godot
- `gdapi/rust/tests/` — 需要 Godot 编辑器运行的端到端测试
- `scripts/` — 开发脚本（Python）
- `tests/e2e/` — pytest E2E 测试（需要 Godot，用 uv 管理 Python venv）
- 测试用 Godot 项目在 `tests/fixture_project/`，addon 需要先符号链接

## 注意事项

- 本机 Godot 路径：`GODOT_BIN=D:\app\devel\Godot\v4.7.1\godot_console.exe`
- 版本号统一在 workspace `Cargo.toml` 的 `workspace.package.version` 管理
- `plugin.cfg` 和 `gdapi.gdextension` 中的版本号需要手动同步
- 行列号参数是 1-based（与编辑器一致），内部转换为 0-based
- `--project` 参数用于解析相对路径和发现 LSP 端口
- LSP 端口发现优先级：`--port` > `.godot/gdapi.json` > 默认 6005
- **所有辅助脚本一律使用 Python（.py）**，不使用 .sh 或 .ps1，确保跨平台兼容
