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

当前开发验证基线为 **Godot 4.7.2**，本机 Windows 二进制为 `D:\app\devel\Godot\v4.7.2\godot_console.exe`。维护版本升级不改变 `api-4-7` 或 `.gdextension` 的 `compatibility_minimum = 4.7`，也不将最低要求提高到 4.7.2。

**平台范围**：仅桌面编辑器与桌面导出目标（Windows / macOS / Linux）。Android 平台能力（设备查询、打包、部署、ADB 集成）自 2026-10-03 起不属于本分支范围，相关路由与实现已从代码树移除；见[分支总目标与范围](docs/superpowers/specs/2026-10-03-gdcli-branch-goal-and-scope.md)与[目标收口计划](docs/superpowers/plans/2026-10-03-gdcli-goal-closure.md)。

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

## Sample Godot Project

`godot/sample_project/` is a minimal Godot 4.7.x project; Godot 4.7.2 is the development baseline. From the repository root, run:

```bash
python scripts/install-sample-plugin.py
```

The script builds the gdapi extension, installs it into `godot/sample_project/addons/gdapi/`, and enables the plugin. Re-running it replaces the existing sample-project installation. Open `godot/sample_project/` with Godot 4.7.2 to use the project.

## 开发验证

M1/M2/M3 gdapi 路由基础设施端到端验证（需要 Godot 编辑器，用 uv 管理 Python venv）：

```bash
# M1 烟测
uv run pytest tests/e2e/test_m1_smoke.py -v
# M2 基础编辑验收
uv run pytest tests/e2e/m2 -v
# M3 runtime 验证闭环
uv run pytest tests/e2e/m3 -v
```

完整回归按统一顺序执行 formatter、GDScript lint、clippy、workspace 单元测试、单一持久编辑器内的完整 E2E（file transport、EngineDebugger 和真实 OpenGL 渲染器）以及父进程 wall-clock 预算：

```bash
uv run python scripts/check.py
```

可重复传入 `--gate format|clippy|unit|e2e|budget` 选择门禁。`e2e` 在一个 GUI `gl_compatibility` 编辑器中运行全部用例，包含 GridMap、MultiMesh 和 EngineDebugger 数据面，不再分别启动 file/engine/render 会话；CI 使用 Mesa llvmpipe。直接运行 `uv run pytest tests/e2e/` 也默认包含这些用例。`GDAPI_E2E_BUDGET_SECONDS` 配置完整 wall-clock 阈值（默认 360 秒）；等待统计只报告 P50/P95/P99/max 和 P99×3 建议，不会静默提高门限。

同一次 `scripts/check.py` 调用选择 `e2e` 和 `budget` 时，只执行一次完整套件：budget 使用该次 pytest 子进程从启动到退出的父进程 monotonic wall-clock。单独 `--gate budget` 也只调度一次完整 E2E，不嵌套 pytest、不复用旧产物。`.pytest-artifacts/e2e-waits.json` 记录每个参数化 case 的 setup/call/teardown、状态、等待样本和单编辑器证据；`e2e.xml` 提供 JUnit 报告。E2E 保留生产默认 30 秒 handler 期限。格式/lint 排除生成目录，junction 别名按物理目录去重，并按 Windows 命令行长度限制合并批次。

项目复制、构建、安装和编辑器启动均只发生一次。各用例持续操作同一项目、场景标签页、UndoRedo 历史和审计记录；不再有通用的场景关闭/重开、全项目快照、文件回滚或运行时重置。用例使用自己拥有的资源和名称，并按实时状态做前后比较；只有显式测试撤销、持久化、取消、run/stop 等行为时才执行相应生命周期操作。普通 runtime 用例复用正在运行的 `RuntimeMain`，其中包含 Physics/Navigation domain；意外断连直接报诊断错误，不以自动重启掩盖。

24 个原生 GDScript 套件通过测试插件的 `run_suite` 文件桥，在这个编辑器的真实 SceneTree 中执行，不再启动 `--headless --script` 进程。Godot 原生游戏运行和真实导出仍按产品行为使用子进程：共享的是持续提供 CLI 服务的编辑器，而不是将这些被测行为伪装成同一 OS 进程。

测试专用 `gdapi_test` 插件将编辑器聚焦/失焦时的帧间休眠统一设为 2ms，并在退出时恢复原值；保留正数休眠，不忙循环、不加速游戏时间。生产 addon 的帧调度与请求期限不变。大响应的 JSON 转义使用原生扫描与分段合并，避免逐字符字符串拼接卡住编辑器主线程。

Undo/Redo 与原生套件共用带 `request_id` 的文件桥。命令完整写入请求专属临时文件，关闭后原子替换正式命令；已完成请求重投只重发结果，执行中的套件不会重复启动。结果遭遇 Windows 读句柄共享冲突时，插件保留已写好的临时结果并逐帧继续发布，不重写内容或重做操作。Undo/Redo 保留 10 秒等待与最多 3 次尝试；原生套件使用独立的 45 秒等待，失败结果保留真实计数与诊断。

通过 `GODOT_BIN` 环境变量可覆盖 Godot 路径；共享 E2E fixture 在 Windows 上默认使用 `D:\app\devel\Godot\v4.7.2\godot_console.exe`，其他平台默认使用 PATH 中的 `godot`。直接调用 `build_environment(godot_bin=...)` 时，显式参数优先于环境变量。

共享 fixture 初始使用 file transport；EngineDebugger 用例在同一编辑器内通过真实项目设置和游戏 stop/run 切换数据面，并验证不发生 file 回退。可单独运行该场景：

```bash
uv run pytest tests/e2e/m3/test_engine_transport.py -q -s
```

Windows PowerShell 示例：

```powershell
$env:GODOT_BIN = 'D:\app\devel\Godot\v4.7.2\godot_console.exe'
& $env:GODOT_BIN --version
uv run pytest tests/e2e/test_m1_smoke.py -v
```

### Godot 4.7.1 → 4.7.2

[官方公告](https://godotengine.org/article/maintenance-release-godot-4-7-2/)列出 57 项修复，暂无相对 4.7.1 的已知不兼容。与本工具相关的重点包括 GDExtension 父类暴露检查、主线程生命周期、autoload 状态判断、Windows 初始化/网络盘访问和 TLS 熵源修复。`rand_weighted` 负权重和 `Color.hash()` 有边界行为修正，但本仓库不依赖被修正的旧行为。

完整分类清单、代码影响核对和实测证据见 [4.7.2 升级核对报告](docs/reports/2026-10-03-godot-4.7.2-upgrade.md)。目前未发现必须修改 Godot API 调用、LSP 协议或 Rust 依赖的适配项；已验证真实 4.7.2 编辑器、HTTP/HTTPS、LSP、原生进程和重复运行/停止链路。

使用导出功能前还需安装匹配的 **4.7.2 导出模板**；本机新安装目录的 `export_templates` 为空。file E2E 已验证桌面 PCK 导出；可执行文件/移动端导出仍需要模板，尚未在本机验收。历史报告中的 4.7.1 保留为当时的验证记录。

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

加 `--json` 切回原始的 minified JSON（脚本场景推荐）。`--json` 只把 `ok` 前置，保留响应原始结构（空数组仍是 `[]`，不会被 TOON 的有损压缩改写成 `""`）：

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
| `scene/current/save` | 保存当前编辑场景（可选另存为 `{path?}`） |
| `scene/open` | 在编辑器中打开场景，并等到编辑器实际切换完成 `{path}` |
| `scene/close` | 关闭当前场景（`path` 可省略或仅能指向当前场景） |
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
| `script/write` | 覆盖写入脚本文件 `{path, content}` |
| `script/patch` | 行范围替换 `{path, start_line, end_line, text}` |
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
| `filesystem/write` | 写入文件 `{path, content}` |
| `filesystem/search` | 按文件名搜索 `{pattern, root?, offset?, limit?}` |
| `filesystem/grep` | 按内容搜索 `{root, pattern, glob?, case_sensitive?, offset?, limit?}` |
| `filesystem/reimport` | 重新导入资源 `{paths}` |

### 资源 (resource)

| 路由 | 说明 |
|---|---|
| `resource/info` | 资源元信息 `{path}` |
| `resource/deps` | 资源依赖列表 `{path}` |
| `resource/search` | 搜索资源 `{filter?, type?, offset?, limit?}` |
| `resource/create` | 创建资源文件 `{path, type, properties}` |
| `resource/assign` | 分配资源到节点属性（UndoRedo 支持）`{node_path, property, path}` |
| `resource/delete` | 删除资源文件 |
| `resource/move` | 移动/重命名资源 `{from, to}` |
| `resource/reimport` | 重新导入单个资源 |

### 编辑器 UI (editor)

| 路由 | 说明 |
|---|---|
| `editor/selection/get` | 获取当前选中节点 |
| `editor/selection/set` | 设置选中节点 `{node_paths, clear?}` |
| `editor/main_screen/set` | 切换主编辑器 Tab `{screen: "2D"|"3D"|"Script"|"AssetLib"}` |
| `editor/undo` `editor/redo` | 执行当前场景真实 UndoRedo history |
| `editor/inspector/*` `editor/dock/*` | 检查节点/资源，枚举、切换、聚焦原生 docks |
| `editor/plugins/*` `editor/settings/*` | 管理非 gdapi 插件及受保护的已存在编辑器设置 |
| `editor/camera/*` `editor/screenshot/viewport` | 临时覆盖/恢复 2D/3D editor 相机并截图 |
| `node/meta/*` `node/call` | 读写 meta；调用安全原生方法或节点显式声明的 `gdapi_callable_methods` |
| `scene/instantiate` `scene/delete` | 保留 PackedScene 链接的实例化，以及受引用/打开场景保护的删除 |
| `scene3d/*` `particles/*` | 3D light/environment/sky/camera/gridmap/CSG/MultiMesh 与 2D/3D GPU 粒子 |

`MultiMeshInstance3D` 的非空 `instances` 需要活动渲染器；headless 模式返回 `not_supported`，避免将 RenderingServer dummy values 当作成功读回。

`scene/batch/plan` → `validate` → `apply` → `recover` 对多个未打开场景执行带 `plan_hash`、资源依赖校验及全事务回滚的属性重构；`scene/project/find_nodes`、`references`、`dependencies` 提供项目级引用扫描。

### M4 游戏系统与 T8 资源/动画

M4 涵盖 Animation/AnimationTree、TileMap、Material/Shader、Audio、UI/Theme、2D Physics 与 2D Navigation。增强能力还包括音频 bus 属性和 effects、AnimationTree blend graph 与 Tween、通用资源 typed 属性写入及保存读回、Theme 属性读取和异步 Texture/EditorResourcePreview PNG。编辑器界面操作和资源写入按真实 UndoRedo/文件状态验证。

Physics 与 Navigation 当前只支持 2D。3D 节点、形状、地图或查询在 mutation 前返回 `not_supported`。`physics/raycast`、`navigation/path/get` 和 `navigation/agent/target` 通过运行中的游戏 probe 执行；停止游戏后请求会按 broker 清理语义失败。

完整路由集合及每条参数/返回文档可通过 `gdcli exec command/list` 和 `gdcli exec command/doc <route>` 查询。

### M5 项目、诊断与发布

M5 提供项目设置、InputMap、Autoload、ClassDB、UID 修复、只读项目诊断和受控导出路由。配置用例在持久项目中观察真实内存与磁盘状态，仅管理自己改变的设置、动作和资源；持久化 mutation 返回 `undoable:false`，删除/修复/覆盖为不可撤销写入。

除 health、unused-resource、dependency-cycle 与 script-error diagnostics，`diagnostics/signal_flow`、`scene_complexity`、`script_references`、`project_statistics` 返回带位置/类型信息的静态扫描结果。无法从静态源文件证明运行期连接行为时显式标记为 `unknown`。

`export/presets` 从 `export_presets.cfg` 发现预设，`export/run` 只使用固定 Godot 导出参数并校验项目内目标路径；缺少模板返回 `not_supported`，超时返回 `timeout` 并删除半成品产物。导出在独立的 `--editor --headless --recovery-mode` 子进程中执行：不加载编辑器插件，避免与正在运行的编辑器争用 `.godot/gdapi.json`；响应 `messages` 已去除 ANSI 转义与控制字符。导出能力仅覆盖桌面预设（PCK/Pack），Android 预设与部署不在目标与验收范围内。

### Mutation 模型

| 类型 | UndoRedo | 覆盖保护 |
|---|---|---|
| 编辑器状态（节点/属性/信号/分组） | ✅ `undoable:true` | 不适用 |
| 文件/资源操作 | ❌ `undoable:false` | 直接覆盖 |
| 运行期 mutation（M3 runtime/*） | ❌ `undoable:false` | 不适用 |

所有 mutation 响应包含 `ok`、`changed`、`undoable` 字段。Router 根据 `RouteDoc.mutates()` 记录 mutation 成功与失败（含 body 校验错误），handler 已自审计时不会重复；纯只读请求的失败不会误记为 mutation。

`scene/current/save` 在保存前检查目标可写性，保存后从磁盘重新加载并核对实际场景内容；失败不报告 `saved:true`，保留原场景路径和未保存状态。`scene/current.edited` 来自编辑器真实的未保存场景列表（按场景索引对齐，`save-as` 之后同样准确）。`scene/delete` 的依赖检查包括 GDScript 中的 `preload`/`load`（资源路径、相对路径和 UID），不会为扫描而执行脚本。

`uid/repair` 复用所有文件写入入口的保护路径策略，逐一预检计划目标后才执行写入；省略 `roots` 时扫描整个 `res://`，扫描容器允许 `res://` / `user://` 根及其规范化别名，但根目录本身仍不是文件写入目标。广根目录扫描跳过受保护目录，显式传入受保护根仍整批拒绝。InputMap 保存失败恢复操作前完整事件、deadzone 和 ProjectSettings 状态。`resource/assign` 验证具体资源子类（含自定义脚本继承），并确认赋值生效后才提交 UndoRedo。

审计 `list` 支持 `safety` 过滤（`mutation`/`runtime`/`file`/`dangerous`）及 `since` 游标分页。容量上限为 1000，普通 mutation 优先淘汰；危险/文件类记录在保护记录队列填满前不会被普通流量驱逐。

### M3 运行时验证

M3 提供 runtime 路由；M6 引入 `runtime/eval` 作为 v2 协议下运行进程内执行的能力，必须在 broker 协商 v2 后才能路由。这些路由需要项目处于运行状态：使用 `gdcli exec project/run` 启动游戏后通过 `runtime/status` 等待 `connected`。所有 runtime/* 请求统一经后台 broker 转发：优先走 EditorDebuggerPlugin ↔ EngineDebugger 通道，不可用时回退到项目内 `.godot/gdapi_runtime` 文件 transport；公共路由不直接调用 session API。

| 分类 | 路由数 | 说明 |
|---|---|---|
| `runtime/status` `runtime/scene/tree` | 2 | 状态、场景树 |
| `runtime/node/info\|get\|set\|call\|find\|remove\|reparent\|create\|duplicate\|rename` | 10 | 节点增删改查，方法调用需要在节点元数据 `gdapi_callable_methods` allowlist 中 |
| `runtime/input/key\|mouse\|gamepad\|touch\|action\|sequence` | 6 | 输入模拟；sequence 最多 100 项、累计 ≤ 10 秒 |
| `runtime/screenshot/viewport\|camera\|frames` | 3 | PNG 截图，尺寸限制 1920x1080（超限源在 CPU readback 前拒绝），单响应 ≤ 4 MiB |
| `runtime/log/read\|clear` `runtime/debug/performance\|monitors\|errors\|breakpoints` | 6 | 日志游标与性能监控；`errors` 当前返回空列表，`breakpoints` 返回 `not_supported` |
| `runtime/assert/condition\|node_exists\|property_equals\|signal_received` | 4 | 等待 / 断言，使用固定 json grammar，不调用 Expression/eval |
| `runtime/signal/connect\|disconnect\|emit\|await` | 4 | 信号连接 / 等待 |

补充的 Runtime 路由：
- `runtime/recording/*`：有界输入录制分页、回放、取消与 session reset 清理。
- `runtime/monitor/*`：typed 属性跨帧采样、cursor 分页、停止和目标消失状态。
- `runtime/particles/info`：运行中读取 GPU emitter、材质、绘制资源和 frame。
- `runtime/test/*` `runtime/assert/screen_text`：声明式 JSON 场景 QA、压力测试/报告和 `Control.text` 断言，不执行 eval 或源码。
- `runtime/screenshot/compare`：比较实际 PNG 像素、尺寸、阈值、误差统计和差异框。
- `runtime/tween/*` `runtime/node/meta/*`：typed tween 运行状态与受控运行节点 meta。

等待阈值通过 `GDAPI_E2E_*_SECONDS` 显式配置；成功等待统计只给建议，不改动验收门限。共享会话内的 EngineDebugger 场景要求 `transport=engine_debugger`，验证协议 v2、运行时读写、输入、PNG 与 stop，不接受 file transport 回退。

M6 高风险能力（`editor/eval`、`runtime/eval`、`process/run`、`network/http_request`、
`filesystem/batch/delete`、`filesystem/batch/replace`、`filesystem/batch/recover`）自 2026-08-01 起默认可用，不再需要额外权限配置或
强制确认字段（gdcli 为开发期工具，鉴权由 loopback + Bearer token 承担）。能力仍受
内置硬上限约束：eval 源码 ≤16 KiB、
process 超时 ≤60s/输出 ≤1 MiB、network 仅 http(s)/超时 ≤60s/响应 ≤4 MiB/
重定向 ≤5、export 超时 ≤600s。所有危险操作保留审计日志（不含 secret）。

HTTP handler 的默认期限为 30 秒，可用 `GDAPI_HANDLER_TIMEOUT_MS` 显式设置。`process/run` 的业务期限还受当前 HTTP 请求剩余期限限制：HTTP 超时、客户端断连或服务器停止会取消并回收实际进程，终态与失败审计保持一致，不允许超时响应之后继续产生延迟副作用。Windows 使用 Job Object，Unix 使用独立进程组；进程自然完成、超时、取消及 runner 销毁都会清理后代，输出管道采用可停止的有界排空，不会无界等待继承管道的后代。

受限 eval 在解码输入前递归拒绝可加载或执行的 Object/Resource 等值。HTTP 重定向按 scheme、host、有效 port 区分 origin；跨源会剥离认证/Cookie 等敏感请求头，后续跳回原源也不会恢复凭据。审计摘要对 URL 中的 userinfo 脱敏，包括被拒绝请求与嵌套错误文本。

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
