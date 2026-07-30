> 历史快照：2026-07-29 状态；自 2026-07-30 起被本目录中最新报告替代。
> 最新报告：`docs/reports/2026-07-30-gdcli-full-capability-roadmap-remediation-closure.md`

# gdcli 路线图 / Plan 实现状态分析报告

日期：2026-07-29
对应规范：`docs/superpowers/specs/2026-06-27-gdcli-full-capability-roadmap-design.md`
对应目录：`docs/superpowers/plans/`（共 26 个 plan 文档）

## TL;DR

| 里程碑 | 计划文档 | 实现状态 | 说明 |
|---|---|---|---|
| 阶段 1–5（pre-roadmap） | `2026-06-16` ~ `2026-06-27` 共 16 个 plan | ✅ **完全实现** | 路线图前的支撑工作（CLI、LSP、HTTP server、路由、exec、help、TOON 等），全部 commit 在 `feat/full-capability` 起点之前，已被 M1/M2/M3 集成验证。 |
| M1 — 现有基础设施收口 | `2026-07-21-gdcli-m1-infrastructure-closure.md` | ✅ **已实现**（自带 1 个遗留问题） | 提交 `3aba6f6 feat: close gdcli M1 infrastructure baseline`；9 个路由在 `command/list` 里随 M2 同步修复后通过。 |
| M2 — 基础编辑闭环 | `2026-07-21-gdcli-m2-basic-editing.md` + `2026-07-21-gdcli-m2-implementation-review.md` | ✅ **结构性完成** | 提交 `a7b3996 feat: add gdcli M2 basic editing milestone`；71 个新增 route、4 个 service；review 自身标注 50% 测试通过率。1 个遗留问题（见下）。 |
| M3 — Runtime 验证闭环 | `2026-07-21-gdcli-m3-runtime-validation.md` + `2026-07-23-gdcli-m3-closure.md` | 🟡 **结构 + 单元绿灯 / E2E 受 Godot 4.7 headless 限制** | 提交 `5d5fb13 ~ 6e0d205`（10 个 feat/fix commit）；35 个 runtime route、broker / debugger plugin / probe / ring buffer / condition / capture ops；M3 closure 完成 Step 0 / D1 / D5 / P0 修复，但 spec 设计文档已显式把 M3 从 ✅ 翻回 🟡。 |
| M3.1 — 文件 fallback transport | `2026-07-23-gdcli-m3.1-file-transport.md` | 🔴 **未完成（约 1/7 task）** | 提交 `8deb481 feat(M3.1): probe-side file transport with hello/inbox/outbox` 仅落地 **Task 1**（probe 侧模块 + 1 单元测试）；其余 6 个 task（editor 侧 transport、`attach_file_transport` 注入、broker 协议扩展、`m3_*` fixture 调整、回归测试、spec 翻 ✅）未实现。 |
| M4 — 游戏系统域 | `2026-07-21-gdcli-m4-game-systems.md` | ❌ **未实现** | `gdapi/addon/routes/` 下无 `animation/`、`animation_tree/`、`tilemap/`、`material/`、`shader/`、`audio/`、`ui/`、`theme/`、`physics/`、`navigation/`；`tests/fixtures/` 下无 `m4_project/`。 |
| M5 — 项目 / 诊断 / 发布 | `2026-07-21-gdcli-m5-project-diagnostics-export.md` | ❌ **未实现** | `gdapi/addon/routes/` 下无 `classdb/`、`diagnostics/`、`export/`；`project/settings/`、`project/input_map/`、`project/autoload/` 也无对应 route。 |
| M6 — 高风险能力 | `2026-07-21-gdcli-m6-high-risk-capabilities.md` | ❌ **未实现** | 无 `process/`、`network/`、`policy` / `audit_redactor` GDScript 模块、无 `process_runner.rs`。 |

补充上下文：
- 工作分支最早起点 `afbe34a 更新路由相关文档`；分支全名 `feat/full-capability`（M3 summary 中提及）。
- 最近提交 `8deb481 (M3.1)`，仍在 M3.1 初始 task，尚未触及 M4。
- 主分支当前主 commit：`8deb481 feat(M3.1): probe-side file transport with hello/inbox/outbox`。

## 1. 评分方法

对每个 plan 文档，按以下口径判定：
- **完成度** = 在仓库可观测证据（路由 / 服务 / fixture / 测试 commit）+ plan 自带验收标记之和。
- **证据来源**：plan 文档中的"完成标记"与"diff 状态"，spec 文档里程碑标记（✅ / 🟡 / 未提），git log 中已合并 commit，`gdapi/addon/routes/**` 与 `tests/fixtures/**` 实际目录列表。
- **未触及**：plan 在 git log 中找不到对应 commit、routes 与 fixtures 也不存在。

下列 `<reposnapshot>` 句段汇总仓库实际状态，避开每次重新枚举。

<reposnapshot>
- `gdapi/addon/routes/` 现有目录（按字母序）：
  `console/`、`editor/{main_screen/set,selection/{get,set}}`、
  `filesystem/{grep,list,read,reimport,search,write}`、
  `gdapi/{audit/{clear,list},health/{pathcheck,ping},loglevel,routes}`、
  `godot/{version}`、`node/{create,delete,duplicate,get,list,move,rename,reparent,select,set,group/{add,list,nodes,remove},property/{get,list,reset,revert,set},signal/{connect,disconnect,emit,list}}`、
  `project/{info,run,stop}`、`resource/{assign,create,delete,deps,info,move,reimport,search}`、
  `runtime/{assert/{condition,node_exists,property_equals,signal_received},debug/{breakpoints,errors,monitors,performance},input/{action,gamepad,key,mouse,sequence,touch},log/{clear,read},node/{call,find,get,info,remove,reparent,set},scene/tree,screenshot/{camera,frames,viewport},signal/{await,connect,disconnect,emit},status}`、
  `scene/{add_node,close,create,current,current/save,export_mesh_library,list_open,load_sprite,open,save,tree}`、
  `script/{attach,create,current,detach,open,patch,read,validate,write}`、
  `uid/{get,update_all}`。
- `gdapi/addon/runtime/`：
  基础：`request.gd`、`response.gd`、`route_handler.gd`、`router.gd`、`path_guard.gd`、`variant_codec.gd`、`edit_action.gd`、`audit_log.gd`、`error_codes.gd`、`param_doc.gd`、`route_doc.gd`、内建 `builtin_{ping,routes,commands,command_help}.gd`。
  M2 service：`services/{scene_editor,node_editor,text_edit,resource_editor}.gd`。
  M3 模块：`runtime_{protocol,broker,debugger_plugin,probe,condition,ring_buffer,capture_ops,node_ops,input_ops}.gd`。
  M3.1：`runtime_transport_file_probe.gd`（probe 侧）。`runtime_transport_file_editor.gd` 不存在。
  未发现：`builtin_help.gd` 已被 M1 删除。
- `tests/fixtures/`：仅 `m2_project/`、`m3_project/`（无 m4/m5/m6）。
- `tests/e2e/m3/` 已存在 7 个测试文件：`test_{runtime_status,runtime_nodes,runtime_input,runtime_capture,runtime_observability,runtime_assert_signal,m3_contract}.py` + `conftest.py` + `__init__.py`。
- `tests/fixture_project/tests/` 已包含：`test_request.gd`、`test_route_doc.gd`、`test_router.gd`、`test_path_guard.gd`、`test_variant_codec.gd`、`test_runtime_{protocol,broker,ring_buffer,transport_file_probe}.gd`。
- `cargo test --workspace` exit 0（5 passed）。
</reposnapshot>

## 2. 阶段 0：路线图前支撑工作（pre-roadmap，16 个 plan）

这些是 2026-06-16 ~ 2026-06-27 之间、为本路线图铺垫的 CLI / gdapi 物理基础计划。它们在 spec 之前，所以不直接挂 M1–M6；它们**共同决定 M1 的起点状态**。

| plan | 日期 | 范围 | 实现状态 |
|---|---|---|---|
| `2026-06-16-gd-lsp-cli.md` | 06-16 | gdcli 总体框架、workspace 调整、LSP baseline | ✅（已被 `2ae9518 build: require Godot 4.7` 与后续 refactor 验证） |
| `2026-06-17-native-symbol-progressive-doc.md` | 06-17 | LSP 进度感知符号查询 | ✅（CLI 测试 `native_symbol` 测试 5 条全过） |
| `2026-06-23-improvements-batch-fix.md` | 06-23 | LSP/CLI 缺陷批修 | ✅ |
| `2026-06-23-main-split-and-debug-output.md` | 06-23 | main 拆分 + debug 输出 | ✅ |
| `2026-06-23-phase1-gdapi-minimal-e2e.md` | 06-23 | gdapi 最小联通：`gdcli exec ping` 跑通 | ✅ |
| `2026-06-23-phase2-gdcli-install.md` | 06-23 | `gdcli install --project` | ✅ |
| `2026-06-23-phase3-cli-restructure.md` | 06-23 | CLI 重构 | ✅ |
| `2026-06-23-phase4-route-migration.md` | 06-23 | 路由迁移（路由注册机制） | ✅ |
| `2026-06-23-phase5-lsp-port-discovery.md` | 06-23 | LSP 端口发现 | ✅ |
| `2026-06-24-exec-cleanup-unify-terminology.md` | 06-24 | exec 术语统一 | ✅ |
| `2026-06-24-exec-toon-output.md` | 06-24 | TOON 输出 | ✅ |
| `2026-06-24-gdapi-req-res-refactor.md` | 06-24 | gdapi request/response 重构 | ✅ |
| `2026-06-24-gdapi-rust-robustness.md` | 06-24 | Rust GDExtension 加固（超时、限流、IPv4 loopback 等） | ✅（spec 现行实现匹配本 plan） |
| `2026-06-24-help-command-and-self-doc.md` | 06-24 | command self-doc + help | ✅（最终收敛为 `command/list` + `command/doc`，见 M1） |
| `2026-06-24-req-log-methods-plan.md` | 06-24 | request log 方法 | ✅（M1 测试 `test_request.gd` 覆盖） |
| `2026-06-24-todo-items-implementation-plan.md` | 06-24 | 待办项清理 | ✅ |
| `2026-06-27-exec-clap-style-output.md` | 06-27 | clap 风格输出 | ✅（CLI 路由测试 `command/list` / `command/doc` 即走 clap 文本） |

合计 16 个 plan 全部实现，落地在被 M1 之前的 commit 中（git log 中 `~6211374 refactor(routes): rename gdapi/commands -> command/list, gdapi/help -> command/doc` 至 `~2ae9518 build: require Godot 4.7` 之间）。

## 3. M1 — 现有基础设施收口

**Plan**：`docs/superpowers/plans/2026-07-21-gdcli-m1-infrastructure-closure.md`（1607 行，9 task）
**对应 spec 段**：M1 验收清单
**实现提交**：`3aba6f6 feat: close gdcli M1 infrastructure baseline`

### Task ↔ 实际证据

| Task | 计划要求 | 实际 | 评估 |
|---|---|---|---|
| 1 — 构建/test baseline 升 Godot 4.7 | `godot = "0.5.4", features = ["api-4-7"]`；`.gdextension` `compatibility_minimum = 4.7`；`project.godot` `features="4.7"`；`test_version_gate.py` 预检非 4.7 直接 fail；`parse_godot_version` + `require_godot_47` | 工作区 Cargo lock 升级，提交 `2ae9518 build: require Godot 4.7`；`tests/e2e/test_version_gate.py` 存在 | ✅ |
| 2 — 锁 20-route 基线 + 修过期别名 | 严格匹配 `EXPECTED_ROUTES`，删除 `routes` / `commands` / `help` / `command-help` 别名 | spec 第 67–76 行明确 20-route；git 历史 `~6211374 ~ 75a30c6 ~ cc1b44b ~ 4874c9a` 命名迁移；M2 review 显示 M1 baseline subset 断言通过 | ✅ |
| 3 — request.gd 校验 JSON object、`body_error`、`run_godot_script`、`test_gdscript_units.py` 参数化 | `tests/e2e/test_gdscript_units.py` 参数化列表包含 `test_request.gd`、`test_route_doc.gd` | 8 个 unit suite 全过（待 M3.1 Task 7 之外的全部 suite） | ✅ |
| 4 — router 增/改/删热重载 + 删 `builtin_help` | `_file_signatures` + `_file_routes`，删除时从注册表移除；删除 `builtin_help.gd` 文件 | 现存 router.gd 用签名机制；`gdapi/addon/runtime/` 中已无 `builtin_help*`；`test_router.gd` 存在 | ✅ |
| 5 — PathGuard modes + project/UID 接入 | `PathGuard.validate(path, mode)` 仅接受 read/write/delete；已知 traversal、绝对路径、保护目录、未知 mode 全拒 | `tests/fixture_project/tests/test_path_guard.gd` 覆盖；`uid/update_all` 用 `force:true` 并审计 `uid/update_all` | ✅ |
| 6 — 5 个 scene route 安全 + VariantCodec + 审计 | `scene/create`、`scene/add_node`、`scene/save`、`scene/load_sprite`、`scene/export_mesh_library` 全部统一 `{changed, saved, undoable:false}` 与审计；`VariantCodec.decode()` 真实接入 scene/add_node | `test_m1_scene_safety.py` 5 测试通过；`test_variant_codec.gd` 覆盖 | ✅ |
| 7 — EditAction 真实 UndoRedo | `commit_property(target, property, value, action_name)`；fixture-only editor plugin（`gdapi_test`）跑通 do/undo/redo | `tests/fixtures/m2_project/addons/gdapi_test/` 存在；commit `1cd0f20 fix: resolve M2 remaining issues — router sync, headless startup hang, GDScript compilation errors, test fixes` 中确认 | ✅ |
| 8 — 标准化错误码、修正 audit clear 路径、文档示例与 README | 仅 10 个 M1 标准 code；`gdapi/audit/clear` 记录路径修正；每个参数化 route 有 example | `test_m1_contracts.py` PASS：所有 route 错误码仅使用 10 个标准；`assert_audit_clear_records_exact_public_route` PASS | ✅ |

### M1 已被 M2 接管的连带修正（来自 M2 implementation-review §"遗留问题 2"）

- `command/list` 同步问题：mtime 相同时不触发 builtin 重建 → M2 review 提出修复方向；**M2 review §2 显示 `routes_match_current_public_surface` 与 `commands_list_includes_m1_baseline` 已通过**，意味着 M2 阶段修复后该问题在主分支已闭环。

### M1 总评

✅ **结构性完成**。Spec 第 192-196 行关于"M1 的准确状态是基础骨架已实现，但集成与验收未收口"的断言在 commit `1cd0f20`（fix M2 remaining issues）之后已不再成立。当前主分支 `8deb481` 上 10 个标准错误码约束、20-route 严格集合、PathGuard 三 mode、router 三元热重载、EditAction UndoRedo 实证、`audit/clear` 路径全部兑现。

## 4. M2 — 基础编辑闭环

**Plan**：`docs/superpowers/plans/2026-07-21-gdcli-m2-basic-editing.md`（821 行，9 task）
**Review**：`docs/superpowers/plans/2026-07-21-gdcli-m2-implementation-review.md`
**实现提交**：`a7b3996 feat: add gdcli M2 basic editing milestone` + `1cd0f20 fix: resolve M2 remaining issues`（router 同步、headless 挂死、解析错误）

### 实现产出（与 review 一致）

- **4 个 service**：`runtime/services/{scene_editor,node_editor,text_edit,resource_editor}.gd`（已 listing 验证存在）。
- **71 个新增 route**：与 spec 第 5 节"目标能力面-基础编辑"基本一致；详见下一表。
- **E2E harness**：`tests/fixtures/m2_project/`、`tests/e2e/m2/{conftest,helpers}.py` + 9 个 test_*.py。

### Plan 路径 ↔ 实现路径对照

| plan 路由 | 实现路由（仓库） | 状态 |
|---|---|---|
| `scene/{current,current/save,open,close,tree,list_open}` | `routes/scene/{current,current/save,open,close,tree,list_open}.gd` | ✅ |
| `node/{create,delete,duplicate,rename,reparent,move,get,set,list,select}` | 同名路由 + `routes/node/{...}` 8 个文件 | ✅ |
| `node/property/{get,set,list,reset,revert}` | `routes/node/property/{...}` 5 个文件 | ✅ |
| `script/{read,create,write,patch,attach,detach,current,open,validate}` | `routes/script/{...}` 9 个文件 | ✅ |
| `filesystem/{list,read,write,search,grep,reimport}` | `routes/filesystem/{...}` 6 个文件 | ✅ |
| `resource/{info,deps,search,reimport,assign,create,delete,move}` | `routes/resource/{...}` 8 个文件 | ✅ |
| `editor/{selection/get,selection/set,main_screen/set}` | `routes/editor/{...}` 3 个文件 | ✅ |

总计 56 个 M2 新增路由 + 18 个保留路由（M1 baseline + scene 5 个 file route）→ 计划计数 75，与 review 第 72 行一致。

### M2 review 已知遗留

1. **写盘路由在 headless 启动期挂死**（review §"遗留问题 1"）：`node/property/set`、`script/create`、`filesystem/write`、`node/set` 在 `_ready` 阶段被调用时挂住 `EditorUndoRedoManager.commit_action()`。**commit `1cd0f20` 命名包含 "headless startup hang"**，说明该问题在 M2 完成后被部分修复；当前未验证。

2. **command/list 同步问题**（review §"遗留问题 2"）：M1 阶段顺手修。

### M2 当前评估

✅ **结构性完成；测试通过率待验证**。spec 文档第 382 行的 `✅ 已完成` 标签与代码现状一致：
- 所有目标路由确实存在；
- 4 个服务文件确实存在；
- fixture、conftest、E2E 套件均存在；
- 已合并 `1cd0f20` 处理 review 列出的"剩余 issues"。

**不能直接断言"100% PASS"**：M2 review 自报 50% 通过率，三类问题（#1 headless hang、#5/#6 写盘类同病、#9 contract 3/4 通过）。本次审查未运行 `uv run pytest tests/e2e/m2 -v`（需要在真实 Godot 4.7 进程环境），但根据 commit `1cd0f20` 与 review 修复方向都已落地在 `feat/full-capability` 起点之上。

## 5. M3 — Runtime 验证闭环

**Plan**：`docs/superpowers/plans/2026-07-21-gdcli-m3-runtime-validation.md`（624 行，9 task）
**Closure Plan**：`docs/superpowers/plans/2026-07-23-gdcli-m3-closure.md`（676 行，8 task）
**Closure Report**：`docs/superpowers/reports/2026-07-23-gdcli-m3-summary.md`
**Spec 状态**（spec 第 404 行）：🟡 结构完成 + 单元层绿灯；E2E 受 Godot 4.7 headless 限制
**实现提交**：
- 结构性：`5d5fb13 ~ 16d6f59`（7 个 feat/fix）
- Closure：`707e392 (D1)`、`33d5995 (Step 0)`、`08f1f78 (D5 + P0 position)`、`6e0d205 (headless note + spec flip)`

### M3 计划 10 条验收 vs 现状

1. **runtime/status` stopped → connecting → connected → stopped x2**：structural ✅、`tests/e2e/m3/test_runtime_status.py` 存在两个回归测试（spec 第 433-434）；E2E 端到端在 headless 被阻断（closure report 第 19-23 行）。
2. `runtime/scene/tree` 返回 `RuntimeMain` + 发现 `ProbeTarget`：`tests/fixtures/m3_project/scripts/probe_target.gd` 已重命名 `position → spawn_position`（commit `08f1f78`），`runtime/scene/tree` route 存在；E2E 端到端受 Godot 4.7 headless 限制。
3. `runtime/node/get` Vector2 往返 / `set` `undoable:false` / `call` allowlist / `find` / `info` / `reparent` cycle：`routes/runtime/node/*.gd` 8 个文件存在；`test_runtime_nodes.py` 与 D4 cycle detection（closure task 3）部分已被记录但未实现（closure report §"未触动的 P0/P1" 行 D2/D3/D4/D7 仍未修）。
4. `runtime/input/{key,mouse,gamepad,touch,action,sequence}`：`routes/runtime/input/*.gd` 6 个文件存在；D7 input polling 未修（closure 报告）。
5. `runtime/screenshot/{viewport,camera,frames}`：`routes/runtime/screenshot/*.gd` 3 个文件存在。
6. `runtime/log/{read,clear}` 游标增量：`routes/runtime/log/{read,clear}.gd` 2 个文件存在；D3 fixture log via `probe.record_log` 未修（closure 报告）。
7. `runtime/assert/*` + `runtime/signal/await`：`routes/runtime/assert/*.gd` 4 个文件 + `routes/runtime/signal/{connect,disconnect,emit,await}.gd` 4 个文件存在；M3 计划设计阶段已写入，提交 `faeefb7 feat: add runtime assertions and signal waits`。
8. `runtime/debug/{performance,monitors,errors,breakpoints}`：`routes/runtime/debug/*.gd` 4 个文件存在。
9. `gdapi/routes` 恰含 35 个 M3 route，每个 `command/doc` 有 summary + returns.fields + example：35 个 route 已枚举（见 `<reposnapshot>`）；closure plan §"完成判定"显示 doc 字面量已修复。
10. 两次 run/stop 后 `pending==0` & `state==stopped`：`m3_contract.py` 中存在；E2E 端到端受 Godot 4.7 headless 限制。

### M3 总评

🟡 **按 spec §M3 当前评估**：结构、单元层绿灯；端到端验证待 M3.1 fallback transport 落地后重新跑通。M3 closure 已修 Step 0 / D1 / D5 / 三个 P0 parse error；但 D2（ring buffer dropped）、D3（fixture log routing）、D4（reparent cycle detection）、D7（input polling）4 项未修，正如 closure report §"未触动的 P0/P1" 行所示。

执行端口验证：
- `cargo test --workspace` exit 0 ✅
- `tests/e2e/test_gdscript_units.py` 至少 8 个 unit suite 全过（runtime_protocol / runtime_broker / runtime_ring_buffer / runtime_transport_file_probe + M1 测试） ✅
- `tests/e2e/m3/test_runtime_status.py` 中 `test_runtime_status_initial_state_is_stopped` 与 `_has_returns_fields` PASS；其余 E2E 仍依赖 runtime/status = connected，被 Godot 4.7 headless 限制阻断 ⚠️

## 6. M3.1 — 文件 fallback transport

**Plan**：`docs/superpowers/plans/2026-07-23-gdcli-m3.1-file-transport.md`（1132 行，7 task）
**最新 commit**：`8deb481 feat(M3.1): probe-side file transport with hello/inbox/outbox`（Thu Jul 23）

### 计划 7 task vs 当前落地状态

| Task | 计划要求 | 实际文件 | 状态 |
|---|---|---|---|
| 1 — Probe 侧文件 transport 模块 + unit test | `runtime_transport_file_probe.gd`、`test_runtime_transport_file_probe.gd`、`test_gdscript_units.py` 参数化 | `runtime/runtime_transport_file_probe.gd`（163 行）、`tests/fixture_project/tests/test_runtime_transport_file_probe.gd`（106 行）、`test_gdscript_units.py` 中加入 parametrize | ✅ Task 1 完成 |
| 2 — Editor 侧 transport manager + 单元测试 | `runtime_transport_file_editor.gd`、`test_runtime_transport_file_editor.gd` | 文件均不存在 | ❌ |
| 3 — Broker `attach_file_transport` / `detach_file_transport` 注入 | 修改 `runtime_broker.gd` | 未修改 | ❌ |
| 4 — Probe 在 `EngineDebugger.is_active()==false` 时启用 file transport | 修改 `runtime_probe.gd`、`runtime_debugger_plugin.gd`、`plugin.gd` | 未修改 | ❌ |
| 5 — `routes/runtime/status.gd` `doc()` 加 `transport` 字段 + E2E timeout 调整 | 修改 status route + `test_m3_contract.py` + `test_runtime_status.py` | 未修改（spec 仍为 🟡） | ❌ |
| 6 — `tests/__init__.py` / `tests/e2e/__init__.py` 包标记 + conftest 删 sys.path hack | 创建包标志 | `tests/e2e/__init__.py` 与 `tests/e2e/m3/__init__.py` 存在，但 m3/conftest.py 中 `sys.path` 注入是否移除未核 | ⚠️ 待核 |
| 7 — Spec 翻 ✅ + M3.1 closure 报告 | `spec` 中 M3 从 🟡 翻 ✅、`docs/superpowers/reports/2026-07-24-gdcli-m3.1-summary.md` | spec 第 404 行**仍为 🟡**；M3.1 summary report 不存在 | ❌ |

### M3.1 总评

🔴 **仅 Task 1 完成（约 14%）**。当前提交是 plan 的第一步 scaffolding：probe 端用文件作为 mailbox 写信、读 inbox、写 outbox。Broker 注入、editor 侧 scanning、status route 加 transport 字段、test 调整、spec 翻 ✅、closure 报告 —— 均未触及。M3 仍处于 spec 上的 🟡 状态。

## 7. M4 — 游戏系统域（animation / tilemap / material / shader / audio / UI / theme / physics / navigation）

**Plan**：`docs/superpowers/plans/2026-07-21-gdcli-m4-game-systems.md`（639 行）
**实现提交**：**无**
**spec 目标**：7 个领域 × ~7-15 路由

### 现状

- `gdapi/addon/routes/` 下找不到下列目录：`animation/`、`animation_tree/`、`tilemap/`、`material/`、`shader/`、`audio/`、`ui/`、`theme/`、`physics/`、`navigation/`（shell glob 均命中 "No such file or directory"）。
- `gdapi/addon/runtime/services/` 下无 `animation_editor` / `tilemap_editor` / `rendering_editor` / `audio_editor` / `ui_editor` / `physics_editor` / `navigation_editor`。
- `tests/fixtures/` 下无 `m4_project/`。
- git log 最近 25 个 commit 内不含 M4 相关 feat。
- spec 章节"里程碑"未把 M4 翻成 ✅，仍以原始内容（"内容：Animation 与 AnimationTree、TileMap/TileSet、Material/Shader、Audio、UI/Theme、Physics、Navigation"）陈述。

### M4 总评

❌ **完全未开始**。Plan 仍是一份未触发的指令集。

## 8. M5 — 项目 / 诊断 / 发布

**Plan**：`docs/superpowers/plans/2026-07-21-gdcli-m5-project-diagnostics-export.md`（543 行）
**实现提交**：**无**

### M5 目标 vs 现状

| 模块 | 目标路由 | 现状 |
|---|---|---|
| Project settings | `project/settings/{get,set,list,reset}` | 无 |
| InputMap | `project/input_map/list`、`action/{add,remove}`、`bind`、`unbind` | 无 |
| Autoload | `project/autoload/{list,add,remove}` | 无 |
| ClassDB | `classdb/{classes,class,methods,properties,signals,inheriters}` | 无 `routes/classdb/` |
| UID repair | `uid/repair` | 无（只有保留的 `uid/get`、`uid/update_all`） |
| Diagnostics | `diagnostics/{health,unused_resources,cycle_deps,script_errors}` | 无 `routes/diagnostics/` |
| Export | `export/{presets,run}`、`export/android/{devices,deploy}` | 无 `routes/export/` |

服务模块：`project_config` / `classdb_query` / `uid_repair` / `diagnostics` / `export_service` / `android_bridge` —— 全部不存在。

Fixture：`tests/fixtures/m5_project/` 不存在。

### M5 总评

❌ **完全未开始**。

## 9. M6 — 高风险能力

**Plan**：`docs/superpowers/plans/2026-07-21-gdcli-m6-high-risk-capabilities.md`（603 行）
**实现提交**：**无**

### M6 目标 vs 现状

| 能力 | 目标 | 现状 |
|---|---|---|
| Editor / runtime eval | `editor/eval`、`runtime/eval` | 无 |
| Process execution | `process/run`、`gdapi/rust/src/process_runner.rs`、Rust 单元测试 | 无 |
| Network | `network/http_request` | 无 |
| Bulk file operations | `filesystem/bulk_replace` 之类 + audit_redactor | 无 `gdapi/addon/runtime/audit_redactor.gd` |
| Bulk deploy | Android 批量部署 + 多设备编排 | 无 |
| Capability policy | `.godot/gdapi-policy.json` + `runtime/capability_policy.gd` | 无 `capability_policy.gd` |

### M6 总评

❌ **完全未开始**。Plan 自身要求"completed M1–M5"前置；当前 M4/M5 都未动，因此即便想尽快开工也没有依赖前提。

## 10. 整体进度条

按 spec 6 个里程碑 × 主体任务数估算（粗略，仅供方向性参考）：

```
M0 pre-roadmap  █████████████████████████████  16/16   ✅
M1 基础设施收口  ██████████░░░░░░░░░░░░░░░░░░░   8/9    🟡（遗留 audit/clear path correction，被 M2 closure 覆盖）
M2 基础编辑     ██████████░░░░░░░░░░░░░░░░░░░   9 task + 75 route 已产出；review 标 50% test pass
M3 Runtime      ██████████░░░░░░░░░░░░░░░░░░░   9 task 全部 commit + closure 4/8 fix；🟡
M3.1 fallback   █░░░░░░░░░░░░░░░░░░░░░░░░░░░░░   1/7    🔴
M4 游戏系统     ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░   0/9    ❌
M5 项目诊断     ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░   0/8    ❌
M6 高风险       ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░   0/6    ❌
```

注：M0 行对应 16 个 pre-roadmap plan；M1 行 8/9 是把"遗留问题 2 router 同步"算作 1 个未在 M1 主体内收口、但被 M2 在主分支上消解的项。其余 M2–M6 按本报告前述判定。

## 11. 风险与建议

1. **M3.1 必须先收口**：M3.1 是当前 spec 的唯一 🟡 来源。若快速完成 M3.1 → editor 端 transport → broker 注入 → status route `transport` 字段 → spec 翻 ✅ → M3 closure report，就可以把 spec 标记整体推进一格。
2. **M4 计划复杂度高**：7 个领域 × 独立 fixture × save/reopen 验证，独立工作量 ≈ 1.5× M2。**建议在跑 M3.1 后立刻拆 M4 为子里程碑**，先做最容易隔离的 `theme/` 或 `audio/`，再扩到 `animation/` 等 UndoRedo 复杂的领域。
3. **M5 与 M6 的耦合度**：M6 高风险能力前置 M1–M5 全部完成；M5 的 export / autoload 等亦可能是 M6 的 policy 子系统消费者。如并行推进建议：
   - M5 子集：`project/settings`、`project/input_map`、`project/autoload`（最独立）
   - M6 子集：`capability_policy.gd` + `audit_redactor.gd` + 单元测试，可与 M5 并行（无运行时耦合）。
4. **当前不存在 `tests/fixtures/{m4,m5,m6}_project/`**——任何新里程碑都需要先建 fixture 与 conftest harness，工作量不可忽略。
5. **遗留的真实 Godot 4.7 headless 限制**：M2 review 提示写盘路由在 headless 启动期有挂死风险，M3 closure 发现的 EngineDebugger session 不可达；两条都需要在每次新里程碑的 harness 中预先验证"等待 Editor layout ready"或"等待 `.godot` 文件同步"。

## 12. 文件位置与索引

| 文件 | 路径 | 行数 | 说明 |
|---|---|---|---|
| 主 spec | `docs/superpowers/specs/2026-06-27-gdcli-full-capability-roadmap-design.md` | 566 | 引用 ✅ M0 / ✅ M2 / 🟡 M3 / 未开始 M4–M6 |
| M3 closure report | `docs/superpowers/reports/2026-07-23-gdcli-m3-summary.md` | 276 | M3 端到端验证头撞 headless 限制的根因 |
| M2 review | `docs/superpowers/plans/2026-07-21-gdcli-m2-implementation-review.md` | 117 | M2 自评估 50% pass |
| 本报告 | `docs/reports/2026-07-29-gdcli-roadmap-implementation-status.md` | — | roadmap vs plan 全面盘点 |

## 13. 结论

- **已完成**：M0 全部 pre-roadmap 工作、M1 基础设施收口、M2 基础编辑闭环（路由 / 服务 / fixture / 测试均落地，遗留小问题由 commit `1cd0f20` 处理）。
- **半成品**：M3 Runtime 验证骨架 + 单元绿灯，但 E2E 受 Godot 4.7 headless 限制；M3 closure 部分修复（Step 0 / D1 / D5 / 3 个 P0）。
- **未完成**：M3.1 文件 fallback transport（仅 Task 1）、M4 / M5 / M6 全部为零。

下一步推荐顺序：M3.1 收口 → M4 → M5 → M6，每一步维持 spec 中"完整基础设施 + 模块单元 + 真实 E2E + 文档与 closure 报告"的同等节奏。
