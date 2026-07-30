# gdcli 用户手册 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 编写一套渐进式披露的 gdcli 用户手册，中文 Markdown，覆盖所有子命令和 exec 路由。

**Architecture:** Hub-and-spoke 结构：一个入口文档 + 每个子命令独立文件。exec 子命令采用"教用户在线查询 + 全路由一览表"策略，不逐路由详细展开。

**Tech Stack:** Markdown（中文）

## Global Constraints

- 所有文档写入 `docs/gdcli/` 目录
- 中文，精确简洁，高信息密度
- 不解释 CLI 惯用法（管道、重定向、`--help` 等）
- exec 手册不逐路由详细描述，使用 `command/doc` 在线查询替代
- 路由表数据来源：扫描 `gdapi/addon/routes/` 目录下的所有 `.gd` 文件的 `doc()` 方法中的 summary 字段

---

### Task 1: gdcli-manual.md（入口文档）

**Files:**
- Create: `docs/gdcli/gdcli-manual.md`

**Interfaces:**
- Consumes: 无
- Produces: 主文档，链接到其他子命令文档

- [ ] **Step 1: 编写文档头部**

```markdown
# gdcli 用户手册

gdcli 是与 Godot 编辑器交互的命令行工具。两种工作模式：

- **LSP 模式** — 通过 Godot 内置 LSP 服务器进行代码智能操作
- **exec 模式** — 通过 gdapi HTTP 插件调用编辑器功能

```

- [ ] **Step 2: 编写安装与前置条件**

```markdown
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
```

- [ ] **Step 3: 编写快速上手**

```markdown
## 快速上手

```bash
# 检查 LSP 连接
gdcli status --project .

# 查找符号引用
gdcli lsp references player.gd:health

# 列出所有编辑器命令
gdcli exec command/list --project .
```
```

- [ ] **Step 4: 编写子命令索引表**

```markdown
## 子命令

| 子命令 | 功能 | 文档 |
|--------|------|------|
| `lsp` | LSP 代码智能操作（重命名、引用、定义等） | [gdcli-lsp.md](gdcli-lsp.md) |
| `status` | 检查 LSP 连接状态 | [gdcli-status.md](gdcli-status.md) |
| `install` | 安装 gdapi 编辑器插件到目标项目 | [gdcli-install.md](gdcli-install.md) |
| `exec` | 调用 Godot 编辑器命令 | [gdcli-exec.md](gdcli-exec.md) |
```

- [ ] **Step 5: 编写全局选项**

```markdown
## 全局选项

| 选项 | 默认 | 说明 |
|------|------|------|
| `--project <path>` | 当前目录 | Godot 项目根目录 |
| `--port <port>` | 6005 | LSP 端口（自动发现时无需指定） |
| `--json` | — | JSON 输出格式（替代人类可读格式） |
```

- [ ] **Step 6: 最终检查**

确认所有链接指向正确的文件路径，无拼写错误。

---

### Task 2: gdcli-lsp.md（LSP 子命令）

**Files:**
- Create: `docs/gdcli/gdcli-lsp.md`

**Interfaces:**
- Consumes: 无
- Produces: LSP 子命令参考文档

- [ ] **Step 1: 编写概述与定位方式**

```markdown
# gdcli lsp — LSP 代码智能操作

通过 Godot 内置 LSP 服务器操作代码。需要编辑器运行中。

## 定位方式

支持两种方式指定目标符号：

**行列号**（1-based，与编辑器显示一致）：
```bash
gdcli lsp definition player.gd 10 5
gdcli lsp rename player.gd 10 5 new_name
```

**符号路径**（无需手动查找行列号）：
```bash
gdcli lsp definition player.gd:health
gdcli lsp definition player.gd:Player.Inventory.name
```
```

- [ ] **Step 2: 编写子命令速查表**

查阅 `cli/src/main.rs` 中 `LspCmd` 枚举（约第 76-103 行），确认所有 9 个子命令的名称和参数，写成表格：

```markdown
## 子命令

| 子命令 | 参数 | 功能 |
|--------|------|------|
| `rename` | `<target> <new_name>` | 重命名符号 |
| `references` | `<target>` | 查找引用 |
| `definition` | `<target>` | 跳转到定义 |
| `declaration` | `<target>` | 跳转到声明 |
| `symbols` | `<file>` | 列出文件符号 |
| `hover` | `<target>` | 悬浮提示 |
| `native-symbol` | `<class> [member]` | 查询 Godot 原生类文档 |
| `diagnostics` | `[file]` | 诊断信息（编译错误/警告） |
| `capabilities` | — | 服务器能力列表 |
```

- [ ] **Step 3: 编写符号路径格式说明**

```
- 简写：`player.gd:counter` — 符号名在当前文件内唯一时使用
- 完整：`player.gd:Player.health` — 类名.成员
- 多级：`player.gd:Player.Inventory.Item.name` — 嵌套类
- `res://` 前缀：`res://player.gd:Player.health` — 完整项目路径
- 限制：文件名含 `.`（如 `2d_in_3d.gd`）时只能用简写形式
```

- [ ] **Step 4: 编写 native-symbol 渐进式披露**

```markdown
## native-symbol 渐进式披露

查询 Godot 内置类文档。三个披露级别：

| 模式 | 示例 | 输出 |
|------|------|------|
| 默认 | `gdcli lsp native-symbol Node3D` | 类名、签名、描述全文 |
| `--members` | `gdcli lsp native-symbol --members Node3D` | 按 Constants/Properties/Signals/Methods 分组列表 |
| `--full` | `gdcli lsp native-symbol --full Node3D` | 所有成员完整展开（detail + 全部 documentation） |
| 查询成员 | `gdcli lsp native-symbol Node3D get_parent` | 单个成员详情 |

`--members` 与 `--full` 互斥。`--json` 模式下输出完整 JSON，不受 flag 影响。
```

---

### Task 3: gdcli-status.md + gdcli-install.md（小型文档）

**Files:**
- Create: `docs/gdcli/gdcli-status.md`
- Create: `docs/gdcli/gdcli-install.md`

**Interfaces:**
- Consumes: 无
- Produces: 两个小型子命令文档

- [ ] **Step 1: 编写 gdcli-status.md**

```markdown
# gdcli status — 检查 LSP 连接状态

验证与 Godot LSP 服务器的连接。

```bash
gdcli status --project /path/to/project
```

连接成功时输出编辑器版本信息，失败时输出错误到 stderr 并退出码非 0。
```

- [ ] **Step 2: 编写 gdcli-install.md**

```markdown
# gdcli install — 安装编辑器插件

将 gdapi 插件安装到目标 Godot 项目，自动修改 `project.godot` 启用插件。

```bash
gdcli install --project /path/to/project
```

| 选项 | 说明 |
|------|------|
| `--force` | 覆盖已有安装 |
| `--no-enable` | 不修改 `project.godot` 启用插件 |

安装效果：复制 gdapi 插件文件到 `addons/gdapi/`，在 `project.godot` 中添加插件引用。
安装后需在 Godot 编辑器中打开项目以激活插件。
```

---

### Task 4: gdcli-exec.md（exec 子命令 + 路由表）

**Files:**
- Create: `docs/gdcli/gdcli-exec.md`

**Interfaces:**
- Consumes: 扫描 `gdapi/addon/routes/` 下所有 `.gd` 文件的 `doc()` 方法获取 summary
- Produces: exec 子命令参考文档 + 全路由一览表

- [ ] **Step 1: 编写 exec 概述与语法**

```markdown
# gdcli exec — 调用 Godot 编辑器命令

通过 gdapi HTTP 插件与运行中的 Godot 编辑器通信。需要编辑器运行中且 gdapi 插件已启用。

```bash
gdcli exec <command> [--data <json>] [--timeout <secs>] --project <path>
```

| 选项 | 默认 | 说明 |
|------|------|------|
| `--data <json>` | `{}` | 请求数据：字面 JSON、`@file`（从文件读取）、`-`（从 stdin 读取） |
| `--timeout <secs>` | 30 | 请求超时秒数 |
```

- [ ] **Step 2: 编写特殊命令与在线文档查询**

```markdown
## 特殊命令

`command/list` 和 `command/doc` 使用位置参数，不接受 `--data`：

```bash
gdcli exec command/list              # 列出所有可用路由
gdcli exec command/doc scene/save    # 查看路由的完整文档
```

## 在线文档查询

gdapi 路由自带自描述文档，无需翻阅静态手册：

```bash
# 查看所有路由
gdcli exec command/list --project .

# 查看某个路由的详细文档（参数、返回值、示例）
gdcli exec command/doc scene/create --project .
gdcli exec command/doc node/property/set --project .
gdcli exec command/doc runtime/input/key --project .
```

`command/doc` 输出包含：功能描述、参数名/类型/必填/说明、返回值字段、调用示例。
```

- [ ] **Step 3: 编写输出格式与退出码**

```markdown
## 输出格式

| 条件 | 格式 |
|------|------|
| 默认 | TOON（人类可读键值对/表格/树状列表） |
| `--json` | 原始 JSON（脚本友好） |
| `command/list` | clap 风格（命令名 + 摘要） |
| `command/doc` | clap 风格（参数/返回值/示例） |

## 退出码

| 码 | 含义 |
|----|------|
| 0 | 成功（2xx 响应） |
| 1 | 服务器错误（5xx 响应） |
| 2 | 客户端错误（4xx 响应或参数错误） |
| 3 | 网络错误、超时或元数据缺失 |
```

- [ ] **Step 4: 编写全路由一览表**

扫描 `gdapi/addon/routes/` 目录下所有 `.gd` 文件的 `doc()` 方法，提取每个路由的 `make("summary")` 文本。按功能域分组，每组一个表格。

分组及顺序：

```
### gdapi（插件系统）
| 路由 | 说明 |
|------|------|
| gdapi/health/ping | 健康检查 |
| gdapi/health/pathcheck | 校验并规范化项目路径 |
| gdapi/audit/list | 读取审计日志 |
| gdapi/audit/clear | 清空审计日志 |
| gdapi/loglevel | 查询或设置日志级别 |

### godot（引擎信息）
| 路由 | 说明 |
|------|------|
| godot/version | Godot 引擎版本详细信息 |

### scene（场景操作）
| 路由 | 说明 |
|------|------|
| scene/create | 创建新场景文件 |
| scene/open | 在编辑器中打开场景 |
| scene/close | 关闭当前或指定场景 |
| scene/save | 保存场景文件 |
| scene/current | 当前编辑场景信息 |
| scene/current/save | 保存当前编辑场景 |
| scene/tree | 返回场景节点树 |
| scene/list_open | 列出编辑器当前打开的场景 |
| scene/add_node | 向场景中添加新节点 |
| scene/load_sprite | 为精灵节点加载纹理 |
| scene/export_mesh_library | 从场景导出 MeshLibrary |

### node（节点操作）
| 路由 | 说明 |
|------|------|
| node/create | 在指定父节点下创建节点 |
| node/delete | 删除节点 |
| node/duplicate | 复制节点及子结构 |
| node/rename | 重命名节点 |
| node/reparent | 把节点挂接到新父节点 |
| node/move | 调整节点在兄弟节点中的顺序 |
| node/get | 读取节点摘要 |
| node/set | 批量原子设置节点属性 |
| node/list | 列出节点直接子节点 |
| node/select | 选中一个或多个节点 |
| node/property/get | 读取节点属性 |
| node/property/set | 设置节点属性 |
| node/property/list | 列出节点属性 schema |
| node/property/reset | 重置属性为类默认值 |
| node/property/revert | 还原属性到默认值 |
| node/group/add | 节点加入 group |
| node/group/remove | 节点退出 group |
| node/group/list | 列出节点所属 group |
| node/group/nodes | 列出 group 中的节点 |
| node/signal/connect | 连接节点信号到目标方法 |
| node/signal/disconnect | 断开节点信号连接 |
| node/signal/list | 列出节点信号和已连接信号 |
| node/signal/emit | 在编辑器中触发节点信号 |

### script（脚本操作）
| 路由 | 说明 |
|------|------|
| script/create | 创建 .gd 脚本文件 |
| script/read | 读取 .gd 脚本文件内容 |
| script/write | 覆盖写入 .gd 脚本文件 |
| script/patch | 替换脚本中行区间 |
| script/validate | 校验 .gd 脚本语法 |
| script/open | 把脚本加载到 Script Editor |
| script/attach | 挂接脚本到节点 |
| script/detach | 卸下节点脚本 |
| script/current | 当前编辑的脚本路径 |

### resource（资源操作）
| 路由 | 说明 |
|------|------|
| resource/create | 创建并保存 Resource 子类 |
| resource/search | 通过 EditorFileSystem 搜索资源 |
| resource/info | 读取资源元数据 |
| resource/deps | 读取资源依赖列表 |
| resource/move | 在文件系统中移动资源 |
| resource/delete | 删除资源文件 |
| resource/assign | 将 Resource 赋给节点属性 |
| resource/reimport | 重新导入一组资源 |

### project（项目操作）
| 路由 | 说明 |
|------|------|
| project/info | 获取项目基本信息 |
| project/run | 运行场景 |
| project/stop | 停止运行中的场景 |
| project/settings/get | 读取项目设置 |
| project/settings/set | 写入项目设置 |
| project/input_map/list | 列出 InputMap |
| project/autoload/list | 列出自动加载 |

### animation（动画）
| 路由 | 说明 |
|------|------|
| animation/create | 创建动画 |
| animation/delete | 删除动画 |
| animation/play | 播放动画 |
| animation/stop | 停止动画 |
| animation/key/add | 添加动画 key |
| animation/key/remove | 删除动画 key |
| animation/track/add | 添加动画 value track |
| animation/track/remove | 删除动画 track |

### animation_tree（动画树）
| 路由 | 说明 |
|------|------|
| animation_tree/blend/set | 设置 AnimationTree blend |
| animation_tree/state/add | 添加 AnimationTree state |
| animation_tree/transition/add | 添加 AnimationTree transition |

### audio（音频）
| 路由 | 说明 |
|------|------|
| audio/play | 播放音频 |
| audio/stop | 停止音频 |
| audio/bus/add | 添加音频总线 |
| audio/bus/list | 列出音频总线 |
| audio/bus/remove | 删除音频总线 |
| audio/player/create | 创建音频播放器 |

### classdb（ClassDB 查询）
| 路由 | 说明 |
|------|------|
| classdb/classes | 列出 Godot ClassDB 类 |
| classdb/class | 查询 ClassDB 类详情 |
| classdb/methods | 查询 ClassDB 方法 |
| classdb/properties | 查询 ClassDB 属性 |
| classdb/signals | 查询 ClassDB 信号 |
| classdb/inheriters | 查询 ClassDB 派生类 |

### console（控制台）
| 路由 | 说明 |
|------|------|
| console/output | 读取编辑器 Output 面板 |

### editor（编辑器）
| 路由 | 说明 |
|------|------|
| editor/eval | 执行编辑器内受限表达式 |
| editor/selection/get | 获取编辑器选中节点 |
| editor/main_screen/get | 获取当前主屏幕 |

### export（导出）
| 路由 | 说明 |
|------|------|
| export/android/build | 构建 Android 导出 |
| export/run | 运行导出预设 |
| export/presets | 列出导出预设 |

### filesystem（文件系统）
| 路由 | 说明 |
|------|------|
| filesystem/read | 读取文件文本内容 |
| filesystem/write | 写入文本文件 |
| filesystem/search | 按 glob 模式查找文件 |
| filesystem/list | 列出目录内容 |
| filesystem/grep | 在文件中搜索文本 |
| filesystem/reimport | 重新导入一组资源 |
| filesystem/batch/remove | 批量删除文件 |

### material（材质）
| 路由 | 说明 |
|------|------|
| material/create | 创建并赋值材质 |
| material/assign | 通过 UndoRedo 赋值材质 |
| material/set | 设置材质属性 |
| material/info | 查询节点材质 |
| material/save | 保存材质到项目资源 |
| material/duplicate | 复制材质到新资源 |

### navigation（导航）
| 路由 | 说明 |
|------|------|
| navigation/region/list | 列出 2D 导航区域 |
| navigation/path/get | 查询 2D 导航路径 |
| navigation/mesh/bake | 烘焙并保存 2D 导航网格 |
| navigation/agent/target | 设置运行期 2D 导航 agent 目标 |

### network（网络）
| 路由 | 说明 |
|------|------|
| network/http_request | 策略约束的 HTTP 请求 |

### physics（物理）
| 路由 | 说明 |
|------|------|
| physics/raycast | 执行 2D 物理射线检测 |
| physics/shape/colliders | 列出形状碰撞体 |
| physics/layer/collision | 配置层碰撞矩阵 |
| physics/joint/list | 列出关节 |
| physics/body/list | 列出物理体 |

### process（进程）
| 路由 | 说明 |
|------|------|
| process/run | 执行无 shell 的受限外部进程 |

### runtime（运行时）
| 路由 | 说明 |
|------|------|
| runtime/status | 查询运行期 broker 状态 |
| runtime/eval | 执行受限运行时表达式 |
| runtime/node/call | 调用运行期节点方法 |
| runtime/node/create | 创建运行期节点 |
| runtime/node/get | 读取运行期节点属性 |
| runtime/node/info | 查询运行期节点类型和属性 |
| runtime/node/set | 设置运行期节点属性 |
| runtime/node/remove | 删除运行期节点 |
| runtime/node/rename | 重命名运行期节点 |
| runtime/node/reparent | 重新挂载运行期节点 |
| runtime/node/duplicate | 复制运行期节点 |
| runtime/node/find | 在运行期场景树中查找节点 |
| runtime/scene/tree | 查询运行期场景树 |
| runtime/signal/await | 等待运行期信号 |
| runtime/signal/connect | 连接运行期信号 |
| runtime/signal/disconnect | 断开运行期信号连接 |
| runtime/signal/emit | 主动 emit 运行期信号 |
| runtime/log/read | 增量读取运行期日志 |
| runtime/log/clear | 清空运行期日志 ring buffer |
| runtime/debug/breakpoints | 编辑断点 |
| runtime/debug/errors | 列出运行期错误 |
| runtime/debug/monitors | 读取标准 Performance 监控指标 |
| runtime/debug/performance | 读取自定义 monitor 值 |
| runtime/assert/condition | 按 grammar 等待断言 |
| runtime/assert/node_exists | 等待节点出现在路径 |
| runtime/assert/property_equals | 等待属性等于期望值 |
| runtime/assert/signal_received | 等待信号发送一次 |
| runtime/screenshot/viewport | 截主视口当前帧 |
| runtime/screenshot/camera | 截 Camera 视口 |
| runtime/screenshot/frames | 按间隔连续截多帧 |
| runtime/input/key | 注入 InputEventKey |
| runtime/input/mouse | 注入 InputEventMouse |
| runtime/input/action | 触发 InputMap action |
| runtime/input/gamepad | 注入手柄 button/axis |
| runtime/input/touch | 注入 touch 事件 |
| runtime/input/sequence | 顺序触发多个输入事件 |

### shader（着色器）
| 路由 | 说明 |
|------|------|
| shader/read | 读取 Shader 源码 |
| shader/write | 创建或覆盖 Shader |
| shader/uniforms | 列出 Shader uniform |
| shader/param/set | 设置 ShaderMaterial uniform |
| shader/material/create | 创建 ShaderMaterial 资源 |

### theme（主题）
| 路由 | 说明 |
|------|------|
| theme/create | 创建 Theme 资源 |
| theme/stylebox/create | 创建 StyleBox |
| theme/font_size/set | 设置字体大小 |
| theme/constant/set | 设置常量 |
| theme/color/set | 设置主题色 |

### tilemap（瓦片地图）
| 路由 | 说明 |
|------|------|
| tilemap/info | 查询 TileMapLayer 信息 |
| tilemap/used_cells | 列出已用单元格 |
| tilemap/cell/get | 读取单元格 |
| tilemap/cell/set | 设置单元格 |
| tilemap/layer/clear | 清空 TileMapLayer |
| tilemap/rect/fill | 填充矩形区域 |

### uid（资源 UID）
| 路由 | 说明 |
|------|------|
| uid/get | 查询资源文件 UID |
| uid/update_all | 批量更新所有资源 UID |
| uid/repair | 扫描并修复资源 UID |

### ui（UI）
| 路由 | 说明 |
|------|------|
| ui/control/set_anchor | 设置控件锚点 |
| ui/layout/build | 构建固定 UI 布局 |
| ui/text/set | 设置控件文本 |

### diagnostics（诊断）
| 路由 | 说明 |
|------|------|
| diagnostics/health | 编辑器健康检查 |
| diagnostics/script_errors | 列出脚本错误 |
| diagnostics/cycle_deps | 检测循环依赖 |
| diagnostics/unused_resources | 列出未使用资源 |
```

- [ ] **Step 5: 最终检查**

确认所有路由路径正确，无遗漏。与 `gdapi/addon/routes/` 目录结构逐一核对。

---

### Task 5: 最终审阅与格式统一

**Files:**
- Modify: `docs/gdcli/gdcli-manual.md`
- Modify: `docs/gdcli/gdcli-lsp.md`
- Modify: `docs/gdcli/gdcli-status.md`
- Modify: `docs/gdcli/gdcli-install.md`
- Modify: `docs/gdcli/gdcli-exec.md`

**Interfaces:**
- Consumes: 所有已创建文档

- [ ] **Step 1: 交叉检查链接**

确认入口文档中的子命令索引链接正确指向每个 `.md` 文件。

- [ ] **Step 2: 风格一致性检查**

确认所有文件使用一致的标题层级、表格格式、代码块风格。

- [ ] **Step 3: 拼写与格式检查**

快速扫读，修正中文标点、空格、Markdown 渲染问题。

- [ ] **Step 4: 最终确认**

所有文件就绪，内容完整，无占位符。