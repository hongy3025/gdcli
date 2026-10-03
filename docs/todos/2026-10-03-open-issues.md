# gdcli 遗留问题清单（开专题用）

日期：2026-10-03
来源：[目标收口报告](../reports/2026-10-03-gdcli-goal-closure.md) + [外部能力对等复核](../reports/2026-10-03-external-parity-comparison.md)
用法：**每个 T 编号独立立项**。每条给出「证据 → 影响 → 建议调查路径 → 验收标准 → 规模」，可复现命令附在文末。

优先级：`P1` = 影响验收可信度，`P2` = 影响能力面，`P3` = 行为取舍/环境。

---

## 1. 工程遗留问题

### T1（P1）运行时 harness 偶发握手失败——唯一仍未定位的问题

**证据**
- 6 次全量运行中出现 1 次：`m3_running` 的 probe 在 60s 内未连接（`state=connecting`、`transport=none`、`editor_playing=true`），级联同模块 14 个用例 error；同时单独运行 `tests/e2e/m3` 为 **123 passed**，其余全量运行也全绿。
- 相关代码：`tests/e2e/m3/conftest.py`（`attach_game`、`wait_for_connected`，重试上限 `RECOVERY_RESTART_LIMIT = 1`）、`tests/e2e/shared_fixture.py`（session 级单编辑器）。
- 已做的缓解（不构成修复）：`attach_game` 失败时打印 `runtime/status` + `.godot/gdapi_runtime` 目录内容 + 编辑器 console 尾部；失败后清理并重试 1 次。

**影响**：全量 E2E 偶发红，CI/验收可信度受损；功能本身未见缺陷。

**建议调查路径**
1. 统计复现率：连续跑完整套件 5 次，记录失败次数与失败点（文件/模块），确认是否只出现在 module 级 fixture 首次 attach。
2. 采集时间线：在 `wait_for_connected` 期间每 5s 打印一次 `runtime/status`，并同时记录 `.godot/gdapi_runtime` 下的文件出现顺序（`hello.json`/`inbox`/`outbox`），对比成功与失败两次运行。
3. 验证假设（按可能性排序）：
   - a. **transport 选择竞态**：probe 先尝试 EngineDebugger、再回落 file；若此前有残留 session/文件，可能一直停在 connecting。用 `GDAPI_E2E_TRANSPORT=engine_debugger` 与默认 file 两种模式各跑多次对比。
   - b. **编辑器主线程拥塞**：上一测试遗留的重负载（如大文件写入/恢复）让 `play_custom_scene` 与 debugger attach 延迟超过 60s。可在同一台机器上把并发任务清空后复跑。
   - c. **reset 清理不彻底**：`reset_shared_state` 只做 stop/close/open/selection/audit，没有显式清 `.godot/gdapi_runtime`；残留会干扰下一次 attach。
   - d. 机器/磁盘瞬时故障（Windows 句柄竞争）。

**验收标准**：连续 5 次全量运行 0 次该失败；或给出根因并落地「真实修复」（不只是放宽超时/加重试）。

**规模**：1–3 小时（取决于是否复现）。

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

1. **T1**（唯一未定位的稳定性问题，直接影响验收可信度）
2. **T2 + 4 中的「CI/脚本化」**（把已建立的验收入口固化）
3. **T5 / T7**（3D 场景搭建、跨场景批量重构：能力面最大的两块）
4. **T6** 与 **T8** 中按需项
5. **T4 / T3**（审计与超时余量的精细化）

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

# 运行时握手诊断（T1 复现时看 [attach_game] 输出）
uv run pytest tests/e2e/m3 -q -s
```
