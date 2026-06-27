# gdcli 全功能能力路线图设计

日期：2026-06-27
状态：已批准
范围：仅设计 `gdcli exec` 与 gdapi route 能力面；不设计 MCP server 或外部工具名兼容。

## 背景

`docs/papers` 下的研究报告显示，Godot 编辑器/运行时操控工具已经形成完整能力谱系：场景管理、节点操作、脚本管理、文件与资源、信号与分组、编辑器控制、动画、TileMap、材质与 Shader、音频、UI、物理、导航、运行时调试、输入模拟、代码执行、ClassDB、导出与部署等。

gdcli 当前优势是 Rust CLI、Godot LSP、GDExtension HTTP 安全底座、Bearer token、嵌入式 addon 安装和 TOON/JSON 输出。主要短板是操控域少、无 UndoRedo、缺节点/脚本/资源/信号基础能力、无运行时探针、无系统化验证夹具。

本设计采用能力等价，而不是复刻外部项目的工具名或参数。目标是为 gdcli 建立清晰的 route 目录、完整能力覆盖、分里程碑实施路径和可程序验证的收口标准。

## 目标

1. 继续以 `gdcli exec <route> --data ...` 作为唯一用户 API。
2. 通过 gdapi route 覆盖研究报告中的所有主要能力域。
3. 设计清晰稳定的 route 命名空间，避免后续能力扩展时目录混乱。
4. 将实现拆分为渐进里程碑，每个里程碑都有独立验证夹具。
5. 高风险能力纳入总体设计，但默认关闭或要求显式确认、`force:true`、安全级别与审计记录。
6. 所有编辑器 mutation 优先支持 UndoRedo。

## 非目标

1. 不新增 MCP server。
2. 不设计 MCP tool schema。
3. 不追求外部项目工具名、参数或行为的一比一兼容。
4. 不把所有能力压入一个实现里程碑。
5. 不绕过 gdcli 当前的 loopback、Bearer token、header/body limit 等安全底座。

## 总体架构

用户仍通过 shell 调用 `gdcli exec`。CLI 层只承担通用职责：

- 解析 `--project` 并读取 `.godot/gdapi.json`。
- 发送 Bearer token。
- POST JSON body 到 gdapi route。
- 处理超时、HTTP status 和退出码。
- 输出 TOON 或 JSON。

Godot 侧继续使用当前三层结构：

```text
gdcli exec
  -> Rust CLI HTTP client
  -> gdapi Rust GDExtension HTTP server
  -> GDScript router
  -> GDScript route handler
  -> Godot Editor API / Runtime probe
```

Rust GDExtension 仍保持极薄：只处理 HTTP、认证、队列、超时和响应回传，不承载业务逻辑。业务能力全部在 GDScript route 和共享 helper 中实现。

## Route 命名原则

新增能力统一使用显式上下文前缀。现有无前缀 route 继续保留作为兼容入口，但新能力只发布到新路径。

上下文前缀：

- `editor/**`：需要 EditorInterface、EditorFileSystem、EditorUndoRedoManager 的编辑器内操作。
- `runtime/**`：针对正在运行的游戏进程或 runtime probe 的操作。
- `project/**`：项目级设置、输入映射、autoload、诊断、UID、ClassDB、审计。
- `shared/**`：不依赖编辑器状态的只读信息或通用辅助能力。

路由名使用名词域 + 动词叶子，例如：

- `editor/node/create`
- `editor/node/property/set`
- `runtime/input/key`
- `project/input_map/bind`

避免把大型域压成一个巨大的 `manage` route。`gdcli exec` 不受 MCP 工具数量限制，因此优先可发现性和文档清晰度。后续若需要 MCP 映射，可另行在 MCP 层聚合。

## Route 目录规划

```text
gdapi/addon/routes/
  shared/
    godot/version.gd
    project/info.gd
    uid/get.gd

  editor/
    scene/
    node/
      property/
      signal/
      group/
    script/
    filesystem/
    resource/
    animation/
      tree/
    tilemap/
    material/
    shader/
    audio/
    ui/
    theme/
    physics/
    navigation/
    debug/
    control/
    eval/
    export/

  runtime/
    scene/
    node/
    input/
    screenshot/
    log/
    assert/
    signal/
    debug/
    eval/

  project/
    settings/
    input_map/
    autoload/
    uid/
    classdb/
    audit/
    diagnostics/
    health/
    process/
    network/
```

Router 需要支持新旧路径共存：

- 新 route 暴露为 `editor/**`、`runtime/**`、`project/**`、`shared/**`。
- 旧 route 如 `scene/create`、`project/run`、`log/output` 保留兼容。
- `/routes`、`/commands`、`/help` 必须标注 canonical path 与 legacy alias。

## 能力覆盖

### 1. 基础编辑

覆盖场景、节点、脚本、信号、分组、文件系统、资源。对应第一批可用闭环。

代表 route：

- `editor/scene/current|open|save|save_as|close|tree|list_open`
- `editor/node/create|delete|duplicate|rename|reparent|move|get|set|list|select`
- `editor/node/property/get|set|list|reset|revert`
- `editor/node/signal/list|connect|disconnect|emit`
- `editor/node/group/list|add|remove|nodes`
- `editor/script/read|create|write|patch|attach|detach|current|open|validate`
- `editor/filesystem/list|read|write|search|grep|reimport`
- `editor/resource/info|deps|search|reimport|assign|create|delete|move`
- `editor/control/run|stop|screenshot|selection/get|selection/set|main_screen/set`

### 2. 脚本与 LSP 融合

gdcli 现有 LSP 能力仍归 `gdcli lsp`。exec route 只负责 Godot 编辑器内脚本文件与挂载操作。后续可提供桥接 route 查询当前脚本、打开指定行、触发编辑器脚本验证，但不重复实现 LSP rename/references/definition。

### 3. 游戏系统域

覆盖常见游戏开发高频域：动画、AnimationTree、TileMap、材质、Shader、音频、UI、主题、物理、导航。

代表 route：

- `editor/animation/create|delete|play|stop|track/add|track/remove|key/add|key/remove`
- `editor/animation/tree/state/add|transition/add|blend/set`
- `editor/tilemap/info|cell/get|cell/set|rect/fill|layer/clear|used_cells`
- `editor/material/create|info|set|assign|duplicate|save`
- `editor/shader/read|write|uniforms|material/create|param/set`
- `editor/audio/bus/list|bus/add|bus/remove|player/create|play|stop`
- `editor/ui/control/set_anchor|text/set|layout/build`
- `editor/theme/create|color/set|constant/set|font_size/set|stylebox/set`
- `editor/physics/body/create|shape/create|layer/set|raycast|joint/create`
- `editor/navigation/region/list|mesh/bake|path/get|agent/target`

### 4. 运行时验证闭环

运行时能力用于让 AI agent 验证游戏是否真的按预期运行。优先采用 EngineDebugger runtime probe 方案；如实现复杂，可先使用最小 runtime autoload 通道，但最终设计以 Godot 原生调试链路为目标。

代表 route：

- `runtime/scene/tree`
- `runtime/node/info|get|set|call|find|remove|reparent`
- `runtime/input/key|mouse|gamepad|touch|action|sequence`
- `runtime/screenshot/viewport|camera|frames`
- `runtime/log/read|clear`
- `runtime/assert/condition|node_exists|property_equals|signal_received`
- `runtime/signal/connect|disconnect|emit|await`
- `runtime/debug/performance|monitors|errors|breakpoints`

### 5. 项目、诊断、导出

覆盖项目配置、输入映射、autoload、ClassDB、UID、健康检查、资源依赖、导出与部署。

代表 route：

- `project/settings/get|set|list|reset`
- `project/input_map/list|action/add|action/remove|bind|unbind`
- `project/autoload/list|add|remove`
- `project/classdb/classes|class|methods|properties|signals|inheriters`
- `project/uid/get|update_all|repair`
- `project/diagnostics/health|unused_resources|cycle_deps|script_errors`
- `editor/export/presets|run`
- `editor/export/android/devices|deploy`

### 6. 高风险能力

高风险能力纳入设计，但默认禁用或要求显式启用。包括：

- `editor/eval/script`
- `runtime/eval/script`
- `project/process/run`
- `project/network/http_request`
- 删除、覆盖写、批量替换、导出、部署

每次调用必须：

- 要求 `force:true` 或更高安全级别字段。
- 记录 audit log。
- 返回参数摘要、执行结果、影响范围。
- 对路径、命令、URL、输出大小和超时做限制。

## 共享基础设施

### 路径校验

统一 helper 负责把用户输入解析为 `res://` 或 `user://`，并执行安全检查：

- 允许 `res://`、`user://` 和项目相对路径。
- 拒绝 `..`、绝对系统路径和空路径。
- 写操作默认拒绝 gdapi addon 内部目录、`.godot/gdapi.json`、token、临时 metadata。
- 删除、覆盖和批量替换必须传 `force:true`。

### Variant 转换

统一 JSON ↔ Godot Variant 转换，支持：

- 基础 JSON 标量、数组、对象。
- `Vector2`、`Vector2i`、`Vector3`、`Vector3i`、`Vector4`、`Vector4i`。
- `Color`、`Rect2`、`Rect2i`、`Transform2D`。
- `Quaternion`、`Basis`、`Transform3D`、`AABB`。
- `NodePath`、Resource path、Packed arrays。

推荐输入形态：

```json
{"type":"Vector2","value":[10,20]}
```

### UndoRedo 包装

所有 editor mutation 优先通过 `EditorUndoRedoManager`：

- 节点创建、删除、复制、重命名、reparent、属性设置。
- 脚本 attach/detach。
- 信号 connect/disconnect。
- 分组 add/remove。
- 材质、资源、动画、TileMap 等编辑器对象变更。

无法 UndoRedo 的文件写入、导出、运行时操作必须在响应中明确标注 `undoable:false`。

### 错误模型

统一错误 code：

- `missing_param`
- `invalid_param`
- `invalid_path`
- `not_found`
- `conflict`
- `not_supported`
- `permission_denied`
- `unsafe_operation`
- `timeout`
- `godot_error`

HTTP status 继续表达错误类别，body 中保留 `error`、`code`、`details`。

### 审计日志

新增审计 helper，记录危险操作和状态变化：

- route path。
- 时间戳。
- 安全级别。
- 参数摘要，不记录 secret。
- 影响对象。
- 成功/失败。
- 错误 code。

审计读取 route：`project/audit/list`、`project/audit/clear`。

## 里程碑

### M1：基础设施与 route 命名迁移

内容：

- 新 route 命名空间支持：`editor/**`、`runtime/**`、`project/**`、`shared/**`。
- legacy alias 与 canonical path 元数据。
- 路径校验 helper。
- Variant 转换 helper。
- UndoRedo helper。
- 统一错误 helper。
- 审计日志 helper。
- E2E harness 框架。

验收：

- `gdcli exec ping`、`routes`、`commands`、`help` 正常。
- 新旧 route 同时可发现。
- 路径攻击、缺 token、未知 route、危险操作未授权均被拒绝。
- E2E harness 能启动 Godot fixture、等待 metadata、执行 smoke case、清理。

### M2：Core plus 基础编辑闭环

内容：

- Scene：current/open/save/save_as/close/tree/list_open。
- Node：CRUD、property、hierarchy、select。
- Script：read/create/write/patch/attach/detach/current/open/validate。
- Filesystem：list/read/write/search/grep/reimport。
- Resource：info/deps/search/reimport/assign。
- Signal：list/connect/disconnect/emit。
- Group：list/add/remove/nodes。

验收：

- 创建测试场景并精确验证场景树。
- 新增、重命名、reparent、设置属性、删除节点后，保存重开仍匹配预期。
- 创建脚本、patch 内容、attach 到节点，文件内容和场景引用均正确。
- 资源依赖、资源分配、reimport 可验证。
- 信号连接/断开、分组添加/移除可验证。
- 覆盖写、删除未传 `force:true` 返回 `conflict` 或 `unsafe_operation`。
- UndoRedo 对支持的 editor mutation 可用。

### M3：Runtime 验证闭环

内容：

- Runtime probe 通道。
- runtime scene tree、node inspect/get/set/call。
- runtime input key/mouse/gamepad/touch/action。
- screenshot/frame capture。
- runtime log/error buffer。
- wait/assert/condition。
- runtime signal await/emit。

验收：

- 启动 fixture 场景后可查询 runtime tree。
- 输入模拟能改变 fixture 中的可观测状态。
- screenshot 产生有效 PNG 或可验证图像元数据。
- assert route 能通过成功条件并拒绝失败条件。
- runtime log 与 error buffer 可增量读取。

### M4：游戏系统域

内容：

- Animation 与 AnimationTree。
- TileMap/TileSet。
- Material/Shader。
- Audio。
- UI/Theme。
- Physics。
- Navigation。

验收：

- 每个域有独立 fixture。
- 每个域至少覆盖创建、查询、修改、保存后再查询。
- 动画 track/key、TileMap cell、Shader uniform、Audio bus、Theme 属性、Physics shape、Navigation path 均可程序验证。

### M5：项目、发布与诊断

内容：

- Project settings。
- InputMap。
- Autoload。
- ClassDB。
- UID repair。
- 项目健康审计。
- unused resources、cycle dependencies、script errors。
- export preset 查询与导出。
- Android device/deploy。

验收：

- settings/input map/autoload 修改后可恢复。
- ClassDB 查询返回稳定结构。
- health/audit 对 fixture 中刻意制造的问题能报告准确结果。
- export 使用最小 fixture preset，并验证产物或明确跳过条件。
- Android deploy 无设备时返回可预测错误。

### M6：高风险能力

内容：

- editor eval。
- runtime eval。
- OS/process。
- network request。
- 批量删除、批量替换、部署类危险操作。

验收：

- 默认禁用时全部拒绝。
- 显式启用和 `force:true` 后只允许受限 fixture 场景执行。
- 超时、输出大小、路径、URL、命令白名单生效。
- audit log 精确记录每次危险调用。

## E2E 验证夹具

每个里程碑都新增独立 fixture 和脚本。外部依赖只有 `GODOT_BIN`。

通用流程：

1. 构建 workspace。
2. 使用 `gdcli install --project tests/fixture_project --force` 安装 addon。
3. 启动 Godot editor/headless editor 指向 fixture project。
4. 等待 `.godot/gdapi.json` 出现，并确认 `http_port`、`token`、`gdapi_version`。
5. 通过 `gdcli exec` 执行正例。
6. 通过查询 route、读取文件、重开场景或 runtime assert 验证最终状态。
7. 执行反例，验证错误 code 和状态未改变。
8. 清理本次生成物。
9. 停止 Godot。

精确收口标准：

- 不只检查命令成功，还检查最终对象状态。
- 验证错误分支不会产生副作用。
- 验证 UndoRedo 或明确标注不可撤销。
- 验证危险操作进入审计日志。
- 验证无额外节点、文件、资源残留。

## 成功标准

完成全部里程碑后，gdcli 能通过 `gdcli exec` 覆盖 Godot 编辑器和运行时操控工具生态中的主要功能域：安全地编辑场景和脚本，管理资源、信号、分组和项目设置，构建游戏系统对象，执行运行时验证，导出和诊断项目，并在受控条件下执行高风险能力。每个能力域都有程序化验证夹具证明功能精确达成并可回归测试。
