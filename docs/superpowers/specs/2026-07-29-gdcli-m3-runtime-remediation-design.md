# gdcli M3 Runtime Remediation Design

日期：2026-07-29
状态：已批准
对应路线图：`docs/superpowers/specs/2026-06-27-gdcli-full-capability-roadmap-design.md`
验收检查：`docs/reports/2026-07-29-gdcli-m3-acceptance-review.md`

## 背景

M3 的目标是让 gdcli 能通过固定、受限、可审计的 runtime probe 检查和操作独立
Godot 游戏进程。公开能力包含 35 条 `runtime/**` route，覆盖连接状态、场景树、节点、
输入、截图、日志、断言、信号和调试信息。

当前实现完成了 route manifest、文档、broker 状态机、EngineDebugger 适配器和 file
transport 骨架，但数据面没有形成闭环。2026-07-29 的完整 M3 E2E 结果为
15 passed / 22 failed，耗时 421.26 秒。主要根因是：

1. 除 `runtime/status` 外，route handler 直接在 editor 进程调用 runtime ops，没有通过
   broker 派发到 game 进程。
2. broker 与 file transport 各自维护独立 pending；broker 发出的请求虽然能进入 inbox，
   但 outbox reply 会被 file transport 当作未知 id 删除。
3. file probe 的同步 scanner 无法可靠完成 screenshot、sequence、assert 和 signal await
   等异步 handler。
4. M3.1 修改遗漏了 `add_debugger_plugin()`，非 headless EngineDebugger 路径没有注册。
5. transport 选择、generation 和 stale probe 清理不足，无法保证 EngineDebugger 优先和
   生命周期隔离。
6. closure plan 的 ring buffer dropped、known logs、reparent cycle、action observation 和
   mutation audit 等缺口没有完全关闭。
7. M3 pytest fixture 为函数级，每个测试重复构建、安装、启动 editor 和运行游戏。四个
   status 测试中 23.67/28.89 秒消耗在 setup。

## Route manifest reconciliation (2026-07-29)

原始 M3 文档把 runtime route 数量写为 35，但已落地的 route/op 清单实际只有 32 条。
经用户确认，缺失的三条公开 runtime route 补齐为：

- `runtime/node/create`
- `runtime/node/duplicate`
- `runtime/node/rename`

三条 route 属于 runtime node mutation family，必须与现有 node route 一样通过 broker 在 game
进程执行，返回 `undoable:false`，成功与拒绝均审计。它们不是 editor-side `node/*` route
的 alias；必须拥有独立 protocol op、route doc、fixture 行为和真实 CLI E2E。补齐后 M3
runtime manifest 精确为 35 条，data-plane route 精确为 34 条。

## 目标

1. 完成 35 条 M3 runtime route 的真实 game-process 数据面闭环。
2. 保持公开 route、protocol v1 和 CLI 行为兼容。
3. 保持 EngineDebugger 为首选 transport，file transport 为 Godot 4.7 headless fallback。
4. 统一 request ID、pending、deadline、reply 和 disconnect 的所有权。
5. 关闭三份 M3 plan 中所有未满足的 P0/P1 缺陷和验收项。
6. 将 M3 E2E 的本地 warm-build 时间降到 60 秒以内。
7. 以可重复的完整验证证据将 roadmap M3 从 🟡 翻为 ✅。

## 非目标

- 不新增、删除或重命名公开 runtime route。
- 不修改 protocol v1 的 request/reply/event 顶层结构。
- 不引入 TCP、WebSocket 或其它第三种 runtime transport。
- 不增加 arbitrary eval、process execution 或 network request。
- 不把 runtime mutation 接入 UndoRedo。
- 不通过降低 E2E 断言、跳过必需环境或改为直接 HTTP 来换取速度。
- 不在 M3 整改中实现 M4 及后续游戏系统域。

## 已确定的边界

- 公开 route 精确保持 35 条。
- `runtime/status` 查询 editor-side broker 状态；其余 34 条 route 通过 broker 派发。
- CLI 仍通过 `gdcli --json exec` 调用 HTTP route。
- EngineDebugger 和 file transport 共享同一 protocol 和 broker。
- file transport 保留为 Godot 4.7 `--headless --editor` 的生产 fallback。
- E2E 默认串行复用一个 editor；不依赖 pytest-xdist。

## 目标架构

### 数据流

```text
gdcli
  │
  ▼
HTTP runtime route
  │
  ▼
GdApiRuntimeRoute.dispatch(route, request, response, mutation)
  │
  ▼
GdApiRuntimeBroker.request(op, payload, timeout, callback)
  │
  ├─ EngineDebugger sender ─┐
  └─ file sender ──────────┤
                            ▼
                   game RuntimeProbe
                            │
                            ▼
                 allowlisted runtime op
                            │
                            ▼
                    protocol v1 reply
                            │
                            ▼
                  broker.receive(reply)
                            │
                            ▼
                    HTTP response once
```

### Runtime route adapter

新增 `gdapi/addon/runtime/runtime_route.gd`，作为 34 条数据面 route 的统一异步适配器。
它负责：

- 获取 `GdApiRuntimeBroker.instance()`；
- 校验 broker 已连接；
- 从 body 解析 operation timeout；
- 调用 `broker.request()`；
- 在 callback 中构造成功 envelope 或标准错误响应；
- 将稳定 error code 映射到 HTTP status；
- 对 mutation 成功和拒绝写入审计日志；
- 保证 response 只发送一次。

route 文件只保留：

- 固定 op 名；
- 是否属于 mutation；
- `doc()`。

route 不再直接加载或调用 `runtime_node_ops.gd`、`runtime_input_ops.gd`、
`runtime_capture_ops.gd` 或 editor SceneTree 中的 runtime probe。

### Broker ownership

`GdApiRuntimeBroker` 是以下状态的唯一所有者：

- 单调递增 request ID；
- pending callback；
- operation name；
- deadline；
- generation；
- exactly-once completion；
- stopped / connecting / connected 状态；
- EngineDebugger/file sender 与 active transport。

transport 不再提供独立业务 `request()` 或 pending map。transport 只实现：

- attach/detach；
- `send(message) -> bool`；
- 把收到的完整 protocol message 交给 `broker.receive(message)`。

broker 在删除 pending 后才调用 callback。reply、timeout、disconnect、game stop 和
plugin exit 对同一 request 最多完成一次。

### Transport selection

broker 分别保存：

- `_engine_sender`
- `_file_sender`
- `_engine_connected`
- `_file_connected`
- `_active_transport`

选择顺序固定为：

```text
engine_debugger > file > none
```

file hello 不得覆盖有效 EngineDebugger sender。EngineDebugger 断开时，如果同 generation
的 file transport 仍存活，则降级到 file；只有 project stop、generation 失效或两个
transport 都断开时才进入 stopped 并失败所有 pending。

`plugin.gd` 必须成对调用：

- `add_debugger_plugin(_runtime_debugger_plugin)`
- `remove_debugger_plugin(_runtime_debugger_plugin)`

### Generation 与 stale transport

每次 `project/run` 先递归清理旧 transport root，再调用 broker `begin_connect()`。
runtime probe 启动时生成新的 generation；file hello 和 EngineDebugger hello 都携带同一个
generation。editor 在本轮 run 收到的第一条有效 hello 绑定 generation，之后拒绝其它
generation。hello event 的 `result` 增加：

- generation
- process ID
- started_at
- transport

这些字段是 event result metadata，不改变 protocol v1 顶层 schema。

editor 只接受当前 generation 的 hello/outbox。以下时机递归清理对应 generation 的
transport 目录：

- 新 run 开始前；
- project stop；
- probe `_exit_tree`；
- plugin `_exit_tree`。

file manager 必须检测 hello 消失、进程退出和 generation 不匹配，并 detach 对应 transport。
过期 hello 不得把 stopped broker 推到 connected。

### File transport reply

editor file transport 的 outbox scanner 读取并删除 reply 后，直接调用：

```text
broker.receive(reply)
```

它不查询 transport-local pending。

probe scanner 在读取完整 inbox 文件后先原子领取/删除请求，再启动独立异步处理。每个
inflight id 只处理一次。异步处理完成后才写入 outbox：

```text
claim inbox
  → await runtime handler
  → validate/encode reply
  → atomic write outbox
  → clear inflight
```

screenshot、frames、sequence、condition 和 signal await 必须覆盖真实 suspend/resume 路径。

## 可靠性契约

### Message bounds

- request 和 reply 最大 4 MiB；
- viewport/camera 最大 1920×1080；
- capture 在 CPU readback 前检查源纹理尺寸；超限源返回结构化
  `invalid_param`，不先分配完整 Image 再缩放；
- frames 最大 60；
- input sequence 最大 100 events / 10 秒。

request 在 route/broker/probe 三层验证；reply 在 probe 和 broker 验证。oversized reply
返回结构化错误，不得表现为静默 timeout。

### Timeout hierarchy

- operation timeout 默认 5,000 ms，最大 25,000 ms；
- broker transport grace 固定 1,000 ms，因此 broker deadline 最大 26,000 ms；
- HTTP handler deadline 保持 30,000 ms；
- CLI 默认 deadline 保持 30 秒，显式值不得小于 operation timeout 加 2 秒。

adapter 负责把用于 broker 的 timeout 与传给 runtime op 的 timeout 分开，避免 operation
刚完成时 broker 或 HTTP 先超时。frames、sequence 和 assert/signal 必须校验其理论总时长
不会超过 operation 上限。

### Error mapping

| Error code | HTTP status |
|---|---:|
| `missing_param` / `invalid_param` / `invalid_path` | 400 |
| `permission_denied` / `unsafe_operation` | 403 |
| `not_found` | 404 |
| `conflict` | 409 |
| `timeout` | 408 |
| `not_supported` | 501 |
| `godot_error` | 500 |

transport 拒绝、disconnect 和 generation 失效使用稳定 code，不得被 CLI helper 转为
`unknown`。

### Mutation 与审计

以下 route 属于 runtime mutation：

- node set/call/remove/reparent；
- input key/mouse/gamepad/touch/action/sequence；
- signal connect/disconnect/emit；
- log clear。

成功响应包含：

- `ok:true`
- `changed`
- `undoable:false`
- 目标或操作摘要

成功与拒绝均写审计事件。审计 redactor 递归移除或替换以下字段：

- token
- password
- secret
- authorization
- cookie

截图 base64、大数组和 Variant 大值只记录类型、大小和摘要，不复制完整 payload。

## Closure defect remediation

### Ring buffer

cursor 从 1 单调递增。`after_cursor` 表示已消费的最后 cursor。若当前最旧 cursor 为
`oldest_cursor`，则：

```text
dropped = max(0, oldest_cursor - (after_cursor + 1))
```

`next_cursor` 为本页最后返回 cursor；空页保持安全且不访问 `_items[0]`。测试必须覆盖：

- cursor 0 之前发生 eviction；
- partial read 后发生 eviction；
- empty read；
- clear 后 read；
- 两页读取无重复。

### Known logs

fixture 的 `emit_known_logs()` 显式调用 `GdApiRuntimeProbe.record_log()` 写入
`known-info` 和 `known-error`。控制台输出可以保留用于人工诊断，但不作为 ring buffer
采集机制。

### Reparent cycle

`runtime/node/reparent` 在修改树之前拒绝：

- node == new parent；
- new parent 是 node 的任意 descendant；
- root/current scene root/probe 等受保护节点；
- 无效或跨 generation 节点。

增加 GDScript unit 和真实 game-process E2E。

### Input action observation

fixture 不依赖 `Input.action_press()` 自动产生 `_input()` event。采用明确的 `_process()`
edge polling 或等价的稳定观测机制，在 pressed 从 false→true 时只增加一次计数，并在
release 后允许下一次 press。

### Debug and async coverage

补齐：

- debug errors v1 empty-list 行为；
- debug breakpoints `not_supported`；
- disconnect during call/sequence/await；
- timeout exactly once；
- oversized request/reply；
- async file handler；
- EngineDebugger priority/fallback；
- stale generation rejection。

## E2E harness design

### Session lifecycle

M3 matrix 使用一个 session-scoped harness：

```text
build workspace once
  → copy/install fixture once
  → start editor once
  → run lifecycle scenario (run/stop × 2)
  → start data-plane game once
  → execute all data-plane tests
  → stop game once
  → stop editor once
```

合并重复 lifecycle 测试，一个 scenario 覆盖：

- initial stopped；
- connecting；
- connected；
- active transport；
- stop；
- 第二轮 run/stop；
- pending 归零；
- transport/generation 清理。

### Per-test isolation

data-plane 测试共享运行中的 game，但每个测试使用 fixture-only allowlisted
`reset_fixture()` 恢复：

- ProbeTarget properties；
- input counters；
- remove/reparent 专用节点；
- fixture signal connections；
- fixture timers；
- runtime log。

destructive route 只操作专用临时节点。reset 失败时 harness：

1. 保留原始测试失败；
2. 收集 runtime status、pending、transport 目录和 Godot log；
3. 重启 game 恢复后续测试；
4. 明确报告发生过 recovery，不能静默掩盖隔离缺陷。

### CLI fidelity

所有 route 行为 E2E 继续调用真实：

```text
gdcli --json exec
```

不以 Python 直接 HTTP 替代。helper 在解析 JSON 前先检查 return code；失败信息包含：

- command；
- exit code；
- stdout；
- stderr；
- runtime/status；
- Godot log tail。

### Waiting and timeouts

- readiness 使用短间隔条件轮询，不使用固定 1 秒 sleep；
- subprocess 均设置明确 timeout；
- 引入 `pytest-timeout` 仅作为防挂死保护；
- 条件测试以状态变化结束，不人为等待完整 timeout；
- `--durations=20` 作为每次验收输出。

### Performance budget

| 指标 | 门槛 |
|---|---:|
| Editor 启动次数 | 1 |
| Game 启动次数 | 最多 3 |
| 本地 warm-build M3 E2E | ≤ 60 秒 |

M3 E2E 默认串行，测试正确性不依赖 pytest-xdist 或固定执行顺序。

## 实施顺序

### Phase 1：锁定失败与组合测试

- 保存 15/37、421.26 秒基线；
- 新增 broker + file transport sync/async 组合测试；
- 复现 reply deletion、async handler、stale hello 和 transport priority；
- 不修改公开 route。

### Phase 2：纵向打通

- 修复 broker/transport ownership；
- 恢复 debugger plugin 注册；
- 新增统一 runtime route adapter；
- 只迁移 `runtime/node/get`；
- 验证 CLI→HTTP→broker→file→probe→reply→CLI。

### Phase 3：快速 harness

- session-scoped editor；
- lifecycle scenario 合并；
- failure diagnostics；
- performance measurement。

此阶段先复用 editor；在 scene/node family 迁移并验证 `runtime/node/call` 与
`reset_fixture()` 后，才启用跨测试共享 data-plane game。此前需要 runtime reset 的测试
仍按 game restart 隔离，避免 harness 依赖尚未打通的 route。

### Phase 4：逐领域迁移

按以下顺序迁移并分别验证：

1. scene/node；
2. input；
3. capture；
4. log/debug；
5. assert/signal。

每组 route 完成后运行该组 unit/integration/E2E，不等所有 route 完成后才验证。

### Phase 5：Closure defects and safety

- ring buffer；
- known logs；
- reparent cycle；
- action observation；
- audit/redaction；
- bounds/timeout/disconnect/exactly-once/generation cleanup。

### Phase 6：Final closure

- Rust/GDScript/M1/M2/M3 全量验证；
- 性能验收；
- 更新 roadmap 和 closure report；
- 所有门槛满足后才把 M3 标为 ✅。

## Acceptance criteria

1. 原 closure plan 的 10 条 M3 acceptance criteria 全部通过。
2. `gdapi/routes` 恰好包含 35 条 runtime route，无额外 runtime route。
3. 34 条数据面 route 全部通过 broker 在 game 进程执行。
4. 每条 route 至少有一个有效行为测试；mutation、安全拒绝和异步 route 另有反例。
5. headless E2E 使用 file transport；EngineDebugger 注册、优先级和 fallback 有独立验证。
6. request/reply ≤4 MiB，capture/input/frames 限制全部有边界测试。
7. 所有 runtime mutation 返回 `undoable:false`，成功与拒绝均审计且 secret 被 redacted。
8. 两轮 lifecycle 和完整 suite 后 `pending == 0`，无 stale probe 目录、残余 game process、
   signal connection 或 timer。
9. `cargo fmt --check`、`cargo clippy --workspace`、`cargo test --workspace` exit 0。
10. GDScript unit 和完整 `tests/e2e/` 全绿；必需环境失败不得 skip。
11. 本地 warm-build M3 E2E ≤60 秒，并保存 `--durations=20` 证据。
12. closure report 记录实际命令、exit code、测试数量、transport 和耗时。

## Rollback strategy

实施按纵向 slice 和 route family 分阶段提交。若某阶段不能满足其组合测试：

- 不回退 protocol 或公开 route；
- 保留上一阶段已验证的 broker/transport core；
- 回退当前 route family 的 adapter 迁移；
- 用失败的最小组合测试继续定位；
- 不恢复 editor-process 本地 runtime ops 作为临时 fallback。
