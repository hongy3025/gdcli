# gdcli T1–T8 验收与遗留边界

日期：2026-10-03
来源：[目标收口报告](../reports/2026-10-03-gdcli-goal-closure.md) + [外部能力对等复核](../reports/2026-10-03-external-parity-comparison.md)
状态：T1–T8 均已完成。本文件保留 T1 历史故障证据，并汇总 T2–T8 的实现、验证与复现入口；明确非目标和环境边界见 §3–§4。

优先级：`P1` = 影响验收可信度，`P2` = 影响能力面，`P3` = 行为取舍/环境。

---

## 1. 工程修复与验收记录

### T1（P1）运行时 harness 偶发握手失败（已解决）

**历史证据**
- 6 次全量运行中出现 1 次：`m3_running` 的 probe 在 60s 内未连接（`state=connecting`、`transport=none`、`editor_playing=true`），级联同模块 14 个用例 error；单独运行 `tests/e2e/m3` 为 **123 passed**。
- 当时仅加入失败诊断与一次恢复重启，未修复握手本身。

**已定位缺陷**
- `gdapi/addon/runtime/runtime_transport_file_probe.gd::_write_hello_file()` 在写文件前就设置 `_hello_sent=true`，并忽略 `_atomic_write()` 的成功/失败结果。一次 open 或 rename 失败后，`tick()` 不再发布 hello，编辑器无法发现 probe。
- 真实 Godot 故障注入：在 probe 建好 inbox/outbox 后用目录占住 `hello.json`，使临时文件写入成功而 rename 失败；移开障碍后，旧实现仍无 hello，连续状态采样保持 `connecting / none / editor_playing=true`。
- 历史失败未记录 hello 的写入结果，不能断言那一次一定由同一个 I/O 故障触发；本次证明并修复的是能确定性产生该症状的握手终态缺陷。

**修复**
- 只有原子发布成功才把 hello 标记为已发送。立即与延迟 hello 共用明确的发布 deadline；未发布成功时保持握手待完成，由后续 tick 完成发布，且不处理未就绪端点的请求。
- 保持原定 hello 延迟、不扩大 harness 的 60s 超时或恢复次数、不重启游戏。已发布端点消失仍表示断开，不重新宣告旧 session。
- 两份 fixture 的 `test_runtime_transport_file_probe.gd` 同步增加真实文件系统回归：立即 open 失败、延迟 rename 失败、发布前 deadline 与发布后断开不复活。

**验证证据（实际执行）**

| 验证 | 结果 |
|---|---|
| 相同 rename 故障注入，解除文件障碍 | **0.025s** 内连接；同一 generation，`game_run_count=1`、`game_stop_count=0`，未恢复重启 |
| 恢复后的 runtime 数据面与停止 | `runtime/scene/tree` 返回 `RuntimeMain` 与 `ProbeTarget`；stop 后 `stopped / none / pending=0 / editor_playing=false` |
| `python scripts/format-gd.py` / `--check` | 555 个 GDScript 通过 |
| `gdlint`（全部 3 个改动 `.gd`） | Success: no problems found |
| `uv run pytest tests/e2e/test_gdscript_units.py -q -s -k transport` | **3 passed, 16 deselected**，单编辑器 |
| `cargo test --workspace` | **202 passed** |
| `uv run pytest tests/e2e -q -s`（连续 5 次） | 每次 **373 passed, 1 deselected**；无握手失败或 harness recovery，均为单编辑器 |

连续全量明细（默认 file transport；budget 仍按默认配置排除）：

| 轮次 | 结果 | 耗时 | `GODOT_EDITOR_STARTS` |
|---|---|---|---|
| 1 | 373 passed, 1 deselected | 281.72s | 1 |
| 2 | 373 passed, 1 deselected | 281.10s | 1 |
| 3 | 373 passed, 1 deselected | 281.04s | 1 |
| 4 | 373 passed, 1 deselected | 281.16s | 1 |
| 5 | 373 passed, 1 deselected | 282.13s | 1 |

**验收标准已满足**：连续 5 次全量运行 0 次该失败；同时落地真实发布状态修复，并证明同一运行会话内的握手恢复，不依赖放宽超时或增加 harness 重试。

### T2（P2）EngineDebugger 数据面独立验收（已完成）

**实现**：默认 E2E 仍固定 file transport，EngineDebugger 使用独立 pytest 会话和 `GDAPI_E2E_TRANSPORT=engine_debugger`，覆盖协议 v2、运行时场景树、PNG 截图、输入与停止。门禁纳入 `scripts/check.py` 和 GitHub Actions，失败会阻断流程。

**验证**：`uv run python scripts/check.py --gate engine` → **1 passed**；独立门禁要求单编辑器会话。

**复现**：见附录的 EngineDebugger 命令。

### T3（P3）成功等待分布与预算余量（已完成）

**实现**：E2E harness 汇总成功等待的 P50/P95/P99/max，并输出 P99×3 建议；成功路径 telemetry 不自动放宽任何 timeout。预算可通过 `GDAPI_E2E_BUDGET_SECONDS` 显式配置，默认仍是 **360s**。

**验收边界**：`E2E_SCENE_SWITCH_TIMEOUT_SECONDS` 与单项等待超时仍是各自独立的语义约束；没有用增加超时、改变预算默认值或缩小测试选择来掩盖 walltime。

**全量 file gate**：`uv run python scripts/check.py --gate file` → **537 passed, 4 deselected in 345.84s**，`GODOT_EDITOR_STARTS=1`。默认 360s 保持不变；被 deselect 的项仅属于独立 budget、EngineDebugger、renderer 门禁。

**预算验收**：`uv run python scripts/check.py --gate budget` → **1 passed in 349.65s**；嵌套全量 `FULL_SUITE_PARENT_WALL_SECONDS=349.612`，低于未变更的 360s 默认预算 **10.388s**。预算测试同时校验单编辑器契约。

成功等待分布（秒；当前 Godot 4.7.2 / Windows 环境）：

| 等待 | count | P50 | P95 | P99 | max | P99×3 建议 |
|---|---:|---:|---:|---:|---:|---:|
| editor_metadata | 1 | 15.0075 | 15.0075 | 15.0075 | 15.0075 | 45.0226 |
| editor_ping | 1 | 6.6318 | 6.6318 | 6.6318 | 6.6318 | 19.8954 |
| editor_ready | 1 | 0.0085 | 0.0085 | 0.0085 | 0.0085 | 0.0254 |
| predicate | 36 | 0.0622 | 0.2184 | 1.0347 | 1.3855 | 3.1040 |
| runtime_connect | 9 | 1.1532 | 1.4825 | 1.5057 | 1.5115 | 4.5171 |
| runtime_playing | 3 | 0.0205 | 0.2125 | 0.2296 | 0.2339 | 0.6888 |
| runtime_stop | 6 | 0.0274 | 0.0396 | 0.0425 | 0.0432 | 0.1276 |
| scene_switch | 287 | 0.0228 | 0.0337 | 0.0359 | 0.0402 | 0.1076 |
| undo_bridge | 91 | 0.0508 | 0.0513 | 0.0667 | 0.2022 | 0.2000 |

### T4（P3）统一 mutation 审计与保留策略（已完成）

**实现**：router 按 `RouteDoc.mutates()` 在请求级判断 mutation。成功、业务失败、JSON/参数校验失败均恰好记录一次；handler 已记录时不重复，纯只读失败不误记。审计列表支持 safety 过滤；达到 1000 条容量时优先淘汰普通 mutation，保留危险/文件类记录。

**验证**：请求级失败路径见 `tests/e2e/m2/test_mutation_audit.py`；1000 条容量边界由 `tests/fixtures/e2e_project/tests/test_audit_retention.gd` 覆盖，纳入 GDScript 单元门禁。

---

## 2. 能力域差距收口（来源：外部对等复核）

原始复核识别的 3 个缺失域（T5–T7）和 T8 部分覆盖项均已交付；保留原能力域边界与证据来源，逐项结果如下（原始差距证据见[对比报告](../reports/2026-10-03-external-parity-comparison.md)）：

### T5（P2）3D 场景搭建（已完成）

实现 `scene3d/{create,set,info}`，覆盖 Light、Environment/Sky、Camera3D、GridMap、CSG 与 MultiMesh 的创建、配置和读回。3D 物理与导航仍按既定范围排除；真实渲染器 gate 验证 GridMap/MultiMesh 状态和持久化。

### T6（P2）粒子系统（已完成）

实现 `particles/{create,set,info}`，覆盖 GPUParticles2D/3D 的创建、参数写入和运行期状态读取；不以 headless dummy RenderingServer 值伪报非空渲染结果。

### T7（P2）跨场景批量重构（已完成）

实现项目级场景扫描、按节点类型查找、引用/依赖查询，以及 `scene/batch/{plan,validate,apply,recover}` 事务。计划哈希绑定输入；校验、应用、恢复均覆盖失败回滚与真实持久化验证。

### T8（P3）部分覆盖域增强包（已完成）

实现与回归覆盖：

| 能力 | 已交付范围 |
|---|---|
| 运行时录制/回放与属性监视 | 输入录制分页、回放/取消、跨帧属性监视 |
| 编辑器 UI 控制 | Undo/Redo、通知、Inspector/Dock、插件、设置及相机/真实视口控制 |
| 场景操作 | 场景实例化与受保护删除 |
| 资源与 Theme | 通用资源属性写入及落盘读回、纹理预览、Theme 读取 |
| 音频与动画 | Audio bus 属性/effect；AnimationTree blend graph 与参数持久化；运行时 Tween 进度/停止 |
| 项目分析 | `signal_flow`、`scene_complexity`、`script_references`、`project_statistics` 只读诊断 |
| QA 与截图 | 声明式场景测试、压力测试/报告、实际 PNG 像素比较 |
| 节点扩展 | 节点 meta 与显式 allowlist 方法调用 |

接口和行为边界详见 [CHANGELOG](../../CHANGELOG.md) 的 Features/Fixes 条目及相应 route 文档。

---

## 3. 已知行为边界与取舍（如需变更须单独立项）

| 边界 | 说明 |
|---|---|
| 导出子进程使用 `--editor --headless --recovery-mode` | 避免子进程加载 gdapi 插件覆盖父编辑器元数据；副作用是**导出时不加载编辑器插件**，依赖插件改写资源的项目行为会不同（`export_service.gd:52-57`） |
| `export/presets` 不再返回 `templates` | Android 移出时一并删除；调用方无法预判模板可用性，只能从 `export/run` 的 `not_supported` 得知 |
| `runtime/debug/errors` 返回空列表、`breakpoints` 返回 `not_supported` | 已批准的 v1 受限语义（`runtime_probe.gd:551/556`），不是缺陷；如需完整能力须立项 |
| `runtime/eval` 仅 v2 协议可用 | v1 调用方收到 `conflict`，属设计 |
| 3D 物理/导航、Android 平台 | 明确非目标（见目标范围文档） |
| 单编辑器契约 | 任何需要第二个编辑器的验收必须走 `GDAPI_E2E_TRANSPORT` 或显式允许多会话的开关，否则会话级断言（`GODOT_EDITOR_STARTS=1`）会失败 |

---

## 4. 环境 / 交付事项

| 事项 | 影响 / 处理 |
|---|---|
| 本机未安装 Godot 4.7.2 导出模板（`export_templates` 为空） | 桌面 **PCK** 导出已实测不需要模板；导出可执行文件仍需安装匹配模板。 |
| CI | `.github/workflows/verify.yml` 执行统一 `scripts/check.py` 门禁，覆盖格式、lint、clippy、workspace 单测、file E2E、EngineDebugger、真实 OpenGL 渲染和 360s 预算。 |
| headless 全量 E2E 预算 | 默认 **360s**，可用 `GDAPI_E2E_BUDGET_SECONDS` 显式设置；`--gate budget` 实测嵌套全量 **349.612s**，通过且未改变默认阈值。 |

---

## 5. 收口结论

T1–T8 已按各自范围完成实现与验收；T2–T8 的接口与回归入口见 §1–§2 和 [CHANGELOG](../../CHANGELOG.md)。剩余边界仅为表中明确排除的能力，以及本机未安装导出模板导致的可执行文件导出未验收；它们不是本轮被静默缩小的验收项。

---

## 附：复现命令

```bash
# 完整顺序门禁：格式、lint、Rust、file E2E、EngineDebugger、renderer、budget
uv run python scripts/check.py

# 分段执行
uv run python scripts/check.py --gate format --gate clippy --gate unit
uv run python scripts/check.py --gate file
uv run python scripts/check.py --gate engine
uv run python scripts/check.py --gate render
uv run python scripts/check.py --gate budget

# EngineDebugger 数据面（T2）
GDAPI_E2E_TRANSPORT=engine_debugger uv run pytest tests/e2e/m3/test_runtime_status.py tests/e2e/m3/test_runtime_nodes.py -q

# T1：真实文件系统故障下的 hello 发布回归
uv run pytest tests/e2e/test_gdscript_units.py -q -s -k transport

# 运行时生命周期与数据面
uv run pytest tests/e2e/m3 -q -s
```
