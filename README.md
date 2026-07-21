# gdcli

与 Godot 编辑器交互的命令行工具。支持两种模式：

- **LSP 模式**：通过 Godot 内置 LSP 服务器进行重命名、查找引用、跳转定义等代码智能操作
- **exec 模式**：调用 Godot 编辑器功能

## 安装

源码构建（需要 Rust 工具链）：

```bash
cargo build --release
# 产物：target/release/gdcli（Windows 下为 gdcli.exe）
```

## 前置条件

gdcli 的 gdapi 插件仅支持 Godot 4.7.x。构建使用 godot-rust 0.5.4 的 `api-4-7` API level；Godot 4.3–4.6 不在兼容或测试范围内。

LSP 命令需要 Godot 编辑器运行中（默认监听 6005 端口）：

```bash
# 有界面模式
godot --editor --path /path/to/project

# 无头模式
godot --editor --headless --lsp-port 6005 --path /path/to/project
```

exec 命令需要在项目中安装并启用编辑器插件（见下方 `gdcli install`）。

## 命令总览

```
gdcli lsp <subcommand>    # LSP 代码智能操作
gdcli status              # 检查 LSP 连接状态
gdcli install             # 安装编辑器插件到目标项目
gdcli exec <command>      # 调用 Godot 编辑器命令
```

---

## gdcli install

将编辑器插件安装到目标 Godot 项目，自动修改 `project.godot` 启用插件。

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

## 开发验证

M1 gdapi 路由基础设施端到端验证（需要 Godot 编辑器，用 uv 管理 Python venv）：

```bash
uv run pytest tests/e2e/test_m1_smoke.py -v
```

可选设置 `GODOT_BIN` 环境变量指定 Godot 路径（默认使用 PATH 中的 `godot`）。

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

调用 Godot 编辑器命令，需要 Godot 编辑器运行中且 gdapi 插件已启用。

```bash
gdcli exec gdapi/health/ping --project /path/to/project
# 输出：{"editor_version":"4.3.x","gdapi_version":"0.2.0","ok":true}
```

| Flag | 默认 | 说明 |
|---|---|---|
| `--data <json>` | `{}` | 请求 JSON 数据：字面 JSON、`@file` 或 `-`（stdin） |
| `--timeout <secs>` | `30` | 请求超时秒数 |

`command/list` 和 `command/doc` 使用位置参数而非 `--data`：

```bash
gdcli exec command/list                     # 列出所有命令
gdcli exec command/doc scene/save           # 查看命令详情
```

### 输出格式

`gdcli exec` 默认以 **TOON** 格式输出响应，便于人类终端阅读和 LLM 消费：

- 对象 → 缩进键值对
- 字段统一的对象数组 → 紧凑表格（pipe 分隔）
- 其它结构 → 树状列表

`command/list` 和 `command/doc` 使用 clap 风格输出，便于阅读：

```bash
# 列出所有命令（clap 风格）
$ gdcli exec command/list
Commands:
  gdapi/health/ping     健康检查
  scene/save            保存场景
  godot/version         获取 Godot 版本

# 查看命令详情（clap 风格）
$ gdcli exec command/doc uid/update_all
批量更新项目中所有资源的 UID

Usage: gdcli exec uid/update_all --data {DATA}

DATA:
{
  "project_path": "PROJECT_PATH" // (optional String)  要扫描的项目子目录路径，默认为 res://
}

Description:
  扫描指定目录下的场景文件和脚本文件，重新保存以生成或更新 UID；用于解决 UID 缺失或损坏导致的资源引用问题

Returns:
  处理结果统计

Return Fields:
  ok                   bool
  scenes_processed     int, 处理的场景文件数
  scenes_saved         int, 成功保存的场景数
  scenes_errors        int, 保存失败的场景数
  scripts_missing_uids int, 缺少 UID 的脚本数
  uids_generated       int, 新生成的 UID 数
```

加 `--json` 切回原始的 minified JSON（脚本场景推荐）：

```bash
# 默认 TOON 输出
gdcli exec gdapi/health/ping
# ok: true
# gdapi_version: 0.2.0

# JSON 输出（脚本友好）
gdcli --json exec gdapi/health/ping
# {"ok":true,"gdapi_version":"0.2.0"}
```

---

## exec 路由家族（M2 基础编辑）

gdcli exec 通过 gdapi 插件提供以下路由家族，覆盖 Godot 编辑器的基本编辑工作流。

### 场景 (scene)

| 路由 | 说明 |
|---|---|
| `scene/current` | 获取当前编辑场景信息 |
| `scene/current/save` | 保存当前编辑场景（可选另存为 `{path, force?}`） |
| `scene/open` | 在编辑器中打开场景 `{path}` |
| `scene/close` | 关闭场景 `{path?}` |
| `scene/tree` | 查询场景树结构 `{path?, max_depth?}` |
| `scene/list_open` | 列出所有已打开场景 |

### 节点 (node)

| 路由 | 说明 |
|---|---|
| `node/create` | 创建节点 `{parent_path, type, name}` |
| `node/delete` | 删除节点（不能删除场景根节点） |
| `node/duplicate` | 复制节点 |
| `node/rename` | 重命名节点 `{node_path, name}` |
| `node/reparent` | 改变节点父级 `{node_path, parent_path}` |
| `node/move` | 调整节点在兄弟中的顺序 |
| `node/get` | 获取节点信息 `{node_path}` |
| `node/set` | 批量设置节点属性 `{node_path, properties}` |
| `node/list` | 列出当前场景所有节点 |
| `node/select` | 选择单个节点 |

### 属性 (node/property)

| 路由 | 说明 |
|---|---|
| `node/property/get` | 获取属性值 `{node_path, property}` |
| `node/property/set` | 设置属性值 `{node_path, property, value}` |
| `node/property/list` | 列出节点所有属性 |
| `node/property/reset` | 重置属性为默认值 |
| `node/property/revert` | 还原属性为场景文件中的值 |

属性值使用 typed Variant JSON 格式，例如：

```json
{"type": "Vector2", "value": [100.0, 200.0]}
{"type": "Color", "value": [1.0, 0.0, 0.0, 1.0]}
{"type": "NodePath", "value": "/root/Main/Player"}
{"type": "Resource", "value": "res://resources/player_data.tres"}
```

### 信号 (node/signal)

| 路由 | 说明 |
|---|---|
| `node/signal/list` | 列出节点信号及连接 `{node_path}` |
| `node/signal/connect` | 连接信号 `{source_path, signal, target_path, method, flags?}` |
| `node/signal/disconnect` | 断开信号连接 |
| `node/signal/emit` | 手动发射信号 |

### 分组 (node/group)

| 路由 | 说明 |
|---|---|
| `node/group/list` | 列出节点所属分组 `{node_path}` |
| `node/group/add` | 添加节点到分组 `{node_path, group, persistent?}` |
| `node/group/remove` | 从分组移除节点 |
| `node/group/nodes` | 查询分组内所有节点 `{group}` |

### 脚本 (script)

| 路由 | 说明 |
|---|---|
| `script/read` | 读取脚本文件内容 `{path}` |
| `script/create` | 创建新脚本文件 `{path, content}` |
| `script/write` | 覆盖写入脚本文件（需 `force:true`） |
| `script/patch` | 行范围替换 `{path, start_line, end_line, text, force?}` |
| `script/attach` | 挂载脚本到节点 `{node_path, path}`（UndoRedo 支持） |
| `script/detach` | 从节点卸载脚本（UndoRedo 支持） |
| `script/current` | 获取当前编辑的脚本 |
| `script/open` | 在编辑器中打开脚本并定位到指定行列 `{path, line?, column?}` |
| `script/validate` | 验证脚本语法 `{path}` |

### 文件系统 (filesystem)

| 路由 | 说明 |
|---|---|
| `filesystem/list` | 列出目录内容 `{path, offset?, limit?}` |
| `filesystem/read` | 读取文件内容 `{path}` |
| `filesystem/write` | 写入文件（需 `force:true`）`{path, content, force?}` |
| `filesystem/search` | 按文件名搜索 `{pattern, root?, offset?, limit?}` |
| `filesystem/grep` | 按内容搜索 `{root, pattern, glob?, case_sensitive?, offset?, limit?}` |
| `filesystem/reimport` | 重新导入资源 `{paths}` |

### 资源 (resource)

| 路由 | 说明 |
|---|---|
| `resource/info` | 资源元信息 `{path}` |
| `resource/deps` | 资源依赖列表 `{path}` |
| `resource/search` | 搜索资源 `{filter?, type?, offset?, limit?}` |
| `resource/create` | 创建资源文件 `{path, type, properties, force?}` |
| `resource/assign` | 分配资源到节点属性（UndoRedo 支持）`{node_path, property, path}` |
| `resource/delete` | 删除资源文件（需 `force:true`） |
| `resource/move` | 移动/重命名资源 `{from, to, force?}` |
| `resource/reimport` | 重新导入单个资源 |

### 编辑器 UI (editor)

| 路由 | 说明 |
|---|---|
| `editor/selection/get` | 获取当前选中节点 |
| `editor/selection/set` | 设置选中节点 `{node_paths, clear?}` |
| `editor/main_screen/set` | 切换主编辑器 Tab `{screen: "2D"|"3D"|"Script"|"AssetLib"}` |

### Mutation 模型

| 类型 | UndoRedo | 覆盖保护 |
|---|---|---|
| 编辑器状态（节点/属性/信号/分组） | ✅ `undoable:true` | 不适用 |
| 文件/资源操作 | ❌ `undoable:false` | 需 `force:true` |

所有 mutation 响应包含 `ok`、`changed`、`undoable` 字段。危险操作记录审计日志。

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
