# gdcli 分支总目标与范围（Android 除外）

日期：2026-10-03
状态：生效，取代此前路线图中关于平台范围的描述
分支：`feat/full-capability`
关联：收口计划见 [`docs/superpowers/plans/2026-10-03-gdcli-goal-closure.md`](../plans/2026-10-03-gdcli-goal-closure.md)

## 1. 总目标

把 gdcli 从「Godot LSP 查询客户端」扩展为**通用 Godot 编辑器和运行时操作工具**：

1. `gdcli exec <route> --data <json>` 通过运行中编辑器内的 gdapi 插件操控编辑器；
2. gdapi 的 Rust 部分保持极薄，只负责 HTTP 监听、协议编解码与主线程队列；业务能力全部由 GDScript 路由实现；
3. 路由按文件系统自动注册，具备结构化自描述、统一错误码、明确 mutation/UndoRedo 语义、稳定边界与审计；
4. 现有 LSP 能力保持不变，继续通过 `gdcli lsp` 使用；
5. 每条能力都必须有可重复执行、能被真实行为断言证明的验收方式。

**平台范围：仅 Windows / macOS / Linux 桌面编辑器与桌面导出目标。Android 平台相关内容不属于本分支目标。**

## 2. 非目标（明确不做、不作为验收项）

| 非目标 | 说明 |
|---|---|
| **Android 平台全部能力** | 设备查询、APK/AAB 打包、单设备部署、多设备部署、ADB 集成、Android 导出预设与 Android 导出模板判断，一律不属于目标、不承诺支持、不进入验收清单、不要求 Android SDK/ADB 或真实设备。 |
| 恢复 policy / force 门禁 | 2026-08-01 起 gdcli 定位为开发期工具，取消 `capability_policy` 与 `force:true`。此决定继续有效。 |
| MCP server、外部工具名或参数的一比一兼容 | 采用能力等价，不复刻外部项目命名。 |
| 3D Physics / 3D Navigation | M4 已批准只支持 2D；3D 参数稳定返回 `not_supported`。 |
| EngineDebugger 断点接管与详细错误回溯 | 已批准为 v1 受限语义（`runtime/debug/breakpoints` 返回 `not_supported`，`runtime/debug/errors` 返回空列表），不视为缺口。 |
| Godot 4.3–4.6 兼容矩阵 | 支持范围是 Godot 4.7.x；当前验证基线 4.7.2。 |

### 2.1 Android 既有实现的处理

Android 相关实现已于 2026-10-03 **从代码树移除**（不再"保留但不验收"）：

- 删除路由 `export/android/{devices,deploy,deploy_many}` 及服务 `android_bridge.gd`、`bulk_deploy_service.gd`；
- 删除 Android 专用 E2E / 单元测试与 fixture（含 Android 导出预设）；
- 里程碑 route manifest 不再包含 Android 路由（M5 = 25、M6 = 7）；
- `export/run` 对全部预设统一使用桌面 `--export-pack` 语义；`export/presets` 不再返回仅为 Android 服务的模板可用性字段。

如将来重新需要 Android 支持，应按新需求重新设计；历史实现可从 git 历史取回，不作为当前目标或验收依据。

## 3. 目标能力域（全部为非 Android）

| 能力域 | 内容 | 主要路由前缀 |
|---|---|---|
| 通信与安装 | loopback HTTP、Bearer token、端口发现、插件安装与 addon 部署、路由自描述 | `gdapi/*`、`command/*`、`console/output`、`godot/version` |
| 基础编辑 | 场景、节点、属性、信号、分组、脚本、文件系统、资源、编辑器 UI、UndoRedo | `scene/*`、`node/*`、`script/*`、`filesystem/*`、`resource/*`、`editor/*` |
| 运行时验证 | broker 双 transport、场景树、节点操作、输入模拟、截图、日志、断言、信号等待 | `runtime/*`（35 条） |
| 游戏系统 | Animation/AnimationTree、TileMap、Material/Shader、Audio、UI/Theme、2D Physics、2D Navigation | `animation*`、`tilemap/*`、`material/*`、`shader/*`、`audio/*`、`ui/*`、`theme/*`、`physics/*`、`navigation/*` |
| 项目与诊断 | 项目设置、InputMap、Autoload、ClassDB、UID 修复、项目健康诊断 | `project/*`、`classdb/*`、`uid/*`、`diagnostics/*` |
| 导出（桌面目标） | 导出预设发现、非 Android 预设的受控导出（PCK/Pack）与产物校验 | `export/presets`、`export/run` |
| 高风险能力（默认可用，硬上限约束） | 受限表达式、运行期表达式、无 shell 进程、HTTP/HTTPS 请求、批量文件事务 | `editor/eval`、`runtime/eval`、`process/run`、`network/http_request`、`filesystem/batch/*` |

## 4. 全局约束

1. **Godot 版本**：运行与验收基线为 4.7.2；godot-rust `0.5.4` / `api-4-7`，`.gdextension` 的 `compatibility_minimum = 4.7` 不变，不因补丁版本升级提高最低要求。
2. **安全姿态**：开发期工具；鉴权由 loopback + Bearer token 承担；保留内置硬上限（eval ≤16 KiB、process ≤60s/≤1 MiB、network 仅 http(s)/≤60s/≤4 MiB/≤5 重定向、export ≤600s）与审计日志（不含 secret）。
3. **Mutation 模型**：编辑器状态 mutation 返回 `undoable:true` 并接入 UndoRedo；文件/资源/运行期 mutation 返回 `undoable:false`，并在失败时不留部分状态。
4. **契约**：仅 POST + JSON object body；成功 `ok:true`；错误使用标准 10 错误码；`doc()` 必须与实际参数、返回字段一致。
5. **验收证据**：只把实际执行并通过的结果记为通过；环境性跳过必须写明原因，并且不得把「功能未实现」伪装成「环境跳过」。

## 5. 验收标准

### 5.1 通用标准（每条公开路由）

- 路由可发现、有 summary/params/returns/example，且与实现一致；
- 参数错误、路径错误、对象不存在、拒绝与 Godot 失败返回稳定 code；
- 失败路径无副作用、无残留文件、无 pending 请求；
- mutation 明确 `undoable` 语义；编辑器状态 mutation 必须能真实 undo/redo 并观察结果；
- 危险操作产生去敏审计记录（成功与失败）。

### 5.2 能力域验收

| 能力域 | 验收要点 |
|---|---|
| 基础编辑 | 节点/属性/信号/分组/脚本/资源/文件的增删改查在真实编辑器中生效；编辑器状态 mutation 逐步 undo/redo 后与磁盘一致；保存并重开后结果一致 |
| 运行时验证 | `runtime/status` 三态正确；数据面经 broker 到达真实游戏进程；输入/截图/日志/断言/信号有可观察结果；stop/disconnect 后 pending 清零且清理 transport |
| 游戏系统 | 每个域具备创建、查询、修改、保存、重开读回的行为断言；运行期路由必须证明在运行中的游戏里执行 |
| 项目与诊断 | 配置变更可快照恢复且不在项目中留下污染；诊断结果与 fixture 中故意制造的问题对应；UID 修复可重复执行且幂等 |
| 导出 | 预设发现返回真实预设；桌面预设导出产出产物且 size/sha256 与产物一致；失败时删除残留产物并返回稳定 code |
| 高风险能力 | 受限表达式拒绝越界输入；进程无 shell、超时/输出上限/取消各只有一次终态；网络限制逐跳生效；批量文件操作具备事务性与可恢复语义，失败不留部分状态 |

### 5.3 验收基础设施要求

- 完整 E2E 套件只启动 **一个** Godot 编辑器进程，并有机器可校验的断言；
- 每个测试的状态隔离可预测：文件与运行时状态在每个测试前后恢复，恢复失败必须使该测试失败而不是被吞掉；
- 全套非预算 E2E 不超过 360 秒，且预算测试本身可在本机执行并通过；
- GDScript 门禁（`gdformat` / `gdlint`）与 Rust 门禁（`cargo fmt --check`、`cargo clippy`、`cargo test`）在本分支上全绿。

## 6. 与既有文档的关系

- 本文件是该分支**当前目标的权威表述**；此前"全功能能力路线图"中涉及 Android 的里程碑与验收条目随本次范围变更失效。
- 2026-06-27 路线图、各里程碑 closure 报告、`.superpowers/sdd/**` 及历史计划保留为**历史证据**，不得作为当前完成度依据，也不回改其数字。
- 收口范围、任务顺序与验收命令见收口计划；范围变更记录以本文件 + 计划为准。
