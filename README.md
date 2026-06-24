# gdcli

与 Godot 编辑器交互的命令行工具。支持两种模式：

- **LSP 模式**：通过 Godot 内置 LSP 服务器进行重命名、查找引用、跳转定义等代码智能操作
- **exec 模式**：通过 gdapi addon 的 HTTP 接口调用编辑器功能

## 安装

源码构建（需要 Rust 工具链）：

```bash
cargo build --release
# 产物：target/release/gdcli（Windows 下为 gdcli.exe）
```

## 前置条件

LSP 命令需要 Godot 编辑器运行中（默认监听 6005 端口）：

```bash
# 有界面模式
godot --editor --path /path/to/project

# 无头模式
godot --editor --headless --lsp-port 6005 --path /path/to/project
```

exec 命令需要在项目中安装并启用 gdapi 插件（见下方 `gdcli install`）。

## 命令总览

```
gdcli lsp <subcommand>    # LSP 代码智能操作
gdcli status              # 检查 LSP 连接状态
gdcli install             # 安装 gdapi addon 到目标项目
gdcli exec <command>      # 通过 HTTP 调用 gdapi 路由
```

---

## gdcli install

将 gdapi addon 安装到目标 Godot 项目，自动修改 `project.godot` 启用插件。

```bash
gdcli install --project /path/to/project
```

| Flag | 说明 |
|---|---|
| `--force` | 覆盖已有安装 |
| `--no-enable` | 不修改 `project.godot` 启用插件 |

安装完成后在 Godot 编辑器中打开项目即可。

---

## gdcli status

验证与 LSP 服务器的连接状态。

```bash
gdcli status --project /path/to/project
```

---

## gdcli lsp

所有 LSP 相关操作通过 `gdcli lsp <subcommand>` 访问。

支持两种定位方式：**行列号** 和 **符号路径**。

### 行列号模式

行列号从 1 开始（与编辑器显示一致）。

```bash
gdcli lsp rename <file> <line> <col> <new_name>
gdcli lsp references <file> <line> <col>
gdcli lsp definition <file> <line> <col>
gdcli lsp declaration <file> <line> <col>
gdcli lsp hover <file> <line> <col>
gdcli lsp symbols <file>
gdcli lsp diagnostics [file]
gdcli lsp capabilities
```

### 符号路径模式

使用 `文件:符号` 格式定位符号，无需手动查找行列号。

```bash
gdcli lsp rename <target> <new_name>
gdcli lsp references <target>
gdcli lsp definition <target>
gdcli lsp declaration <target>
gdcli lsp hover <target>
```

**符号路径格式**：`文件路径:符号路径`

```bash
# 简写形式（推荐）
gdcli lsp definition player.gd:counter

# 完整形式（仅当文件名不含 '.' 时可用）
gdcli lsp definition player.gd:Player.health

# 多级形式
gdcli lsp definition player.gd:Player.Inventory.Item.name

# res:// 路径
gdcli lsp definition res://player.gd:Player.health
```

**错误处理**：当符号找不到时，gdcli 会提供建议：

```
$ gdcli lsp definition player.gd:count
Symbol 'count' not found. Did you mean: counter?
```

**限制**：
- 文件名包含 `.`（如 `2d_in_3d.gd`）时，只能使用简写形式
- 不支持全局符号搜索（需要文件路径）

### native-symbol

查询 Godot 内置类（如 Node、Vector2、Node3D）的文档。支持渐进式披露：

```bash
# 默认：显示类名、签名、描述全文
gdcli lsp native-symbol Node3D

# --members：按 Constants / Properties / Signals / Methods 分组列表
gdcli lsp native-symbol --members Node3D

# --full：所有成员完整展开（detail + 全部 documentation）
gdcli lsp native-symbol --full Node3D

# 查询单个成员
gdcli lsp native-symbol Node3D get_parent
```

`--members` 和 `--full` 互斥。`--json` 模式下输出完整 JSON，不受 flag 影响。

---

## gdcli exec

通过 HTTP 调用 gdapi addon 的路由，需要 Godot 编辑器运行中且 gdapi 插件已启用。

```bash
gdcli exec ping --project /path/to/project
# 输出：{"editor_version":"4.3.x","gdapi_version":"0.2.0","ok":true}
```

| Flag | 默认 | 说明 |
|---|---|---|
| `--data <json>` | `{}` | 请求 JSON 数据：字面 JSON、`@file` 或 `-`（stdin） |
| `--timeout <secs>` | `30` | HTTP 请求超时秒数 |

`help` 命令使用位置参数而非 `--data`：

```bash
gdcli exec help                    # 列出所有路由
gdcli exec help editor/scene/save  # 查看路由详情
```

---

## 全局选项

| Flag | 默认 | 说明 |
|---|---|---|
| `--host <host>` | `127.0.0.1` | LSP 主机 |
| `--port <port>` | 自动发现 | LSP 端口（优先 `--port` > `.godot/gdapi.json` > `6005`） |
| `--project <path>` | — | 项目根目录，用于解析相对路径和发现端口 |
| `--json` | — | 输出 JSON 格式 |

## License

MIT
