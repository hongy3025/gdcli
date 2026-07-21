# gdcli 全功能能力路线图设计

日期：2026-06-27

最后更新：2026-07-21

状态：已批准；已按当前实现重新校准，等待后续 implementation plan

范围：仅设计 `gdcli exec` 与 gdapi route 能力面；不设计 MCP server 或外部工具名兼容。

## 背景

`docs/papers` 下的研究报告显示，Godot 编辑器与运行时操控工具已经形成较完整的能力谱系：场景管理、节点操作、脚本管理、文件与资源、信号与分组、编辑器控制、动画、TileMap、材质与 Shader、音频、UI、物理、导航、运行时调试、输入模拟、代码执行、ClassDB、导出与部署等。

gdcli 已具备 Rust CLI、Godot LSP、GDExtension HTTP server、Bearer token、嵌入式 addon 安装、命令自描述以及 TOON/JSON 输出。当前短板不是通信链路，而是 gdapi 的业务 route 数量少，共享安全 helper 尚未系统接入现有 route，运行时验证链路仍为空白。

本设计采用能力等价，而不是复刻外部项目的工具名或参数。本文同时承担两项职责：

1. 准确记录 2026-07-21 的现有实现基线。
2. 在不推翻现有公开 API 的前提下，定义可直接拆成 implementation plan 的后续路线图。

文中的“当前实现”是事实描述；“目标设计”和“里程碑”是尚待实现的要求。两者不得混用。

## 目标

1. 继续以 `gdcli exec <route> --data ...` 作为 gdapi 的唯一通用用户入口。
2. 沿用当前按业务对象划分的自然 route 命名方式。
3. 先收口现有基础设施，再逐步覆盖基础编辑、运行时验证、游戏系统、项目诊断、发布和高风险能力。
4. 保持 Rust GDExtension 业务逻辑无关；Godot 业务能力在 GDScript route 与 helper 中实现。
5. 所有能力都有可程序验证的成功、失败和无副作用验收条件。
6. 编辑器内存状态 mutation 优先接入 UndoRedo；文件、资源和运行时 mutation 必须明确标注不可撤销性。
7. 危险能力默认关闭或要求显式启用、`force:true`、边界限制和审计记录。
8. 仅支持 Godot 4.7，不为 Godot 4.3–4.6 保留构建、运行或测试兼容。

## 非目标

1. 不新增 MCP server 或 MCP tool schema。
2. 不追求外部项目工具名、参数或行为的一比一兼容。
3. 不恢复已经删除的 canonical/legacy alias 机制。
4. 不把所有能力压入单个实现里程碑。
5. 不绕过现有 loopback、Bearer token、请求大小、连接数和超时限制。
6. 不在本文中写逐文件实施步骤；逐文件任务属于后续 implementation plan。
7. 不支持 Godot 4.3、4.4、4.5 或 4.6；版本升级后不保留旧版 CI/E2E 矩阵。

## 当前实现基线

### 用户入口与 CLI 行为

`gdcli exec` 当前流程如下：

1. 解析 `--project`；未显式提供时从当前目录向上查找 `project.godot`。
2. 读取 `<project>/.godot/gdapi.json` 中的 `http_port` 和可选 `token`。
3. 固定向 `127.0.0.1` 发送 POST 请求；全局 `--host` 仅用于 LSP，不影响 exec。
4. `--data` 支持字面 JSON、`@file` 和 `-`（stdin）；未提供时发送 `{}`。
5. CLI 在发请求前验证 JSON；普通 route 不接受位置参数。
6. 默认请求超时为 30 秒，可通过 `--timeout` 修改。

两个自描述命令由 CLI 特殊处理：

- `command/list` 不接受 `--data` 或位置参数，固定发送 `{}`。
- `command/doc` 不接受 `--data`，要求恰好一个位置参数，并转换为 `{"command":"<route>"}`。

输出与退出码：

- 普通成功响应默认输出 TOON；`command/list` 和 `command/doc` 默认输出 clap 风格文本。
- 全局 `--json` 对所有 route 输出原始 minified JSON。
- 2xx 返回退出码 0，4xx 返回 2，5xx 返回 1，网络错误、超时或 metadata 缺失返回 3。

### HTTP 与插件链路

当前调用链为：

```text
gdcli exec
  -> cli/src/exec.rs
  -> 127.0.0.1:<http_port>
  -> gdapi Rust GDExtension HTTP server
  -> 跨线程 request/response queue
  -> EditorPlugin 主线程轮询
  -> GDScript router
  -> GDScript route handler
  -> Godot Editor API / Resource API
```

Rust GDExtension 当前负责：

- 仅绑定 IPv4 loopback，从 7890 开始最多探测 64 个端口。
- 校验 `Authorization: Bearer <token>`。
- 解析基于 `Content-Length` 的 HTTP 请求，不支持 chunked transfer encoding。
- 限制请求 body 为 16 MiB、header 总量为 32 KiB、header 数为 64。
- 限制并发连接为 128、请求队列为 256。
- 连接读取和响应写入超时均为 5 秒。
- GDScript handler 默认超时 30 秒，可通过 `GDAPI_HANDLER_TIMEOUT_MS` 在 100 至 300000 毫秒之间调整。
- 把请求排队到 Godot 主线程，并把响应送回异步连接。

Rust 层不包含场景、节点或资源业务逻辑，此边界应保持不变。

插件启动后把以下 metadata 写入 `res://.godot/gdapi.json`：

- `http_port`
- `lsp_port`
- `pid`
- `started_at`
- `gdapi_version`
- `token`

当前 workspace 版本、plugin 版本和 ping 中的 gdapi 版本均为 `0.2.0`。升级前基线仍锁定 godot-rust 0.5.3，使用 `api-4-3` feature，`.gdextension` 声明最低兼容 Godot 4.3；这些是待 M1 移除的现状，不是继续兼容的目标。

目标版本基线固定为：

- Godot 4.7.x。
- godot-rust 至少 0.5.4，并显式启用 `api-4-7`。
- `.gdextension` 的 `compatibility_minimum` 为 4.7。
- fixture 的 `config/features` 为 `4.7`。
- 构建和 E2E 不接受 Godot 4.3–4.6 作为替代运行时。

### Router 与自描述系统

`gdapi/addon/runtime/router.gd` 递归扫描 `gdapi/addon/routes/**/*.gd`。相对文件路径去除 `.gd` 后直接成为公开 route，例如 `scene/create.gd` 对应 `scene/create`。

当前规则：

- 只分发 POST。
- 忽略点号开头的目录项和下划线开头的 `.gd` 文件。
- 通过文件 mtime 重新加载新增或修改的 handler。
- 不生成 alias，不维护 canonical path 元数据。
- 增量扫描不会移除已从文件系统删除的 route；删除只有在强制全量扫描或插件重启后才能从注册表消失。
- 每个 handler 继承 `route_handler.gd`，实现 `handle(req, res)`，并可通过 `doc()` 提供结构化文档。

公开内置 route 共四个：

| Route | 当前行为 |
|---|---|
| `gdapi/health/ping` | 返回 `ok`、`gdapi_version` 和 `editor_version` |
| `gdapi/routes` | 返回按字母排序的公开 route 名数组 |
| `command/list` | 返回全部命令的 `path`、`summary` 和参数摘要 |
| `command/doc` | 按 body 中的 `command` 返回完整文档 |

`builtin_help.gd` 仍存在并被 router 实例化，但没有公开 dispatch 路径，不属于当前 API 表面。后续应删除死代码或明确赋予新用途，不能把它误记为可调用的 `/help` route。

### 当前公开 route 清单

当前共有 20 个公开 route：4 个内置 route，加 16 个文件系统 route。

| 领域 | Route | 当前语义 |
|---|---|---|
| command | `command/list` | 列出命令摘要 |
| command | `command/doc` | 查询单个命令文档 |
| console | `console/output` | 从编辑器 Output 面板按字符 offset 增量读取文本 |
| gdapi | `gdapi/health/ping` | 健康检查 |
| gdapi | `gdapi/health/pathcheck` | 调用 PathGuard 校验和规范化路径 |
| gdapi | `gdapi/routes` | 列出 route 名 |
| gdapi | `gdapi/loglevel` | 查询或设置插件日志级别 |
| gdapi | `gdapi/audit/list` | 按 seq 增量读取内存审计日志 |
| gdapi | `gdapi/audit/clear` | 要求 `force:true` 后清空审计日志 |
| godot | `godot/version` | 返回 Godot 版本信息 |
| project | `project/info` | 返回项目名称、主场景、路径和渲染方法 |
| project | `project/run` | 运行主场景或指定场景 |
| project | `project/stop` | 停止正在运行的场景 |
| scene | `scene/create` | 创建并保存 PackedScene，然后在编辑器中重载该路径 |
| scene | `scene/add_node` | 离线实例化 PackedScene、添加节点并覆盖保存 |
| scene | `scene/save` | 加载场景资源并保存到原路径或新路径 |
| scene | `scene/load_sprite` | 离线修改精灵纹理并覆盖保存场景 |
| scene | `scene/export_mesh_library` | 从场景提取 mesh 并保存 MeshLibrary |
| uid | `uid/get` | 查询资源文件及其 `.uid` 文件 |
| uid | `uid/update_all` | 扫描并重存场景/脚本以补充 UID |

现有 route path 是已经发布的 API。后续不得把同一路径静默改成不兼容语义。

### 当前共享基础设施成熟度

| 模块 | 已实现 | 当前接入程度 | 路线图结论 |
|---|---|---|---|
| `request.gd` | JSON Dictionary body、header/query、日志方法 | 所有 route 使用 | 保持；补齐无效 body 的一致错误策略 |
| `response.gd` | JSON/text/file/error、单次发送保护 | 所有 route 使用 | 保持；统一错误 contract |
| `route_doc.gd` / `param_doc.gd` | summary、description、params、returns、examples | 当前 route 已实现 `doc()` | 保持并增加完整性测试 |
| `path_guard.gd` | 相对路径转 `res://`，允许 `res://`/`user://`，拒绝 `..` 和系统绝对路径；写/删保护 gdapi addon 与 `.godot` | 仅 `gdapi/health/pathcheck` 使用 | 未收口；业务 route 必须接入，且需校验 mode |
| `variant_codec.gd` | 常用 Vector、Color、Rect、Transform、Quaternion、Basis、AABB、NodePath、Resource 双向转换 | 未被现有业务 route 使用 | 未收口；不能宣称 route 已支持这些类型 |
| `edit_action.gd` | 仅提供 plugin、UndoRedo manager 获取和可用性判断 | 未被现有业务 route 使用 | 只是访问器，不是 UndoRedo 包装层 |
| `error_codes.gd` | 10 个标准 code 和 `require_force` | 仅部分 gdapi route 使用 | 未收口；现有 scene/uid route 仍返回多种自定义 code |
| `audit_log.gd` | 把事件写入插件内存 buffer | 只有 `gdapi/audit/clear` 记录事件 | 未收口；普通 mutation 和其它危险操作未审计 |
| `router.gd` | 自动扫描、mtime 热重载、4 个内置 route | 已投入使用 | 基本可用；需处理删除检测与遗留 help 死代码 |

审计 buffer 当前最多保留 1000 条，插件重启后丢失。每条记录可包含 `route`、`safety`、`summary`、`ok`、`code`，插件补充 `seq` 和 `ts`。`gdapi/audit/clear` 的审计事件仍错误记录为旧路径 `project/audit/clear`，必须在 M1 收口时修正。

### 当前测试事实

2026-07-21 的验证结果：

- `cargo test --workspace` 通过；覆盖 Rust HTTP/server、CLI exec、格式化、安装和 LSP。
- 升级前的 `uv run pytest tests/e2e/test_m1_smoke.py -v` 在真实 Godot 4.6.3 上得到 10 passed、6 failed。
- 6 个失败均来自测试仍调用已删除的 `routes` 和 `commands`；实现中的正确路径分别是 `gdapi/routes` 和 `command/list`。
- ping、PathGuard 正反例以及 audit clear/list 正反例均通过。
- `tests/fixture_project/tests/test_request.gd` 和 `test_route_doc.gd` 存在，但当前 pytest E2E harness 不执行这些 GDScript 测试，不能把它们计入自动化通过项。

因此，M1 的准确状态是“基础骨架已实现，但集成与验收未收口”，不是“已完成”。

## 已确定的架构决策

### 自然领域 route 命名

公开 route 使用“业务领域/子领域/动作”的自然路径，不使用 `editor/**` 或 `shared/**` 作为统一上下文前缀。

命名规则：

1. 顶层名称表示用户可理解的业务对象或服务，例如 `scene`、`node`、`script`、`resource`、`runtime`。
2. `gdapi/**` 只放 gdapi 自身的健康、审计、日志和发现能力。
3. `command/**` 只放命令自描述能力。
4. `editor/**` 只有在操作对象确实是编辑器 UI/状态时使用，例如 selection 或 main screen；不能作为所有编辑操作的机械前缀。
5. 一个 `.gd` 文件对应一个 route；避免巨大 `manage` route。
6. 不为尚未发布的路径预建空目录或 alias。

### 现有 route 兼容边界

现有 route 保持现有职责。新增能力不得复用同一路径表达另一套行为：

- `scene/add_node` 保持“按 scene_path 离线修改并保存 PackedScene”的文件型操作。
- 新增的 `node/create` 面向当前编辑场景中的节点操作，并接入 UndoRedo。
- `scene/save` 保持当前资源保存/另存语义。
- 当前编辑场景保存使用新的 `scene/current/save`，避免改变 `scene/save` 的必填参数和行为。
- `project/run`、`project/stop` 继续作为编辑器启动/停止游戏的控制入口。

如果未来确认现有 route 设计不再适用，必须经过显式 deprecation 周期，而不是引入隐藏 alias。

### Mutation 模型

mutation 分为三类：

| 类型 | 示例 | UndoRedo | 安全要求 |
|---|---|---|---|
| 当前编辑器状态 | 当前场景节点增删、属性、信号、分组 | 应支持 | 返回 `undoable:true`；失败不创建 action |
| 文件/资源持久化 | 写脚本、覆盖场景、移动资源、重导入 | 通常不支持 | 返回 `undoable:false`；覆盖/删除要求 `force:true` |
| 运行时状态 | runtime node set/call、输入模拟 | 不支持 | 返回 `undoable:false`；限制目标、超时和输出 |

所有 mutation 响应至少应明确：

- `ok`
- `changed`
- `undoable`
- 受影响对象或路径
- 发生持久化时的 `saved`、`written`、`reimported` 等领域字段

### Route contract

新增和重构 route 遵守以下 contract：

- 仅接受 POST 和 JSON object body。
- 成功响应包含 `ok:true`。
- 错误响应使用 `{"error": String, "code": String, "details"?: Dictionary}`。
- 参数缺失、类型错误、路径错误、对象不存在、安全拒绝和 Godot API 失败必须使用稳定 code。
- `doc()` 必须准确描述参数类型、默认值、返回字段和至少一个有参数 route 的示例。
- CLI 继续只对 `command/list` 和 `command/doc` 做特殊输入与输出处理；其它 route 维持通用传输。

标准错误 code 为：

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

不再为同类错误新增 `invalid_type`、`load_failed`、`node_not_found`、`save_failed` 等 route 私有 code；具体 Godot 错误放入 `details`。

## 目标能力面

以下 route 是路线图目标，不代表当前已实现。

### 基础编辑

- Scene：`scene/current`、`scene/open`、`scene/current/save`、`scene/close`、`scene/tree`、`scene/list_open`
- Node：`node/create|delete|duplicate|rename|reparent|move|get|set|list|select`
- Property：`node/property/get|set|list|reset|revert`
- Signal：`node/signal/list|connect|disconnect|emit`
- Group：`node/group/list|add|remove|nodes`
- Script：`script/read|create|write|patch|attach|detach|current|open|validate`
- Filesystem：`filesystem/list|read|write|search|grep|reimport`
- Resource：`resource/info|deps|search|reimport|assign|create|delete|move`
- Editor UI：`editor/selection/get|set`、`editor/main_screen/set`

### LSP 融合边界

代码智能继续由 `gdcli lsp` 提供。exec route 负责编辑器内的文件、脚本挂载、当前脚本、打开位置和 Godot 侧验证，不重复实现 rename、references、definition、declaration、symbols、hover 或 diagnostics。

### Runtime 验证闭环

编辑器插件当前只能启动/停止游戏，不能直接检查独立游戏进程。M3 必须增加显式 runtime probe 通道。优先使用 Godot 原生 EngineDebugger 消息链路；若先交付 autoload 通道，协议层必须与 transport 解耦，以便后续替换而不改变公开 route。

目标 route：

- `runtime/status`
- `runtime/scene/tree`
- `runtime/node/info|get|set|call|find|remove|reparent`
- `runtime/input/key|mouse|gamepad|touch|action|sequence`
- `runtime/screenshot/viewport|camera|frames`
- `runtime/log/read|clear`
- `runtime/assert/condition|node_exists|property_equals|signal_received`
- `runtime/signal/connect|disconnect|emit|await`
- `runtime/debug/performance|monitors|errors|breakpoints`

### 游戏系统域

- `animation/create|delete|play|stop|track/add|track/remove|key/add|key/remove`
- `animation_tree/state/add|transition/add|blend/set`
- `tilemap/info|cell/get|cell/set|rect/fill|layer/clear|used_cells`
- `material/create|info|set|assign|duplicate|save`
- `shader/read|write|uniforms|material/create|param/set`
- `audio/bus/list|bus/add|bus/remove|player/create|play|stop`
- `ui/control/set_anchor|text/set|layout/build`
- `theme/create|color/set|constant/set|font_size/set|stylebox/set`
- `physics/body/create|shape/create|layer/set|raycast|joint/create`
- `navigation/region/list|mesh/bake|path/get|agent/target`

### 项目、诊断与发布

- `project/settings/get|set|list|reset`
- `project/input_map/list|action/add|action/remove|bind|unbind`
- `project/autoload/list|add|remove`
- `classdb/classes|class|methods|properties|signals|inheriters`
- `uid/repair`
- `diagnostics/health|unused_resources|cycle_deps|script_errors`
- `export/presets|run`
- `export/android/devices|deploy`

### 高风险能力

高风险能力进入总体路线图，但默认关闭：

- `editor/eval`
- `runtime/eval`
- `process/run`
- `network/http_request`
- 删除、覆盖写、批量替换、导出和部署

每次调用必须：

- 通过项目级配置显式启用对应能力类别。
- 对产生副作用的调用要求 `force:true`。
- 记录实际公开 route、参数摘要、目标、成功/失败和稳定错误 code。
- 不记录 token、Authorization header 或脚本中的其它 secret。
- 限制路径、命令、URL、响应大小和执行时间。

## 里程碑

### M1：现有基础设施收口

目标：把已经存在的 router、helper 和 E2E 从“骨架可用”提升为可供后续能力复用的稳定基线。

内容：

- 将 godot-rust 从锁定的 0.5.3 升级到至少 0.5.4，并把 feature 从 `api-4-3` 改为 `api-4-7`。
- 将 `.gdextension` 的 `compatibility_minimum` 和 fixture `config/features` 统一改为 4.7。
- E2E 启动前检查 `GODOT_BIN --version`，非 4.7 直接以明确错误终止，不降级、不 skip。
- 修复 M1 E2E 中的 `routes`、`commands` 旧路径，统一使用 `gdapi/routes`、`command/list`、`command/doc`。
- 断言完整的 20-route 当前清单以及命令文档结构。
- 修正源码、注释、README 和审计记录中的旧 route 名。
- 删除未公开的 builtin help 死代码，或在不增加重复 API 的前提下明确其内部用途。
- 让 router 在 route 文件删除后移除旧注册项，并为新增、修改、删除分别增加验证。
- 明确 PathGuard 的 read/write/delete mode，拒绝未知 mode；让现有文件型 route 使用统一路径校验。
- 为 Variant codec 增加真实 route 接入测试；在接入前不扩展 Packed arrays 声明。
- 把 EditAction 从访问器扩展为统一 action helper，并用最小编辑器 mutation 证明 do/undo 行为。
- 把现有 route 错误收敛到标准 code；Godot 原始错误写入 `details`。
- 修正 audit clear 的记录路径，并让现有危险 mutation 进入审计。
- 明确现有离线 scene mutation 返回 `undoable:false`，覆盖已有文件时要求 `force:true`。
- 把 GDScript helper/route_doc/request 测试接入自动化执行链路。

验收：

- `cargo fmt --check`、`cargo clippy --workspace`、`cargo test --workspace` 全部通过。
- `cargo tree -p gdapi` 显示 godot-rust 版本不低于 0.5.4，且构建启用 `api-4-7`。
- `uv run pytest tests/e2e/ -v` 在 Godot 4.7.x 上通过；Godot 4.3–4.6 会在测试启动前被明确拒绝。
- `gdapi/routes` 精确返回当前预期清单，`command/list` 与 `command/doc` 文档一致。
- 新增、修改、删除 route 文件后，热重载注册表与磁盘一致。
- 所有现有文件型 route 的 traversal、绝对路径、保护目录和覆盖未授权反例均无副作用。
- 至少一个真实 editor mutation 可 undo/redo；所有不可撤销 route 明确返回 `undoable:false`。
- 危险操作的成功和失败均产生正确 route 名的审计记录，且不包含 secret。

### M2：基础编辑闭环 ✅ 已完成

实现内容：

- 当前编辑场景的 current/open/save/close/tree/list_open。
- Node CRUD、property、hierarchy 和 selection。
- Script read/create/write/patch/attach/detach/current/open/validate。
- Filesystem list/read/write/search/grep/reimport。
- Resource info/deps/search/reimport/assign/create/delete/move。
- Signal list/connect/disconnect/emit。
- Group list/add/remove/nodes。

验收：

- 在 fixture 中创建并打开测试场景，查询树结构与磁盘内容精确一致。
- 节点新增、重命名、reparent、属性设置和删除可逐步 undo/redo，保存重开后结果一致。
- Vector、Color、NodePath 和 Resource 属性通过 Variant codec 往返不丢失类型。
- 创建和 patch 脚本、挂载到节点后，文件内容、脚本验证结果和场景引用均正确。
- 文件和资源覆盖/删除未传 `force:true` 时返回 `unsafe_operation` 或 `conflict`，且内容不变。
- 信号连接与断开、分组添加与移除在保存重开后仍可查询。
- 每个 mutation 的响应、错误 code、UndoRedo 标记和 audit 行为符合统一 contract。

### M3：Runtime 验证闭环

内容：

- runtime probe transport 和连接状态。
- runtime scene tree、node inspect/get/set/call。
- key/mouse/gamepad/touch/action 输入模拟。
- screenshot 与 frame capture。
- runtime log/error 增量缓冲。
- wait/assert/condition。
- runtime signal await/emit。

验收：

- 启动 fixture 场景后，`runtime/status` 能区分未运行、连接中和已连接。
- runtime tree 与 fixture 中的实际节点、类型和关键属性匹配。
- 输入模拟能改变 fixture 暴露的可观测状态。
- screenshot 返回有效 PNG 或经过明确约定的图像 metadata。
- assert 成功、失败和超时返回稳定结构与 code。
- runtime log/error 可按游标增量读取，不重复、不漏掉 fixture 生成的已知事件。
- 停止游戏或 probe 断开后，待处理 await/call 可预测地失败并完成清理。

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

- 每个领域使用独立 fixture 数据，至少覆盖创建、查询、修改、保存和重开验证。
- 动画 track/key、TileMap cell、Shader uniform、Audio bus、Theme 属性、Physics shape 和 Navigation path 均有类型精确断言。
- 支持 UndoRedo 的 editor mutation 可撤销；资源写入明确不可撤销并遵守覆盖保护。

### M5：项目、诊断与发布

内容：

- Project settings、InputMap 和 Autoload。
- ClassDB 查询。
- UID repair。
- 项目健康检查、unused resources、cycle dependencies 和 script errors。
- export preset 查询与导出。
- Android device 查询与 deploy。

验收：

- settings/input map/autoload mutation 可通过 fixture snapshot 恢复，不污染后续测试。
- ClassDB 返回稳定、可分页或可过滤的结构。
- diagnostics 能准确报告 fixture 中刻意制造的问题。
- export 使用最小 preset，验证产物；缺少模板时返回明确 `not_supported` 或环境错误，而不是静默 skip。
- Android 无设备时返回稳定错误；只有显式选择设备并确认后才部署。

### M6：高风险能力

内容：

- editor eval。
- runtime eval。
- process execution。
- network request。
- 批量删除、批量替换和部署类操作。

验收：

- 默认配置下所有高风险 route 均返回 `permission_denied` 或 `unsafe_operation`。
- 显式启用但未传 `force:true` 时仍拒绝 mutation。
- 只允许受控 fixture 目标执行；路径、URL、命令、超时和输出大小限制生效。
- 每次成功、失败、超时和安全拒绝均产生去敏后的审计记录。

## E2E 验证策略

当前 pytest harness 的生命周期继续作为基础：

1. `cargo build --workspace`。
2. `gdcli install --project tests/fixture_project --force`。
3. 运行 `scripts/setup-dev.py --no-build` 准备本地 addon 二进制。
4. 启动 Godot editor/headless editor。
5. 等待 `.godot/gdapi.json`，读取端口、token 和版本。
6. 通过 `gdcli --json exec` 执行正例和反例。
7. 查询对象、读取文件、重开场景或调用 runtime assert 验证最终状态。
8. 清理生成物并停止 Godot。

后续 plan 必须补齐：

- fixture mutation 的隔离或快照恢复，避免测试顺序依赖。
- stale metadata 清理和 Godot 异常退出清理。
- helper GDScript 测试的自动执行入口。
- Godot 版本预检；只接受 4.7.x，不维护旧版验证矩阵。
- 对必须存在的外部条件使用显式失败；只对真正缺失的可选环境使用 skip。

所有里程碑遵循精确收口标准：

- 不只检查 HTTP 成功，还检查最终对象和持久化状态。
- 验证错误分支没有副作用。
- 验证 UndoRedo，或明确断言 `undoable:false`。
- 验证危险操作进入审计日志。
- 验证 route 文档与真实参数和返回字段一致。
- 验证无额外节点、文件、资源、运行进程或 pending 请求残留。

## 成功标准

完成全部里程碑后，gdcli 能通过 `gdcli exec` 覆盖 Godot 编辑器和运行时操控的主要能力域：安全编辑场景和脚本，管理资源、信号、分组和项目设置，构建常见游戏系统对象，执行运行时验证，诊断和导出项目，并在显式受控条件下执行高风险能力。

每个公开 route 都必须满足：稳定路径、结构化自描述、统一错误、明确 mutation/UndoRedo 语义、安全边界、审计要求和自动化验收。路线图只有在所有能力域均有可重复验证证据时才视为完成。

## 历史决策记录

原始设计曾要求所有新 route 使用 `editor/**`、`runtime/**`、`project/**`、`shared/**` 上下文前缀，并为旧路径维护 canonical/legacy alias。该方案已在 2026-06-27 至 2026-06-28 的实现演进中撤销：alias 机制被删除，route 目录改为从 `routes/` 根目录直接扫描，公开 API 改用当前自然领域路径。

本路线图不再把该前缀方案作为候选架构。后续 plan 必须以本文列出的自然 route、无 alias 机制和现有 20-route 基线为准。
