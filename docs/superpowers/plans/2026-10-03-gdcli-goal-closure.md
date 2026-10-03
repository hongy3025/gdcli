# gdcli 目标收口 Implementation Plan（Android 除外）

> **For agentic workers:** REQUIRED SUB-SKILL: 使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务执行。步骤使用 `- [ ]` 复选框跟踪。

**Goal:** 按 [分支总目标与范围（Android 除外）](../specs/2026-10-03-gdcli-branch-goal-and-scope.md)，把 `feat/full-capability` 上仍未收口的非 Android 能力、已复现缺陷与验收基础设施缺陷全部修完，并以真实执行结果写收口报告。

**Architecture:** 保持现有 CLI → loopback HTTP → Rust GDExtension（极薄）→ 主线程 router → GDScript route 的结构；编辑器能力走 `runtime/services/*` + UndoRedo，运行期能力统一走 broker（EngineDebugger 优先 / file fallback）。本计划只做收口：范围落定、缺陷修复、验收基础设施硬化、可靠性补齐、全量验证。

**Tech Stack:** Godot 4.7.2（GDScript addon）、Rust（godot 0.5.4 / api-4-7）、Python pytest（uv）、gdformat/gdlint。

**范围变更记录:** 2026-10-03 起 Android 平台能力整体移出目标（见总目标文档第 2 节）。本计划不实现任何 Android 能力，只负责把 Android 从**目标、验收、测试门禁与文档声明**中移除。

**执行状态（2026-10-03）：**
- ✅ Task 1、Task 2 已完成并验证（manifest 25/7、桌面 PCK 导出用例通过）。
- 🔧 Task 2 执行期间发现并修复 `export/run` 的两个真实缺陷：子进程管道未排空导致导出阻塞至超时（Godot 管道缓冲约 4 KiB）；导出子进程加载 gdapi 插件后覆盖/删除父编辑器元数据。修复见 `gdapi/addon/runtime/services/export_service.gd` 与 CHANGELOG。
- ✅ Task 18 已执行：Android 路由/服务/测试/fixture 已从代码树删除，并在 CHANGELOG 记为 breaking change。
- ✅ 验证：`uv run pytest tests/e2e/ -m "not budget" -q` → **341 passed, 1 deselected, 0 failed（4:30）**；编辑器实际注册路由 196 → 193；`gdapi;tests;cli;scripts` 内已无 Android/ADB 引用。
- 🔧 验证过程中另修一处隔离缺陷：`default_bus_layout.tres` 属 Godot 自身维护（音频总线变化时自行写出/删除），此前被当作固定文件导致 M2/M4 隔离断言间歇失败；现已在 `tests/e2e/shared_fixture.is_tracked_project_file` 中统一排除，并让 `restore_file_state` 校验+重试、失败即报错（不再静默吞掉恢复失败）。
- ⚠️ 观察到一次运行时 harness 间歇失败（`reset_shared_fixture` 收到 409 `runtime is not connected`），未复现；归入 Task 11 继续跟踪。
- 🟡 Task 3 已完成（Android 声明移除 + README/手册修正：入口写法、runtime 表补齐、EngineDebugger 表述；TODO 收敛）。
- ✅ Task 4 已完成：`node/delete` 改为 do 只 `remove_child`、undo 恢复父节点与 index，并用 `add_undo_reference` 保活（按 Godot `scene_tree_dock.cpp` 的规范做法；未用 `add_do_reference`，因为它会对非 RefCounted 对象在丢弃 redo 栈时 `memdelete`）。`tests/e2e/m2/test_node_editor.py` → 14 passed。
- ✅ Task 6 已完成：`scene/list_open` 改用 `EditorInterface.get_open_scenes()`（稳定排序），`scene/close` 明确为「仅当前场景」并写入 `doc()`；测试覆盖第二个场景打开与关闭路径。`tests/e2e/m2/test_scene_editor.py` → 9 passed。
- 🔧 Task 5、Task 7 由并行任务执行中（Theme 数值、Navigation 真烘焙）。
- 🔧 Task 13/14/15 代码已完成，聚焦测试待跑：network/process 失败审计真实性、deferred registry 不再以「响应已发送」推断成功、bulk `plan_hash` 绑定全部参数 + 回滚/recover 失败可见、replace 逐文件写入校验、uid/repair 回滚、项目配置持久化与保存失败回滚。
- ⬜ Task 8–12、16、17 未开始（Task 8/9 为验收补齐，Task 10–12 为验收基础设施，Task 16/17 为全量验证与收口）。

**收口后追加项（2026-10-03 第二轮，用户确认 1~5 全做）：**
- ✅ 推送分支到 origin。
- ✅ EngineDebugger 数据面验收：headless 与真实 GUI 会话实测 `transport=engine_debugger`（协议 v2、PNG 截图、输入生效、stop 正常）；新增 `GDAPI_E2E_TRANSPORT=engine_debugger` 可重复入口（m3 status+nodes 29 passed）。
- ✅ harness 稳定性：`attach_game` 握手失败打印 status/运行期目录/编辑器 console 诊断；m2+m4 undo 桥与 m3 输入等待统一放宽（只影响失败路径耗时）。
- ✅ 外部对等复核：新增 `docs/reports/2026-10-03-external-parity-comparison.md`（27 域：13 等价/11 部分/3 缺失）。
- ✅ 审计与错误码统一：router 统一补记 mutation 审计（不重复）；`method_not_allowed` 收进 `error_codes.gd`。
- 验证：m2+m3 status+m6 contract 84 passed；预算验收 1 passed（313s，嵌套全量绿色、`GODOT_EDITOR_STARTS=1`）。

## Global Constraints

1. 验证基线 Godot `D:\app\devel\Godot\v4.7.2\godot_console.exe`；支持范围 4.7.x 不变；不提高 `compatibility_minimum`。
2. 不恢复 policy/force 门禁；保留硬上限与审计（不含 secret）。
3. Android 不在目标内：不新增 Android 需求、不申请 Android 环境、不为 Android 保留 skip 依据。
4. 只把**实际执行并通过**的结果写入报告；环境性跳过必须写明原因，且不得与「功能未实现」混写。
5. 每个任务结束跑验证：GDScript 改动先过 `python scripts/format-gd.py`、`python scripts/format-gd.py --check` 与 `gdlint <改动文件>`（缺工具先 `uv tool install gdtoolkit`）；Rust 改动跑 `cargo fmt --check`、`cargo test --workspace`；行为改动用真实编辑器 E2E。
6. 历史报告与 SDD 记录保留为历史证据，不回改其数字；范围变更以总目标文档 + 本计划表达。
7. 每个修复都必须带一条**能被真实行为区分**的回归断言；不得用「文件存在」「返回值非空」代替行为验证。

## 前置条件

- [ ] `Godot 4.7.2` 可用；`uv`、`cargo`、`gdformat`、`gdlint` 在 PATH。
- [ ] 已知实测结论：桌面 PCK 导出（`--export-pack`）**不需要**导出模板即可产出产物（4.7.2 实测，1472B 探针产物）；本机 `export_templates` 为空不影响 `export/run` 的桌面预设验收。
- [ ] 已知实测结论：`tests/fixtures/e2e_project/export_presets.cfg` 中 `M5 PCK` 预设 `platform="Windows"` 不是合法平台名，Godot 4.7.2 直接忽略该预设（`Invalid export preset name: M5 PCK`）；这是该用例即便解除 skip 也必然失败的根因。

---

## Phase A：范围落定（Android 移出）

### Task 1: 里程碑清单与 Android 解耦

**Files**
- Modify: `tests/e2e/route_manifests.py`（`M5_ROUTES`、`M6_ROUTES`、self-assert）
- Modify: `tests/e2e/m5/test_m5_smoke.py`（Android serial 用例）
- Modify: `tests/e2e/m6/test_bulk_deploy.py`
- Modify: `tests/e2e/test_unified_fixture_contract.py`（必需路径中的 Android fixture 项）
- Modify: `tests/e2e/shared_fixture.py`、`tests/e2e/test_collection_order.py`（被删测试的桶排序引用）

**Steps**
- [x] `M5_ROUTES` 移除 `export/android/devices`、`export/android/deploy`（27 → 25）；`M6_ROUTES` 移除 `export/android/deploy_many`（8 → 7）；同步 self-assert 数量。
- [x] ~~新增 `OUT_OF_SCOPE_ROUTES`~~ 不适用：Android 实现已在 Task 18 中整体删除，直接移除清单条目即可（不需要"保留但排除"机制）。
- [x] 删除 `test_m5_smoke.py` 中依赖 Android 路由的用例；删除 `tests/e2e/m6/test_bulk_deploy.py`（Android 专用，且 `command_doc` 未导入、解 skip 即 NameError）。
- [x] 从 `test_unified_fixture_contract.py` 必需路径移除 Android 专用 fixture（`tests/test_android_bridge.gd`）；同时从 `test_gdscript_units.py` 移除已删除的 `test_bulk_deploy_service.gd` 单元套件。
- [x] 同步被删测试文件在桶排序中的条目（`m5/test_export.py` 取代 `m5/test_export_android.py`，移除 `m6/test_bulk_deploy.py`）。

**Verification**
- [x] `uv run pytest tests/e2e/test_unified_fixture_contract.py tests/e2e/test_collection_order.py -q`
- [x] `uv run pytest tests/e2e/m5/test_m5_smoke.py tests/e2e/m6/test_m6_contract.py -q`（需编辑器）
- [x] `python -c "import sys; sys.path.insert(0,'tests'); import e2e.route_manifests as m; print(len(m.M5_ROUTES), len(m.M6_ROUTES))"` → `25 7`

### Task 2: 桌面导出验收恢复（PCK）

**Files**
- Create: `tests/e2e/m5/test_export.py`
- Delete: `tests/e2e/m5/test_export_android.py`
- Modify: `tests/fixtures/e2e_project/export_presets.cfg`

**Steps**
- [x] 修正 `M5 PCK` 预设为合法平台 `platform="Windows Desktop"`；移除 `M5 Android Missing Template` 预设（唯一用途是 Android 验收）。
- [x] `test_export.py`：`export/presets` 必须列出 `M5 PCK` 且平台为 `Windows Desktop`；`export/run` 产出 `res://build/m5.pck`，响应的 `size`/`sha256` 必须与落盘文件的真实摘要一致（不用「非空」代替）。
- [x] 失败路径：`user://` 输出路径返回 `invalid_path`、未知预设返回 `not_found`，两者均断言无残留产物；同一路径重复导出成功覆盖。
- [x] 删除旧模块与所有以 Android 为理由的 `pytest.mark.skip`。

**Verification**
- [x] `uv run pytest tests/e2e/m5/test_export.py -q`（真实编辑器；CLI 超时 180s）

### Task 3: 用户文档与 backlog 与范围一致

**Files**
- Modify: `README.md`（`### M5 项目、诊断与发布` 段、M6 高风险能力清单段）
- Modify: `docs/gdcli/gdcli-exec.md`（export 路由表、`command/list` 用法说明）
- Modify: `docs/todos/TODO.md`

**Steps**
- [x] README/手册移除 Android 能力声明（ADB、serial、设备部署），保留一句范围说明并链接总目标文档；手册的 `export/android/*` 路由行已删除。
- [x] 修正其余已知文档错误：入口改为 `gdcli exec command/list` / `gdcli exec command/doc <route>`；runtime 表补齐 `runtime/node/{create,duplicate,rename}`（7 → 10）；「所有 runtime 请求均由 EngineDebugger 承载」改为「EngineDebugger 优先、file fallback」；手册的 `command/list` 位置参数描述已修正。
- [x] `docs/todos/TODO.md` 保持为指向本计划的短文件，不再保留已取消或已完成条目。

**Verification**
- [x] `rg -n "Android|ADB" README.md docs/gdcli docs/todos` 只命中范围说明行
- [x] `gdcli command list` → exit 2（旧写法），`gdcli exec command/list --project tests/fixtures/e2e_project` → 正常进入执行路径（无编辑器时为 exit 3）

---

## Phase B：已复现缺陷与未落实语义

### Task 4: `node/delete` 的 UndoRedo 真实可用

**Problem（已复现，2026-10-03）:** `node/delete` 返回 `undoable:true`，但跨帧 undo 后 `node/get` 仍返回 `not_found`——`do` 阶段 `queue_free` 释放了对象，`undo` 无法恢复。

**Files**
- Modify: `gdapi/addon/runtime/services/node_editor.gd`（`delete_node`）
- Modify: `tests/e2e/m2/test_node_editor.py`

**Steps**
- [x] 改用编辑器惯用模式：`do` 只 `remove_child`（记录原 `index`），`undo` 恢复 `add_child` + `set_owner` + 原 `index`。**偏差（有据）**：只用 `add_undo_reference(node)`，不用 `add_do_reference`——后者会在丢弃 redo 栈时对非 RefCounted 对象 `memdelete`，把 undo 已放回场景的节点删掉；Godot `editor/scene_tree_dock.cpp` 的删除实现也是只用 undo reference。
- [x] 回归断言（真实编辑器、跨帧）：`create → delete → undo` 后节点存在且父节点/`index` 正确；`redo` 后再次消失；连续两步 delete/undo/redo 无孤儿与错误日志。

**Verification**
- [x] `uv run pytest tests/e2e/m2/test_node_editor.py -q` → 14 passed

### Task 5: Theme 路由可用与可验收

**Problem（已复现，2026-10-03）:** `theme/constant/set`、`theme/font_size/set` 的文档示例 `value:4` / `value:16` 均返回 `400 invalid_param: value must be an int`。

**Files**
- Modify: `gdapi/addon/runtime/services/theme_editor.gd`
- Create: `tests/e2e/m4/test_theme.py`

**Steps**
- [x] 数值处理：新增 `_int_value()`，接受 `TYPE_INT` 与有限的整数值浮点（`4`/`4.0`/`-4.0`），拒绝非整数（`4.5`）、NaN/INF 与非数值，错误码保持 `invalid_param` 且 message 可诊断；不限制取值范围（负数常量合法）。
- [x] 真实行为测试：`tests/e2e/m4/test_theme.py` 覆盖 create → constant/font_size/color/stylebox 写入 → `resource/info` 重新加载读回；非整数拒绝后文件字节不变。
- [x] 断言 `undoable:false` 与 `gdapi/audit/list` 中五个 route 的审计记录。

**Verification**
- [x] `uv run pytest tests/e2e/m4/test_theme.py -q` → 4 passed（临时还原旧判断后 4 failed，确认用例能区分修复）

### Task 6: 场景打开集合与关闭语义

**Problem:** `scene/list_open` 只返回当前场景，`scene/close` 仅支持当前场景，但命名与文档暗示可操作多个打开场景。

**Files**
- Modify: `gdapi/addon/runtime/services/scene_editor.gd`（`close_scene`、`list_open_scenes`）
- Modify: `tests/e2e/m2/test_scene_editor.py`

**Steps**
- [x] `list_open` 使用 `EditorInterface.get_open_scenes()` 返回全部打开场景（过滤空路径 + 排序，稳定顺序）。
- [x] `close`：Godot 4.7 无「关闭指定非当前场景」API，因此明确收窄为「仅当前场景」，并写入服务注释与路由 `doc()`。
- [x] 测试：打开第二个场景后 `list_open` 必须包含两者，关闭后集合更新。

**Verification**
- [x] `uv run pytest tests/e2e/m2/test_scene_editor.py -q` → 9 passed

### Task 7: Navigation bake 真实烘焙

**Problem（源码确认）:** `navigation/mesh/bake` 只 `duplicate` 现有 `NavigationPolygon` 后保存，未调用烘焙，也没有完成等待/超时/失败清理。

**Files**
- Modify: `gdapi/addon/runtime/services/navigation_editor.gd`
- Modify: `tests/e2e/m4/test_navigation.py`

**Steps**
- [x] 使用 Godot 烘焙 API 真正烘焙：深拷贝区域 `NavigationPolygon`（含 `outlines`）→ `NavigationServer2D.parse_source_geometry_data` → `bake_from_source_geometry_data` → 以 `is_baking_navigation_polygon` 等待（10s deadline）→ 仅在 `get_polygon_count() > 0` 时保存；失败/超时删除输出与 `.uid`，不留部分结果。
- [x] 测试能区分「真烘焙」与「复制旧值」：源几何 4 顶点/1 多边形 → 烘焙后 8 顶点/4 多边形；缩放障碍物后重新烘焙得到 3 多边形；非法参数与空区域不产生输出文件。
- [x] `navigation/region/list` 改为稳定字段 `{path, class, vertex_count, polygon_count}`，路由 `doc()` 同步更新。

**Verification**
- [x] `uv run pytest tests/e2e/m4/test_navigation.py -q` → 5 passed；`tests/e2e/m4` 整体 56 passed（含 game bridge 与其它域，确认 fixture 变更无连锁影响）

### Task 8: M2 验收补齐（持久化与类型往返）

**Problem:** 现有 M2 行为断言偏弱：信号/分组只在同一内存场景内查询，未做保存重开；typed 属性只验证 Vector2；`resource/assign` 测试实际未覆盖 assign；脚本 attach 未重开验证。

**Files**
- Modify: `tests/e2e/m2/test_signal_group_routes.py`、`tests/e2e/m2/test_resource_routes.py`、`tests/e2e/m2/test_script_routes.py`
- Modify: `tests/fixture_project/tests/test_variant_codec.gd`（如需）

**Steps**
- [x] 信号连接与分组：connect + add → `scene/current/save` → `scene/close` + `scene/open` → 连接（`flags & CONNECT_PERSIST`）与 persistent 分组仍在；disconnect/remove → 保存重开 → 消失。
- [x] 属性往返：Color（`modulate`）、NodePath（`AnimationPlayer.root_node`）、Resource（`material`）各一条 set → get → 保存重开读回。
- [x] `resource/assign` 真实赋值并在重开后仍生效；`script/attach`/`detach` 用「脚本声明的信号出现在 `node/signal/list`」+ 保存后 `.tscn` 的 `script = ExtResource(...)` 行断言（`node/property/get` 按设计拒绝读取 `script`）。

**Verification**
- [x] `uv run pytest tests/e2e/m2 -q` → 63 passed
- 🔧 验收补齐暴露并已修复的真实不一致：`resource/assign` 未校验目标属性是否为资源槽位（`doc()` 承诺支持），且既有拒绝用例是因资源文件不存在而"误绿"。现已在 `resource_editor.assign` 增加 `_is_resource_property` 校验，并把该用例改为使用项目内真实资源 + 非资源属性，断言 `invalid_param`。

### Task 9: M4 弱验收补齐（Audio / Physics / Animation / TileMap）

**Problem:** M4 路由齐全，但 Audio 的 play/stop 未验证运行期语义（当前对编辑器节点操作并直接宣称 playing）、Physics 只有 body/shape 的 undoable 断言、Animation 的 track/key 重开未读回、TileMap clear 未验证清空与撤销。

**Files**
- Modify: `gdapi/addon/runtime/services/audio_editor.gd`（运行期 play/stop 语义）
- Modify: `tests/e2e/m4/test_audio.py`、`test_physics.py`、`test_animation.py`、`test_tilemap.py`

**Steps**
- [x] Audio：`play`/`stop` 改为回读节点真实的 `AudioStreamPlayer.playing`，`doc()` 明确「作用于编辑器当前场景、非运行中游戏」；测试断言 初始 false → play 后 true → stop 后 false。
- [x] Physics：`physics/layer/set` 写入后读回 `collision_layer`，undo 后恢复；`physics/joint/create` 读回关节类型与参数，undo 后节点消失。
- [x] Animation：track/key → 保存重开读回（含 `.tscn` 序列化断言）；`play`/`stop` 用 `current_animation` 断言（Godot 4.7.2 的 AnimationPlayer 无 `playing` 属性，已用 ClassDB 核实）。
- [x] TileMap：`tilemap/layer/clear` 后 `used_cells` 为空，undo 后恢复。

**Verification**
- [x] `uv run pytest tests/e2e/m4 -q` → 42 passed（连续两次）
- 🔧 暴露并已修复的真实不一致：`audio/player/create` 返回编辑器内部路径（`/root/@EditorNode@...`），无法被其它路由使用 → 现返回 `/root/<场景根>/...`；`physics/*` 只接受场景根相对路径而 `doc()` 示例是绝对路径 → `_find` 现统一规范化三种写法并回传绝对路径。
- ⚠️ 观察到一次既有的 `test_tilemap_cell_set_is_undoable_and_persists` 偶发失败（`history.undo()` 返回 false），复跑未再现，继续跟踪。

---

## Phase C：验收基础设施

### Task 10: 单编辑器 fixture 身份统一

**Problem（已实测）:** `e2e.shared_fixture` 与 `tests.e2e.shared_fixture` 是两个模块（模块对象、`EDITOR_START_COUNTER`、`e2e_editor` fixture 均不同）；`pytest --collect-only` 显示不同测试文件实际选中两套 `e2e_editor` 定义，各自计数为 1 不能证明全会话只启动一次编辑器。

**Files**
- Modify: `tests/e2e/conftest.py`（导入）
- Modify: `tests/e2e/test_shared_editor_contract.py`、`tests/e2e/test_shared_editor_lifecycle.py`

**Steps**
- [x] 统一导入路径：`test_shared_editor_contract.py` / `test_shared_editor_lifecycle.py` 改为 `e2e.shared_fixture`，消除「同一文件两条模块路径」的两套定义。
- [x] **真正根因（本轮抓到）**：把 fixture 函数 `from e2e.shared_fixture import e2e_editor` 导入**测试模块**会在该模块再注册一份定义，pytest 为它单独建立一次会话级 fixture —— 实测同一会话启动了 **2 个编辑器**（两个 pid、调用栈相同）。修法：测试模块只 `import e2e.shared_fixture as shared_fixture` 读取计数，fixture 一律通过 conftest re-export 按名字请求。
- [x] session teardown 断言真实启动数 == 1 并输出 `GODOT_EDITOR_STARTS=<n>`；失败时打印 pids/事件时间线/调用栈；contract 测试新增「shared_fixture 未被重复导入」的回归断言。
- [x] 单元级 mock 用例改为深拷贝快照/还原全局计数（含 `pids`、`callers`），避免污染会话断言。

**Verification**
- [x] `uv run pytest tests/e2e/test_shared_editor_contract.py -q`（守卫用例通过）
- [x] 全量运行 `GODOT_EDITOR_STARTS=1`（此前为 2，见 Task 16 运行 C）
- [ ] `uv run pytest tests/e2e/ -m "not budget" -q -s` 输出恰好一个启动行

### Task 11: 每测试隔离与恢复硬化

**Files**
- Modify: `tests/e2e/shared_fixture.py`（`restore_file_state`/`snapshot_files`、`reset_shared_state`、`teardown_environment`）
- Modify: `tests/e2e/m6/conftest.py`、`tests/e2e/m6/test_bulk_files.py`

**Steps**
- [x] `restore_file_state` 现在写回后校验并在失败时重试（6 次 × 0.1s），仍不一致即报错，不再静默吞掉；`is_tracked_project_file` 明确记录三类有意例外（`.godot/`、`addons/gdapi/`、`project.godot`）并在 docstring 说明原因。
- [x] `teardown_environment` 不再 `suppress` 重置失败：先停止编辑器，再把失败作为会话级错误抛出。
- [x] M6 接入每测试文件恢复（`isolated_m6_files` autouse，断言 added/removed/changed 明细）；`test_bulk_files` 的删除/替换与 `inject_apply_failure` 留下的探针文件都会被恢复。**取舍**：M6 只恢复文件、不停止运行中的游戏，避免破坏模块级 running-game fixture。
- [x] 断言可诊断：M2/M4/M6 的隔离断言都会列出具体变化路径；`_remove_tree` 对 Windows 句柄释放做有界重试。

**Verification**
- [x] `uv run pytest tests/e2e/m6 -q`、`uv run pytest tests/e2e/m2 -q`（在 Task 16 全量运行中一并验证；切片全绿）
- [x] 后续 T1 已落地真实握手修复：hello 文件发布失败不再误标记为“已发送”；真实 Godot 故障注入确认同一 generation 内恢复连接，且未放宽超时/增加 harness 重启。回归与稳定性验收证据见 [T1](../../todos/2026-10-03-open-issues.md)；原全量失败缺少发布结果，保留历史记录而不推断其具体 I/O 来源。
- ⚠️ 未解决：`gdapi_test` undo 桥在重负载下可能超过 2s（观测 1 次 `plugin never produced a result`）。

### Task 12: 预算与收集顺序收尾

**Files**
- Modify: `pyproject.toml`、`tests/e2e/conftest.py`、`tests/e2e/test_full_suite_budget.py`、`tests/e2e/test_collection_order.py`

**Steps**
- [x] `pyproject.toml` 的 `addopts` 改为 `-v -m 'not budget'`：默认真的排除 budget（实测 `--collect-only` 为 360/361，1 deselected），显式 `-m budget` 仍可收集并运行。
- [x] 排序契约与实际一致：`m3/test_runtime_status.py`（module-scoped lifecycle）落在 bucket 2，先于 bucket 3 的数据面测试；`test_collection_order.py` 已有对应用例。
- [x] 预算测试测量嵌套 pytest 报告的 walltime（含编辑器启动）并断言 `≤ 360s`，同时要求 `GODOT_EDITOR_STARTS=1`。

**Verification**
- [x] `uv run pytest tests/e2e --collect-only -q` → 1 deselected（budget）
- [x] `uv run pytest tests/e2e/test_full_suite_budget.py -m budget --collect-only -q` → 1 collected
- [ ] `uv run pytest tests/e2e/test_full_suite_budget.py -m budget -v`（实际 ≤360s 验收在 Task 16 执行）

---

## Phase D：可靠性收口

### Task 13: 失败审计真实性（network / process）

**Files**
- Modify: `gdapi/addon/routes/network/http_request.gd`
- Modify: `gdapi/addon/routes/process/run.gd`
- Modify: `gdapi/addon/runtime/deferred_task_registry.gd`（`_task_outcome`）

**Steps**
- [x] `network/http_request` 注册 deferred task 时传入 `state`，registry 不再以「response 已发送」推断成功；无 outcome 时按 `conflict` 失败处理（新增 GDScript 单元用例覆盖两种情形）。
- [x] spawn 失败、注册失败等早退路径补齐失败审计（`network/http_request`、`process/run`）。
- [x] 故障注入测试：网络超时后审计为 `ok:false` + `code=timeout`；进程 spawn 失败后审计含失败 code。

**Verification**
- [x] `uv run pytest tests/e2e/m6/test_network_request.py tests/e2e/m6/test_process_run.py tests/e2e/m6/test_m6_contract.py -q` → 全绿（与 bulk、m5 配置用例合并运行 35 passed）

### Task 14: 批量事务完整性

**Files**
- Modify: `gdapi/addon/runtime/services/bulk_file_service.gd`
- Modify: `tests/e2e/m6/test_bulk_files.py`

**Steps**
- [x] `plan_hash` 绑定 `{root, find, replace, operations}`（此前只绑 `{path, sha256, replacements}`）；测试断言「同一批文件、不同 replace」产生不同 hash，且旧 hash 驱动新替换返回 `conflict`。
- [x] `_rollback_replace`/`_rollback_manifest` 返回失败列表；replace/delete 的回滚与 recover 的中途失败都会检查每步结果，并把 `details.rollback_failures` 返回给调用方（三个 batch route 现在都会转发 `details`）。
- [x] replace 在扫描阶段即按 write 模式校验每个目标路径（保护 `addons/gdapi/`、`.godot/`），命中即 `permission_denied`。
- [x] 测试：recover 注入中途失败后两个文件都保持未恢复（无部分状态），`details.rollback_failures` 为空；复用既有 `inject_apply_failure` 之外新增 `inject_recover_failure` 探针（测试结束清理）。

**Verification**
- [x] `uv run pytest tests/e2e/m6/test_bulk_files.py -q` → 7 passed

### Task 15: 持久化与 UID 失败路径

**Files**
- Modify: `gdapi/addon/runtime/services/uid_repair.gd`
- Modify: `gdapi/addon/runtime/services/project_config.gd`
- Modify: `tests/e2e/m5/test_uid_repair.py`、`tests/e2e/m5/test_snapshot_restore.py`

**Steps**
- [x] `uid/repair`：dry-run 不写文件（新增 `.uid` 摘要断言）；apply 部分失败时回滚已写入 UID，并在 `details` 返回 `failed_path`/`applied`/`rollback_failures`（无法还原的「原先缺失 UID」项会被列出）。
- [x] 项目配置：`project/input_map/*` 现在把 InputMap 状态写回 `ProjectSettings` 的 `input/<action>`（否则重载即丢），`project/autoload/*` 同理；保存失败时通过 restore 回调还原 `ProjectSettings` 与 InputMap 内存状态，并记录失败审计。
- [x] 测试：新增「InputMap/Autoload 变更写入 `project.godot`」的持久化断言；新增只读 `project.godot` / 只读目标资源的失败路径用例（断言报错、内存回滚、文件不变、`uid/repair` 失败后 dry-run 与失败前完全一致）。
- [x] 保存失败注入问题已解决（不再依赖注入）：路由/服务现在**回读校验落盘结果**——Godot 在目标不可写时会静默返回 OK，服务将其判定为失败并执行回滚；因此回滚分支由只读文件这种真实手段覆盖，无需假探针。

**Verification**
- [x] `uv run pytest tests/e2e/m5 -q` → 18 passed（含 uid/repair 与 project_config 用例）

---

## Phase E：全量验证与收口

### Task 16: 门禁与全量套件

- [x] `python scripts/format-gd.py` / `--check` → 556 个 GDScript 通过；`gdlint`（全部改动文件）→ Success: no problems found
- [x] `cargo fmt --check` → 通过；`cargo clippy --workspace --all-targets -- -D warnings` → exit 0
- [x] `cargo test --workspace` → 202 passed, 0 failed（gdapi 39 + 4 + 6；gdcli 101 + 8 + 20 + 4 + 15 + 5）
- [x] `uv run pytest tests/e2e -q -s`（全量非预算，共 3 次独立运行 + 1 次预算内嵌套运行）：
  - 运行 A：`367 passed, 2 failed, 2 errors`。失败为：新增 M6 隔离断言抓到 m5 `uid/repair` 的跨模块文件泄漏（`fixtures/*.tres` 被写入 uid 后未被恢复）；以及会话 teardown 的重置失败传播使两个 mock 单元用例失败。两者均已修复（m5 收尾恢复共享基线；`teardown_environment(reset=False)` 供 mock 用例使用）。
  - 运行 B：`354 passed, 1 failed, 15 errors`。失败为 1 次 undo 桥等待超时（`gdapi_test plugin never produced a result`，2s 超时偏紧，已放宽到 10s）+ 1 次模块级运行时握手失败级联（`m3_running` 的 probe 60s 未连接，导致同模块 14 个用例 error）；单独运行 `tests/e2e/m3` 为 **123 passed**，属偶发。
  - 运行 C：`369 passed, 1 error`。会话级断言指出 `GODOT_EDITOR_STARTS=2`：测试模块 `from e2e.shared_fixture import e2e_editor` 造成 fixture 重复定义，**真的启动了第二个编辑器** → 修复（只导入模块 + 经 conftest re-export 请求 fixture）。
  - 运行 D（预算内嵌套）：**全绿**，`GODOT_EDITOR_STARTS=1`。
  - 运行 E：`368 passed, 1 failed`（`test_input_sequence_over_five_seconds_honors_explicit_timeout`，`wait_for` 5s 在重负载下偏紧 → 已放宽到 15s 并单跑验证该文件 32 passed）；`GODOT_EDITOR_STARTS=1`。
- [x] `uv run pytest tests/e2e/test_full_suite_budget.py -m budget -v` → **1 passed in 301s**：嵌套全量绿色、`GODOT_EDITOR_STARTS=1`、嵌套 walltime ≤ 360s。
- [x] `uv run pytest tests/e2e/m3/test_runtime_status.py -v` → 5 passed（真实编辑器 run/connect/stop 两轮生命周期）

### Task 17: 收口报告与文档收尾

**Files**
- Create: `docs/reports/2026-10-XX-gdcli-goal-closure.md`
- Modify: `README.md`、`docs/gdcli/*`、`docs/todos/TODO.md`、`CHANGELOG.md`

**Steps**
- [x] 报告 `docs/reports/2026-10-03-gdcli-goal-closure.md` 只记录实际执行的命令与结果（含 5 次全量运行、门禁、切片、预算），并逐条对照总目标验收标准。
- [x] 明确列出 Android 已移出目标（附范围文档链接），以及仍未覆盖项（保存失败注入受限、运行时 harness 偶发、GUI/EngineDebugger 数据面）及原因。
- [x] 同步 README/手册 route 表与范围说明；TODO 收敛为指向本计划；CHANGELOG 记录 breaking changes、Fixes 与 Maintenance。

### Task 18（已执行 2026-10-03）: 删除 Android 实现

- [x] 删除 `gdapi/addon/routes/export/android/`（3 条路由 + `.uid`）、`runtime/services/android_bridge.gd`、`bulk_deploy_service.gd`（含 `.uid`），清理 `export_service.gd` 的 Android 分支（`--export-debug` 分支与 `_template_available`）。
- [x] 删除 Android 专用测试与 fixture：`tests/e2e/m5/test_export_android.py`、`tests/e2e/m6/test_bulk_deploy.py`、两个 `test_android_bridge.gd`、两个 `test_bulk_deploy_service.gd`、两个 fixture 的 Android 导出预设。
- [x] 跑 GDScript 门禁（gdformat/`--check`/gdlint）与 Python 语法检查；Android 专项 E2E 通过。

---

## 完成判据

- 总目标第 5.1–5.3 节全部验收标准有可复现证据；
- 全量非预算 E2E、预算测试、Rust 门禁、GDScript 门禁全部通过，且不存在 Android 相关 skip；
- 收口报告写明实际执行结果，未执行项显式标注原因；
- 仓库内不再有把 Android 当作待验收目标的文档或测试。
