# M4 游戏系统域对齐设计

日期：2026-07-29

## 目标

将 M4 实施计划与总体路线图的 51 条游戏系统 route、已完成的 M3 broker/probe 架构及当前编辑器服务约定对齐。M4 覆盖 Animation/AnimationTree、TileMapLayer/TileSet、Material/Shader、Audio、UI/Theme、Physics 和 Navigation。

## 公开 route 与运行期边界

M4 保持总体 spec 的 top-level route 名称，不把 `physics/raycast`、`navigation/path/get` 或 `navigation/agent/target` 重命名为 `runtime/**`。M3 的 `runtime/**` manifest 继续严格固定为 35 条。

新增 `GdApiGameRoute`：它复用 `GdApiRuntimeRoute` 的 timeout、4 MiB 边界、错误映射、审计和 broker exactly-once 语义，但不要求公开 route 或 probe op 以 `runtime/` 开头。M4 game-side route 将公开路径映射为固定 `m4/...` probe op，例如：

- `physics/raycast` → `m4/physics/raycast`
- `navigation/path/get` → `m4/navigation/path/get`
- `navigation/agent/target` → `m4/navigation/agent/target`
- animation/audio 的运行期 preview/query 只在明确需要运行游戏的 route 使用同一 adapter。

`runtime_probe.gd` 只对固定的 `m4/...` allowlist 分发；不提供通用 eval、method call 或第二条 transport。所有 M4 route 仍使用 M3 的 broker、EngineDebugger 优先/file fallback、generation、deadline、4 MiB 与 disconnect cleanup。

## Fixture 与测试架构

`tests/fixtures/m4_project` 是唯一源 fixture，包含七个可在编辑器中打开的 domain scene、固定资源、`GdApiRuntimeProbe` autoload 和一个可运行的 domain host scene。每个 E2E test 从源 fixture 创建私有副本；源 fixture 的 digest 只用于验证未被污染。

编辑器 authoring 测试通过当前 `scene/open`、`scene/current/save`、`project/run`、`project/stop`、`gdapi/routes`、`command/doc` 和 fixture-only test plugin 工作。运行期测试显式：

1. 打开目标 domain scene；
2. `project/run` 运行该 scene；
3. 等待 broker connected 和至少一个 physics frame；
4. 调用 M4 game route；
5. `project/stop` 并断言 pending 为零、transport root 被移除。

M4 不复制 M2 的“每个 helper 自行启动 editor”行为。共享 helper 将在单个私有项目中拥有 editor，且每个测试独立复制项目，避免 UndoRedo、保存资源、AudioServer bus layout 与 bake 输出交叉污染。

## 编辑器服务与持久化

M4 服务放在已有的 `gdapi/addon/runtime/services/` 下，并复用 `GdApiNodeEditor`、`GdApiResourceEditor`、`GdApiEditAction`、`GdApiVariantCodec`、`GdApiPathGuard` 与 `GdApiAuditLog`。

- 场景节点及其内嵌、scene-local 资源的变更使用单个 `EditorUndoRedoManager` action；在 do/undo 中替换完整 duplicate resource，而不是依赖就地修改的内嵌 Resource。
- 文件资源、shader 文件、Audio bus layout、navigation bake 输出和显式保存都是 `undoable:false`，要求 `force:true` 覆盖、审计和失败后不留下目标文件。
- 所有可写 schema 在 mutation 前完整预校验；UI properties、Animation track type、shape type、joint type、resource type 和 shader uniform 采用固定 allowlist 或 Godot property-list 兼容检查，不能把任意字典直接 set 到 Object。

## Godot 4.7 专项约束

- TileMap 只支持 `TileMapLayer`。fixture 提供真实 `TileSetAtlasSource`，坐标限制为 `[-32768, 32767]`；cell mutation 后在查询前调用 `update_internals()` 或等待帧同步。
- AnimationTree 操作只接受 fixture 中固定的 `AnimationNodeStateMachine` resource 路径；state/transition 先校验图节点和 `AnimationNode` 类型，再使用完整 resource replacement 的 UndoRedo。
- M4 第一版 physics/navigation 只支持 2D。Physics raycast 使用 `World2D.direct_space_state` 与 `PhysicsRayQueryParameters2D`；navigation 使用目标 `NavigationRegion2D` 的实际 map RID，而不是字符串 `"default"`。3D route 参数返回 `not_supported`，不创建任何节点或资源。
- Navigation bake 必须等待 bake completion 或 deadline；失败、timeout、disconnect 时不保存输出且清理 callback。

## 任务顺序

1. M4 private fixture、editor harness 和 `GdApiGameRoute`/probe allowlist vertical slice。
2. Animation 与 TileMapLayer。
3. Material/Shader 与 Audio。
4. UI/Theme。
5. Physics 2D 与 Navigation 2D runtime verification。
6. 跨域 manifest、docs、persistence、full regression。

每个任务先运行一个真实 CLI RED test，再以最小实现转绿并提交。Task 1 的 vertical slice 必须证明 `physics/raycast` 经 broker→probe→reply，而 M3 的 runtime manifest 仍精确为 35 条。

## 验收

- 总体 spec 列出的 51 条 M4 public route 恰好存在、无 alias；每条有 summary、returns、参数化 route 有 example。
- 每域至少有 create/query/modify/save/reopen 测试；scene mutation 另有真实 undo/redo，文件 mutation 另有 force/audit/失败清理测试。
- runtime game route 证明在运行游戏中执行，且不新增 transport、不改变 M3 35-route manifest。
- TileMap、Physics 与 Navigation 的测试使用真实可同步的 2D fixture；未支持的 3D 输入稳定返回 `not_supported`。
- M4 E2E、完整 E2E、Rust 与 GDScript 验证均 exit 0，源 fixture digest 保持不变。
