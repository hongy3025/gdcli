# gdcli 目标收口报告（Android 除外）

日期：2026-10-03
分支：`feat/full-capability`
依据：[分支总目标与范围](../superpowers/specs/2026-10-03-gdcli-branch-goal-and-scope.md) + [目标收口计划](../superpowers/plans/2026-10-03-gdcli-goal-closure.md)
基线：Godot `4.7.2.stable.official.ed1daf0bf`（`D:\app\devel\Godot\v4.7.2\godot_console.exe`）

## 1. 范围变更

Android 平台能力整体移出目标并**删除实现**：删除 `export/android/{devices,deploy,deploy_many}` 路由、`android_bridge`、`bulk_deploy_service` 及其测试/fixture；编辑器实际注册路由 196 → **193**。里程碑 route manifest 调整为 M5 = 25、M6 = 7；`export/run` 统一 `--export-pack`，`export/presets` 不再返回 `templates` 字段。全部记为 CHANGELOG 的 breaking change。

## 2. 收口过程中发现并修复的真实缺陷

以下每项都有执行证据（命令与结果），不是仅靠代码阅读推断。

| # | 缺陷 | 证据与修复结果 |
|---|---|---|
| 1 | `export/run` 在编辑器内必然失败：子进程进度输出写满约 4 KiB 管道（Godot `CreatePipe(..., 4096)`）后阻塞，直到 deadline 被杀 | 改为运行期间持续排空管道；超时返回 `timeout` 并删除半成品；桌面 PCK 用例 5 passed |
| 2 | 导出子进程重复加载 gdapi 插件，覆盖并删除父编辑器正在使用的 `.godot/gdapi.json`，导致编辑器失联 | 子进程改用 `--editor --headless --recovery-mode`；实测 PCK 摘要与普通导出一致（`3735b8e4…`，778136 字节） |
| 3 | 导出响应 `messages` 含 ANSI/控制字符，严格 JSON 解析器无法读取 | 返回前清洗控制字符与 ANSI 转义 |
| 4 | `node/delete` 返回 `undoable:true` 但跨帧 undo 后节点未恢复（已复现） | `do` 只 `remove_child`、`undo` 恢复父节点与 index，按 Godot `scene_tree_dock.cpp` 只用 `add_undo_reference`；`tests/e2e/m2/test_node_editor.py` 14 passed |
| 5 | `theme/constant/set`、`theme/font_size/set` 拒绝文档示例中的合法整数（已复现 `value:4` → 400） | 新增 `_int_value()` 接受整数值浮点、拒绝非整数/NaN/INF；`tests/e2e/m4/test_theme.py` 4 passed（临时还原旧判断即 4 failed） |
| 6 | `navigation/mesh/bake` 只是复制现有 `NavigationPolygon`，并未烘焙 | 改为 `parse_source_geometry_data` + `bake_from_source_geometry_data`（带 deadline 与失败清理）；源几何改动会改变烘焙结果（4 → 3 多边形）；`region/list` 去掉不稳定 `map_rid` |
| 7 | `scene/list_open` 只返回当前场景 | 改用 `EditorInterface.get_open_scenes()`（稳定排序）；`scene/close` 明确为「仅当前场景」并写入 `doc()` |
| 8 | `resource/assign` 未校验目标属性是否为资源槽位（与 `doc()` 不符），既有拒绝用例因资源不存在而"误绿" | 新增 `_is_resource_property` 校验；用例改为项目内真实资源 + 非资源属性，断言 `invalid_param` |
| 9 | `audio/player/create` 返回编辑器内部路径（`/root/@EditorNode@...`），无法再被其它路由使用；`physics/*` 只接受场景根相对路径而 `doc()` 示例是绝对路径 | 统一返回/规范化 `/root/<场景根>/...` |
| 10 | 审计真实性：deferred registry 以「响应已发送」推断成功；`network/http_request`、`process/run` 早退路径无审计 | registry 无 outcome 即判失败（新增单元用例）；早退路径补审计；`test_network_request.py`/`test_process_run.py` 断言失败审计 |
| 11 | 批量文件：`plan_hash` 未绑定 `find`/`replace`（不同替换可共享 hash）、回滚不检查每步结果、`recover` 中途失败会留下部分状态、replace 未逐文件做写入校验 | 绑定全部参数；回滚/recover 检查并回滚（`details.rollback_failures`）；扫描阶段拒绝保护路径；`test_bulk_files.py` 7 passed |
| 12 | 项目配置：InputMap 变更只改内存、重载即丢；保存失败不回滚内存 | InputMap/Autoload 写回 `ProjectSettings`；保存失败回滚并记录失败审计；新增持久化断言 |
| 12b | **Godot 在目标文件不可写时会静默"成功"**（临时文件 rename 失败被吞，`ProjectSettings.save()`/`ResourceSaver.set_uid` 仍返回 OK，磁盘未变），导致路由误报 `ok:true` | 项目设置/InputMap/Autoload/`uid/repair` 增加**回读校验**：未落盘即判定失败、回滚内存状态与已写 UID，并返回 `godot_error`；由只读文件的 E2E 用例覆盖（无需假探针） |
| 13 | 测试隔离：`default_bus_layout.tres` 被当作固定文件（Godot 自行增删）；`restore_file_state` 静默吞掉恢复失败；`scene/open` 延迟生效导致 UndoRedo 绑到旧场景 history；M6 无文件恢复；fixture 把 `cargo build` 失败当作 skip | 统一 `is_tracked_project_file` 例外、恢复校验+重试+报错、`exec_ok` 打开场景后等待切换完成、M6 每测试文件恢复、只有缺 cargo 才 skip |
| 14 | `uid/repair` 失败路径的类型错误：`changes`(Array) 被当作 `res.error()` 第 4 个参数（要求 Dictionary），GDScript 抛错后响应发不出去 → CLI 只能等到超时（潜伏 bug，因失败从未被触发而未被发现） | 路由改为传 `details`（合并 `changes` 与失败详情）；由新的只读目标资源用例覆盖（此前该用例表现为 90s 无响应） |

## 3. 任务执行结果

| Task | 内容 | 状态 |
|---|---|---|
| 1–2 | Android 从 manifest/测试门禁移除；桌面导出验收恢复（PCK） | ✅ |
| 3 | 用户文档与 backlog 与范围一致（含入口写法、runtime 表、EngineDebugger 表述修正） | ✅ |
| 4 | `node/delete` UndoRedo 真实可用 | ✅ 14 passed |
| 5 | Theme 数值与 5 条路由验收 | ✅ 4 passed |
| 6 | 场景打开集合与关闭语义 | ✅ 9 passed |
| 7 | Navigation 真烘焙 | ✅ 5 passed |
| 8 | M2 验收补齐（信号/分组持久化、typed 往返、assign/attach） | ✅ 63 passed |
| 9 | M4 弱验收补齐（Audio/Physics/Animation/TileMap） | ✅ 42 passed ×2 |
| 10 | 单编辑器 fixture 身份统一 + 会话级断言 | ✅ 守卫用例通过 |
| 11 | 每测试隔离与恢复硬化 | ✅（运行时 harness 偶发项仍跟踪） |
| 12 | 预算默认排除 + 收集顺序 | ✅ 360/361、1 deselected |
| 13 | 失败审计真实性 | ✅ |
| 14 | 批量事务完整性 | ✅ 7 passed |
| 15 | 持久化与 UID 失败路径 | ✅（失败注入受限，见下） |
| 16 | 门禁与全量套件 | 见第 4 节 |
| 17 | 本报告 + 文档收尾 | ✅ |
| 18 | 删除 Android 实现（可选，已执行） | ✅ |

## 4. 验证证据（实际执行）

### 4.1 门禁

| 命令 | 结果 |
|---|---|
| `python scripts/format-gd.py` / `--check` | 556 个 GDScript 通过 |
| `gdlint <全部改动 .gd>` | Success: no problems found |
| `cargo fmt --check` | 通过 |
| `cargo clippy --workspace --all-targets -- -D warnings` | exit 0 |
| `cargo test --workspace` | 202 passed, 0 failed |

### 4.2 聚焦套件

| 命令 | 结果 |
|---|---|
| `uv run pytest tests/e2e/m2 -q` | 63 passed（连续两次） |
| `uv run pytest tests/e2e/m4 -q` | 42 passed（连续三次） |
| `uv run pytest tests/e2e/m5 -q` | 18 passed |
| `uv run pytest tests/e2e/m6/test_bulk_files.py -q` | 7 passed |
| `uv run pytest tests/e2e/m5/test_export.py -q` | 5 passed |
| `uv run pytest tests/e2e/m4/test_theme.py -q` / `test_navigation.py -q` | 4 passed / 5 passed |
| `uv run pytest tests/e2e/m3/test_runtime_status.py -v` | 5 passed（真实编辑器 run/connect/stop 两轮生命周期） |
| `uv run pytest tests/e2e --collect-only -q` | 360/361，1 deselected（budget 默认排除） |

### 4.3 全量与预算

| 运行 | 结果 |
|---|---|
| 预算验收 `uv run pytest tests/e2e/test_full_suite_budget.py -m budget -v` | **1 passed in 301s**（嵌套全量绿色、`GODOT_EDITOR_STARTS=1`、嵌套 walltime ≤ 360s） |
| 独立全量非预算 `uv run pytest tests/e2e -q -s` | **368 passed, 1 failed, 1 deselected in 302s**；`GODOT_EDITOR_STARTS=1`。唯一失败为超时敏感的输入序列用例，已放宽等待并单跑验证（32 passed） |

全量套件在收口过程中共运行 5 次，每次暴露的问题都已修复（不是"重跑掩盖"）：

| 运行 | 结果 | 暴露的问题与处理 |
|---|---|---|
| A | 367 passed, 2 failed, 2 errors | 新增 M6 隔离断言抓到 m5 `uid/repair` 的跨模块文件泄漏；会话 teardown 的失败传播让 mock 单元用例失败 → 均已修复（m5 收尾恢复共享基线；mock 用例 `reset=False`） |
| B | 354 passed, 1 failed, 15 errors | 1 次 undo 桥 2s 超时（改为 10s）+ 1 次模块级运行时握手失败级联（单跑 `tests/e2e/m3` 为 123 passed，属偶发；保留诊断继续跟踪） |
| C | 369 passed, 1 error（session teardown） | 会话级断言指出 `GODOT_EDITOR_STARTS=2`：测试模块 `from ... import e2e_editor` 导致 fixture 重复定义、真的启动了第二个编辑器 → 已修复（只导入模块 + 通过 conftest re-export 请求 fixture） |
| D | 预算验收 1 passed（嵌套全量绿色，301s） | — |
| E | 368 passed, 1 failed | `test_input_sequence_over_five_seconds_honors_explicit_timeout` 的 `wait_for` 默认 5s 在重负载下偏紧 → 放宽到 15s，单跑该文件 32 passed；`GODOT_EDITOR_STARTS=1` |

## 5. 未完成 / 未验证事项（如实记录）

1. ~~保存失败回滚缺少 E2E 注入~~ **已解决**：不再依赖"注入失败"，而是让服务自己回读校验落盘结果（Godot 在目标不可写时会静默返回 OK）。回滚分支现由只读 `project.godot` 与只读目标资源两个 E2E 用例覆盖（断言报错、内存回滚、文件不变、`uid/repair` 失败后 dry-run 与失败前完全一致）。
2. **运行时 harness 偶发握手失败**：一次全量运行中 `m3_running` 的 probe 在 60s 内未连接，级联同模块 14 个用例 error；单独运行 `tests/e2e/m3` 为 123 passed，其余运行也全绿。已保留 `attach_game` 的一次重试与失败诊断（含 status/log tail），触发条件仍未定位。
3. **负载敏感的超时**：`gdapi_test` undo 桥 2s 与 `wait_for` 5s 在重负载下偏紧（各观测 1 次），已分别放宽到 10s / 15s；这类放宽只影响失败路径耗时，不改变断言语义。
4. **GUI / EngineDebugger 数据面**：本机验收均为 headless（file transport）。GUI 下的 EngineDebugger 数据面、渲染截图、真实输入注入未在 4.7.2 上重新验收。
5. **未执行**：导出模板相关路径（本机无模板；桌面 PCK 导出已实测不需要模板）；Android 已整体移出范围。
