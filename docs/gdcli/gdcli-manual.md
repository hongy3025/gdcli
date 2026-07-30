# gdcli 用户手册

gdcli 是与 Godot 编辑器交互的命令行工具。两种工作模式：

- **LSP 模式** — 通过 Godot 内置 LSP 服务器进行代码智能操作
- **exec 模式** — 通过 gdapi HTTP 插件调用编辑器功能

## 安装

```bash
cargo build --release
# 产物：target/release/gdcli（Windows 下为 gdcli.exe）
```

## 前置条件

- Godot 4.7.x（gdapi 插件仅支持此版本）
- LSP 模式：Godot 编辑器运行中（默认监听 6005 端口）
- exec 模式：项目中已安装并启用 gdapi 插件

LSP 启动示例：

```bash
godot --editor --path /path/to/project
godot --editor --headless --lsp-port 6005 --path /path/to/project
```

## 快速上手

```bash
# 检查 LSP 连接
gdcli status --project .

# 查找符号引用
gdcli lsp references player.gd:health

# 列出所有编辑器命令
gdcli exec command/list --project .
```

## 子命令

| 子命令 | 功能 | 文档 |
|--------|------|------|
| `lsp` | LSP 代码智能操作（重命名、引用、定义等） | [gdcli-lsp.md](gdcli-lsp.md) |
| `status` | 检查 LSP 连接状态 | [gdcli-status.md](gdcli-status.md) |
| `install` | 安装 gdapi 编辑器插件到目标项目 | [gdcli-install.md](gdcli-install.md) |
| `exec` | 调用 Godot 编辑器命令 | [gdcli-exec.md](gdcli-exec.md) |

## 全局选项

| 选项 | 默认 | 说明 |
|------|------|------|
| `--project <path>` | 当前目录 | Godot 项目根目录 |
| `--port <port>` | 6005 | LSP 端口（自动发现时无需指定） |
| `--json` | — | JSON 输出格式（替代人类可读格式） |
