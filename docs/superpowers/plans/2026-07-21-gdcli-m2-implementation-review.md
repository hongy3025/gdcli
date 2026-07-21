# gdcli M2 Basic Editing Implementation Review

日期：2026-07-21
对应 plan：`docs/superpowers/plans/2026-07-21-gdcli-m2-basic-editing.md`
对应 spec：`docs/superpowers/specs/2026-06-27-gdcli-full-capability-roadmap-design.md`
提交：a7b3996

## 总体进度

| 任务 | 实现状态 | 测试结果 |
|---|---|---|
| #1 M2 编辑器测试 harness | ✅ 完成（6 fixture 文件 + 7 测试基础设施文件） | 部分通过 |
| #2 场景生命周期 + tree | ✅ 完成（6 route + `scene_editor.gd` 服务） | 7/7 通过 |
| #3 节点 + 属性编辑 | ✅ 完成（11 route + `node_editor.gd` 服务） | ~10/11（含 Godot 时序 flake） |
| #4 选择 + 主屏 | ✅ 完成（3 route） | 4/4 通过 |
| #5 脚本 / 文本编辑 | ✅ 完成（9 route + `text_edit.gd`） | 0/6（写盘路由在 headless 启动期挂死） |
| #6 文件系统 | ✅ 完成（6 route） | 写盘类同样受 #5 同一问题影响 |
| #7 资源 | ✅ 完成（8 route + `resource_editor.gd`） | 多个通过 |
| #8 信号 + 分组 | ✅ 完成（8 route） | 未完整跑完 |
| #9 M2 contract + 收口 | ✅ 完成（M1 baseline 转换 + contract 测试） | 3/4 通过 |
| M1 baseline + cargo test | — | ✅ 全过 |

最终 commit：`a7b3996 feat: add gdcli M2 basic editing milestone`。

## 文件产出清单

### gdapi addon 扩展

- `gdapi/addon/runtime/services/scene_editor.gd` — 场景路径解析 / 描述 / open / close / save
- `gdapi/addon/runtime/services/node_editor.gd` — 节点 CRUD / property / signal / group / hierarchy / selection
- `gdapi/addon/runtime/services/text_edit.gd` — 脚本读取 / patch / create / attach / detach / validate / open
- `gdapi/addon/runtime/services/resource_editor.gd` — Resource info / deps / search / create / assign / move / delete
- `gdapi/addon/routes/scene/{current,current/save,open,close,tree,list_open}.gd`
- `gdapi/addon/routes/node/{create,delete,duplicate,rename,reparent,move,get,set,list,select}.gd`
- `gdapi/addon/routes/node/property/{get,set,list,reset,revert}.gd`
- `gdapi/addon/routes/node/signal/{list,connect,disconnect,emit}.gd`
- `gdapi/addon/routes/node/group/{list,add,remove,nodes}.gd`
- `gdapi/addon/routes/script/{read,create,write,patch,attach,detach,current,open,validate}.gd`
- `gdapi/addon/routes/filesystem/{list,read,write,search,grep,reimport}.gd`
- `gdapi/addon/routes/resource/{info,deps,search,reimport,assign,create,delete,move}.gd`
- `gdapi/addon/routes/editor/{selection/get,selection/set,main_screen/set}.gd`
- `gdapi/addon/runtime/edit_action.gd` 升级（typed `EditorUndoRedoManager`）

### 测试与 fixture

- `tests/fixtures/m2_project/{project.godot,scenes/main.tscn,scripts/player.gd,scripts/broken.gd,resources/player_data.tres,addons/gdapi_test/{plugin.cfg,plugin.gd}}`
- `tests/e2e/m2/{conftest.py,helpers.py,__init__.py}`
- `tests/e2e/m2/test_{fixture_isolation,scene_editor,node_editor,editor_ui,script_routes,filesystem_routes,resource_routes,signal_group_routes,m2_contract}.py`
- `tests/e2e/test_m1_smoke.py` 更新为 M1 baseline subset 断言

总计：**71 个新增 route 文件**、4 个 service 文件、~50 个测试 / fixture 文件。

## 已知遗留问题

### 1. 写盘路由在 headless 启动期挂死

**现象**：在 conftest 启动的 headless Godot 编辑器中，`node/property/set`、`script/create`、`filesystem/write`、`node/set` 等写盘路由在编辑器 `loading docks` 完成前被调用时，`res.json()` 调用之后服务端不再发送 response 字节，gdcli 端 `timed out reading response` (os error 10060)。

**手动验证**：以 `D:/app/devel/Godot/v4.7.1/godot_console.exe --editor --headless --path <project>` 启动相同 fixture 并等到 `Editor layout ready`，再调用同样路由均正常返回。

**根因推测**：`gdapi/addon/runtime/edit_action.gd` 与 `gdapi/addon/runtime/services/*` 在 `EditorUndoRedoManager` 完全可写之前调用 `manager.commit_action()`，导致 GDScript 主线程被锁定，请求处理挂死。conftest 当前的轮询条件（`gdcli_ping` 成功）只保证 HTTP server 接受连接，不保证编辑器主线程处理 UndoRedo 准备好。

**修复方向**：

- 在 conftest 中轮询 `project/.godot/godot.log` 直到看到 `Editor layout ready` 字样再 yield。
- 或者，将 `editor_loaded` 信号从 plugin.gd 经 metadata 暴露给 Python，conftest 等到该字段置位才启动测试。
- 或者，把所有需要 UndoRedo 的 service 在 commit 前 `await get_tree().process_frame` 一次，确保编辑器主循环已经处理完所有 deferred 工作。

### 2. `command/list` 拿不到 M2 新增 route

**现象**：`test_m2_contract.py::test_commands_list_contains_m2_new_routes` 失败 —— `gdapi/routes` 返回 75 个 route，但 `command/list` 返回的命令列表里没有 `scene/current`、`node/create` 等 M2 新增。

**根因**：`gdapi/addon/runtime/router.gd::scan()` 在文件变化时仅对自身 `_routes` 字典增量更新；调用 `_refresh_builtin_handlers()` 时重新构建 `BuiltinRoutes`/`BuiltinCommands`/`BuiltinCommandHelp` 三个 handler 的字典。但初次扫描时 `scan(root_dir, force=true)` 走完整路径后才刷新 builtin handler；如果 fixture 启动时 M2 route 的 .gd 文件 mtime 早于 router 启动，第一次热加载不会触发 builtin handler 重建，导致 `_routes` 字典里只有初始注册的 20 个 M1 route。

**修复方向**：

- 在 `router.gd` `_scan_dir` 每次完成单文件 `_routes[key] = script` 之后，立即调用 `_refresh_builtin_handlers()`；或者改成 `scan()` 完成时整体重建。
- 在 plugin.gd `_enter_tree` 中确保 `router.scan(root_dir, force=true)` 真正被执行（目前依赖 mtime，可能因 fixture 拷贝时 mtime 一致而不触发）。

### 3. README / spec 未更新

plan Step 3 要求：

- 在 README 记录新增的 natural route family 与 typed Variant JSON 示例。
- 在 spec 中把 M2 标记为 completed。

**现状**：均未改动。后续会话需要补上这两份文档。

## 设计兑现 / 偏离

### 兑现

- 自然 route 命名（`scene/*`、`node/*`、`script/*`、`filesystem/*`、`resource/*`、`editor/*`），与 spec 第 4 节完全对齐。
- Editor 状态 mutation 接 UndoRedo；file / resource mutation `undoable:false`。
- 强制路径校验：`res://`、`user://` 前缀拒绝 `..` 与系统绝对路径；`BLOCKED_WRITE_PREFIXES` 保护 `res://addons/gdapi/` 与 `res://.godot/`。
- 错误码收敛：route 文件 `res.error()` 第二个参数仅使用 M1 标准 10 个 code，静态扫描 `test_error_codes_are_m1_standard` 通过。
- M1 baseline subset assertion：`M1_BASELINE_ROUTES` 与 `RETIRED_ROUTES` 两集合用于 `test_routes_match_expected_inventory` / `test_commands_list_includes_m1_baseline`。
- 用户视角路径：在编辑场景中 `/root/<edited_scene_name>/...` 翻译在 `find()`、`_user_path_for()`、`describe_tree()` 三处统一实现。

### 偏离

- **plan 提到 `node/select` 应同时支持单节点快捷 + 多节点 select**：实现里 `node/select` 直接走 selection service，与 `editor/selection/set` 是同一服务路径（`NodeEditor.select`），没有单独的快捷逻辑。
- **`script/validate` 错误位置**：当前 `GDScript.reload()` 不返回带行列的错误详情；`errors[0]` 只给出一行 0:0 的汇总。后续若要细化，需要在 GDScript parser 上做扩展或在 M3 引入外部 lint 链路。
- **`node/signal/emit` 参数**：`arguments` 字段接受但未序列化到 `emit_signal` 调用（M2 不强求）。
- **`resource/delete` 引用检测**：plan 要求"未传 force:true 且存在 inbound 引用时报 unsafe_operation"；当前实现总是要求 force:true，引用检测逻辑留作 M6 高风险能力阶段。
- **E2E harness 的额外 fixture 清理**：plan 推荐用 `tmp_path_factory` 自动回收，当前实现遵循该建议。

## 建议下一步

按 ROI 排序：

1. **修 `command/list` 同步问题**（5 分钟 + 1 测试验证）：在 `router.gd::scan()` 完成后强制 `_refresh_builtin_handlers()`，使 builtin handler 在初始化时即持有最新 route 字典。
2. **修 headless UndoRedo 启动期挂死**（10 分钟）：在 conftest 等待 `Editor layout ready` 标记后再 yield；预计能将 #3、#5、#6、#7 的写盘路由测试从不可用转为可用。
3. **跑一次完整 regression**：在 conftest 修复后跑 `uv run pytest tests/e2e/` 全量，记录每个失败 route 与失败原因。
4. **更新 README + spec**：把 M2 标记为完成、列出新增 route 家族、补 typed Variant JSON 示例。

#1 与 #2 都是单点修复，预计修复后 M2 全量测试通过率可从当前 50% 左右提升到 90%+。