# gdcli 遗留问题清单（开专题用）

日期：2026-10-03
来源：[目标收口报告](../reports/2026-10-03-gdcli-goal-closure.md) + [外部能力对等复核](../reports/2026-10-03-external-parity-comparison.md)
用法：**每个 T 编号独立立项**。每条给出「证据 → 影响 → 建议调查路径 → 验收标准 → 规模」，可复现命令附在文末。

优先级：`P1` = 影响验收可信度，`P2` = 影响能力面，`P3` = 行为取舍/环境。

---

## 1. 工程遗留问题

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

### T2（P2）EngineDebugger 数据面尚未进入默认验收

**证据**：本轮已实测 headless 与 GUI 会话下 `transport=engine_debugger`（协议 v2、PNG 截图、输入生效、stop 正常），但默认套件仍强制 file transport（fixture 的 `runtime_force_file_transport=true`）；debugger 路径只能通过 `GDAPI_E2E_TRANSPORT=engine_debugger` 手动验收（m3 status+nodes 29 passed）。
**影响**：debugger 通道的回归不会在默认运行中暴露。
**建议**：二选一——(a) 增加 marker（如 `engine_transport`）门控的独立验收模块并在文档/流程中要求定期执行；(b) 让 fixture 支持「同一会话先 file 后 debugger」或独立会话的双 transport 矩阵（注意单编辑器契约：需要显式允许多会话的开关）。
**验收标准**：debugger 数据面的验收成为一条可重复、被记录的命令（已具备），且失败能被流程捕获（CI 或清单）。
**规模**：0.5–1 天。

### T3（P3）负载敏感的超时余量

**证据**：观测到 3 类超时偏紧——m2/m4 的 `gdapi_test` undo 桥 2s、`wait_for` 默认 5s、m3 输入用例显式 2s；已统一放宽到 10s/15s。另有 `E2E_SCENE_SWITCH_TIMEOUT_SECONDS = 5.0`（`shared_fixture.py`）与 budget 的 360s 阈值同样依赖本机性能。
**影响**：更弱的机器/更高并发下仍可能偶发失败；放宽超时只影响失败路径耗时。
**建议**：在单次全量运行中采集各 `wait_for`/桥等待的真实耗时分布（成功路径），据此设定「本机 P99 × 3」的余量；必要时把 budget 阈值改为可配置。
**规模**：1–2 小时。

### T4（P3）统一 mutation 审计的语义边界

**证据**：`gdapi/addon/runtime/router.gd::_audit_mutation` 仅在「响应含 `changed` 且本次请求未新增审计条目」时补记，因此：
- 非危险 mutation 的**失败**（错误响应无 `changed`）不会留下中央审计条目（危险/文件类操作各自记录成功与失败）；
- 审计 buffer 上限 1000 条，重 mutation 流量下可能挤掉早期危险操作记录。
**影响**：审计用于排障时，非危险 mutation 的失败不可见；极端流量下危险记录可能被淘汰。
**建议**：(a) 给 `gdapi/audit/list` 增加 `safety` 过滤并支持「危险类优先保留」的淘汰策略；(b) 让 router 在 mutation 路由的错误响应上也能补记（需要请求级 mutation 判定，例如按路由是否在 `changed`-contract 集合）。
**规模**：0.5–1 天。

---

## 2. 能力域差距（来自外部对等复核）

对等复核结论：27 个能力域中 **13 等价 / 11 部分 / 3 缺失**。缺失与主要部分项如下（逐条证据见[对比报告](../reports/2026-10-03-external-parity-comparison.md)）：

### T5（P2）3D 场景搭建——缺失
外部证据：youichi `scene_3d_commands.gd:9-16`；DaxianLee `lighting_tools.gd:11/94/161`、`geometry_tools.gd:11/97/175`。
范围建议：light/environment/sky/camera3d/gridmap/CSG/MultiMesh 的创建与参数设置（**不含** 3D 物理/导航，后者仍是明确非目标）。
**规模**：1–2 天（含 fixture 场景与行为断言）。

### T6（P2）粒子系统——缺失
外部证据：youichi `particle_commands.gd:6-12`；DaxianLee `particle_tools.gd:11/102`。
范围建议：GPUParticles2D/3D 创建、参数（amount/lifetime/emitting/材质）与少量运行期观测。
**规模**：0.5–1 天。

### T7（P2）跨场景批量重构——缺失
外部证据：youichi `batch_commands.gd:9-17`（batch_set_property、cross_scene_set_property、find_nodes_by_type、find_node_references、get_scene_dependencies）。
说明：现有 `filesystem/batch/*` 只做文件级事务，`node/find` 只覆盖单场景。
范围建议：项目级扫描 + 计划/校验/应用三段式（沿用现有 `plan_hash` 与 recover 语义）。
**规模**：1–2 天。

### T8（P3）部分覆盖域的增强包

按价值排序（每条含外部证据，均见对比报告）：

| 增强项 | 现状缺口 |
|---|---|
| 运行时录制/回放与属性监视 | 无 start/stop/replay_recording、monitor_properties |
| 编辑器 UI 控制面 | 无 undo/redo 触发、通知、inspector/dock、插件管理、编辑器设置/相机 |
| 场景实例化与删除 | 无 `add_scene_instance`、`delete_scene`（节点只能按类名创建） |
| 资源通用属性写入/纹理预览 | 只有 material/shader/theme 类型专用写入 |
| 音频 bus 属性与 effect | 只有 bus 增删与 player 播放控制 |
| 动画树删除/blend tree/tween | 只有 state/transition 新增与 blend/set |
| 代码分析扩展 | 只有 unused_resources/cycle_deps/script_errors/health |
| 测试/QA 框架化 | 只有 runtime/assert/*（无场景测试脚本、压力测试、报告） |
| 截图对比与编辑器视口 | 只有 viewport/camera/frames 截图 |
| 节点 meta 与编辑期任意方法调用 | 缺 set_meta 与受控 call |
| Theme 读取 | 只能写，不能读回值（测试靠 resource/info 间接验证） |

**规模**：每项 0.5–2 天；建议按需立项，不做批量补齐。

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

| 事项 | 影响 |
|---|---|
| 本机未安装 Godot 4.7.2 导出模板（`export_templates` 为空） | 桌面 **PCK** 导出已实测不需要模板；导出可执行文件/移动端则需要安装模板 |
| 无 CI：门禁与 E2E 均需手动在本机执行 | 建议把 `cargo test`、`gdformat/gdlint`、非预算 E2E、budget 四条命令固化为脚本/流水线 |
| budget 阈值 360s 依赖本机性能（当前实测 302–320s） | 换机器需重新标定 |

---

## 5. 建议立项顺序

T1 的握手发布缺陷已修复，证据见 §1；其余问题按以下顺序立项：

1. **T2 + 4 中的「CI/脚本化」**（把已建立的验收入口固化）
2. **T5 / T7**（3D 场景搭建、跨场景批量重构：能力面最大的两块）
3. **T6** 与 **T8** 中按需项
4. **T4 / T3**（审计与超时余量的精细化）

---

## 附：复现命令

```bash
# 门禁
cargo fmt --check && cargo clippy --workspace --all-targets -- -D warnings && cargo test --workspace
python scripts/format-gd.py && python scripts/format-gd.py --check && gdlint $(git status --porcelain | grep '\.gd$' | awk '$1!="D"{print $2}')

# 默认（file transport）非预算全量
uv run pytest tests/e2e -q -s

# 预算验收（嵌套全量 + walltime ≤360s + 单编辑器）
uv run pytest tests/e2e/test_full_suite_budget.py -m budget -v

# EngineDebugger 数据面（T2 的入口）
GDAPI_E2E_TRANSPORT=engine_debugger uv run pytest tests/e2e/m3/test_runtime_status.py tests/e2e/m3/test_runtime_nodes.py -q

# T1：真实文件系统故障下的 hello 发布回归（立即 open 失败与延迟 rename 失败）
uv run pytest tests/e2e/test_gdscript_units.py -q -s -k transport

# 运行时生命周期与数据面
uv run pytest tests/e2e/m3 -q -s
```
