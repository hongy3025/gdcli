# gdcli 全功能能力路线图实现审计报告

日期：2026-07-30

审计基线：

- 分支：`feat/full-capability`
- HEAD：`8fa22c85ea6001bc6969f995d92a6f7ef51724dc`
- 设计文档：`docs/superpowers/specs/2026-06-27-gdcli-full-capability-roadmap-design.md`
- Godot：`D:\app\devel\Godot\v4.7.1\godot_console.exe`
- 审计范围：M1–M6 的公开 route、共享基础设施、安全合同、自动化测试和文档一致性

## 结论

当前实现不能认定为“路线图完整实现”。

能力表面已经基本铺齐：仓库包含 192 个文件系统 route，加上 4 个内置 route，共 196
个公开 route；M1–M5 的目标 route 基本存在，M6 的 8 个高风险 route 也已加入。但是，
“代码存在”和“满足验收”之间仍有明显断层：

| 里程碑 | 判定 | 说明 |
|---|---|---|
| M1 | 完成 | 39/39 专项 E2E 通过；版本、PathGuard、route doc、审计和 UndoRedo 均有新鲜证据 |
| M2 | 完成 | 54/54 专项 E2E 通过；测试耗时 8 分 58 秒，harness 效率较低但行为闭环 |
| M3 | 主体完成，当前合同不绿 | 120/122；M6 新增 `runtime/eval` 后，35-route manifest 合同未同步 |
| M4 | 主体完成，当前合同不绿 | 30/31；51 条 M4 route 和领域行为通过，唯一失败同样来自 runtime route 数量 |
| M5 | 实现表面完成，验收不足 | 27 条原始 M5 route 存在，但只有 4 项浅层 E2E，未证明大部分正式验收 |
| M6 | 未完成 | 8 条 route 已存在，但 runtime eval、网络安全、终态审计、批量回滚和专项 E2E 未收口 |

发布级判断为 **No-Go**。应先修复 M6 的安全和语义缺口，再补齐 M5/M6 验收，最后恢复
跨里程碑合同和文档一致性。

## 审计方法

每项设计要求按四层证据核对：

1. **公开能力存在**：route、service、runtime helper 和 Rust 模块存在。
2. **实现语义符合设计**：调用链、安全边界、错误合同、UndoRedo 和审计逻辑与设计一致。
3. **自动化验证存在**：测试真正执行正例、反例、无副作用、持久化或运行期终态。
4. **新鲜运行通过**：在本次审计中重新运行，而不是引用旧 closure report。

仅有文件、route 或测试名称不计为完整验收。

## 新鲜验证结果

### 格式、构建和单元层

| 命令 | 结果 |
|---|---|
| `python scripts/format-gd.py --check` | 通过；533 个 GDScript 文件 |
| `cargo fmt --check` | 通过 |
| `cargo clippy --workspace` | exit 0；3 个 warning，0 error |
| `cargo test --workspace` | 202 passed |
| `uv run pytest tests/e2e/test_gdscript_units.py -v` | 20/20 suite passed |

Clippy warning 为既有代码质量问题：

- `gdapi/rust/src/http.rs` 可使用 `std::io::Error::other`。
- `PendingMap` 有 `len()` 但没有 `is_empty()`。
- CLI clap-style formatter 存在可折叠 match/if。

这些 warning 不阻断当前构建，但不应在 closure 报告中描述为“lint clean”。

### E2E 分组结果

单次 `uv run pytest tests/e2e/ -v --durations=20` 在 15 分钟外层超时内没有取得终态，
pytest 在退出时发生 Windows `OSError: [Errno 22] Invalid argument`。超时后残留的
pytest/Godot/gdcli 进程已按 PID 清理，最终进程数为 0。

随后按里程碑分组重新运行：

| 测试组 | 结果 | 耗时 |
|---|---:|---:|
| M1 顶层 E2E | 39 passed | 35.37s |
| M2 | 54 passed | 538.46s |
| M3 | 120 passed, 2 failed | 49.22s |
| M4 | 30 passed, 1 failed | 323.51s |
| M5 | 4 passed | 46.44s |
| GDScript unit harness | 20 passed | 18.17s |

分组汇总为 **267 passed、3 failed**。三个失败均是 M6 新增 `runtime/eval` 后，历史测试
仍断言 runtime route 精确为 35 条：

- `tests/e2e/m3/test_m3_contract.py::test_runtime_manifest_match`
- `tests/e2e/m3/test_m3_contract.py::test_runtime_manifest_has_no_aliases`
- `tests/e2e/m4/test_m4_contract.py::test_m4_bridge_does_not_add_runtime_routes`

这说明 M3/M4 原有数据面没有出现大面积回归，但当前 HEAD 的公开 route 合同不是全绿状态。

## M1：现有基础设施收口

### 已确认完成

- godot-rust 为 0.5.4，启用 `api-4-7`。
- `.gdextension` 和 fixture 都要求 Godot 4.7。
- 旧 `routes`、`commands`、`help` alias 被拒绝。
- router 新增、修改、删除热重载测试存在并通过。
- PathGuard 的 read/write/delete mode 和保护目录反例通过。
- 现有离线 scene mutation 明确返回 `undoable:false`，覆盖需要 `force:true`。
- VariantCodec、request、route doc 和 EditAction 已进入自动化 GDScript 测试链。
- route literal error code 仅使用 10 个标准 code。
- `gdapi/audit/clear` 使用正确公开路径。
- `command/doc` 完整性测试覆盖当前全部公开 route。

### 质量评价

M1 达到设计验收标准。本次没有发现阻断性功能缺口。

## M2：基础编辑闭环

### 已确认完成

- Scene current/open/save/close/tree/list-open。
- Node CRUD、属性、层级和 selection。
- Script read/create/write/patch/attach/detach/current/open/validate。
- Filesystem list/read/write/search/grep/reimport。
- Resource info/deps/search/reimport/assign/create/delete/move。
- Signal 和 group 查询、修改、保存重开。
- Vector、Color、NodePath 和 Resource 的 VariantCodec 往返。
- editor mutation 的逐步 UndoRedo。
- 文件和资源覆盖/删除的 `force:true` 防护。

### 质量风险

M2 fixture 为每个测试重新 build/install/启动 Godot editor，54 项测试耗时 8 分 58 秒。
这不是功能失败，但使完整 E2E 容易超过常规外层 timeout，也降低回归反馈速度。后续应在不
牺牲测试隔离的前提下，改为按模块复用 editor、通过 fixture reset 恢复状态。

## M3：Runtime 验证闭环

### 已确认完成

- 原有 35 条 M3 route 中，34 条数据面 route 经 broker/probe。
- file fallback transport、EngineDebugger 优先级和连接状态单元测试通过。
- runtime node、input、capture、log/debug、assert/signal 数据面测试通过。
- 两次生命周期、pending 清零、timeout/disconnect 和 signal/timer cleanup 通过。
- 122 项专项测试中 120 项通过。

### 当前缺口

M6 新增 `runtime/eval` 后，runtime route 总数变为 36。M3 manifest 测试仍把整个
`runtime/**` namespace 等同于 M3 的 35 条 route，导致 2 项失败。

正确做法不是把 M3 基线改成 36，而是保留 `M3_RUNTIME_ROUTES` 精确集合，并单独维护
`POST_M3_RUNTIME_ROUTES = {"runtime/eval"}`。M3 测试应证明：

- M3 自身仍精确为原 35 条。
- M6 新 route 不冒充 M3 能力。
- 公开表面中不存在 alias 或重复项。

## M4：游戏系统域

### 已确认完成

- 51 条 M4 route 精确存在且有结构化文档。
- Animation/AnimationTree、TileMap、Material/Shader、Audio、UI/Theme、2D Physics、
  2D Navigation 的专项测试覆盖查询、mutation、UndoRedo、保存和运行期验证。
- 31 项专项测试中 30 项通过。

### 当前缺口

唯一失败是 `test_m4_bridge_does_not_add_runtime_routes` 仍断言所有 runtime route 共 35 条。
测试本意是防止 M4 私自在 `runtime/**` 下增加 bridge，应改为断言 M4 route 集合与
`runtime/**` 不相交，并复用 M3/M6 显式 route 集合，而不是固定整个 namespace 数量。

## M5：项目、诊断与发布

### 实现表面

以下 27 条原始 M5 route 均存在：

- Project settings：4 条。
- InputMap：5 条。
- Autoload：3 条。
- ClassDB：6 条。
- UID repair：1 条。
- Diagnostics：4 条。
- Export/Android：4 条。

对应 service 也存在：

- `project_config.gd`
- `classdb_query.gd`
- `uid_repair.gd`
- `diagnostics.gd`
- `export_service.gd`
- `android_bridge.gd`

### 验收证据不足

`tests/e2e/m5/` 只有 4 个测试：

1. route 存在且文档有 summary/returns。
2. `classdb/class`、cycle deps、script errors、export presets 冒烟。
3. UID repair 与 Android deploy 在缺少 `force:true` 时拒绝。
4. fixture snapshot helper 能恢复直接写入的 `project.godot`。

下列设计验收没有被实际证明：

- settings/InputMap/autoload 通过公开 route mutation 后可恢复，且不污染后续测试。
- ClassDB classes/methods/properties/signals/inheriters 的分页、过滤和稳定结构。
- health、unused resources、cycle deps、script errors 对 fixture 刻意问题的精确结果。
- UID repair dry-run/apply、稳定 UID 和第二次运行幂等性。
- `export/run` 生成真实产物并校验产物内容或摘要。
- 缺少 export template 时返回稳定 `not_supported` 或环境错误。
- Android 无设备时的稳定终态。
- 指定无效设备、设备状态变化和显式部署确认。

因此，M5 当前只能认定为“能力表面已实现”，不能认定为“路线图验收完成”。

## M6：高风险能力

### 已实现的骨架

公开 route：

- `editor/eval`
- `runtime/eval`
- `process/run`
- `network/http_request`
- `filesystem/batch/delete`
- `filesystem/batch/replace`
- `filesystem/batch/recover`
- `export/android/deploy_many`

共享模块：

- fail-closed capability policy。
- deferred task registry。
- audit recursive redaction。
- restricted eval service。
- Rust shell-free process runner。
- process/network/bulk file/bulk deploy service。

已有新鲜通过证据：

- capability policy GDScript unit。
- deferred registry GDScript unit。
- eval service GDScript unit。
- Rust process runner 的 argv fidelity、timeout/reap、combined output cap 和 cancel。

### 缺口 1：`runtime/eval` 未在运行游戏进程执行

`routes/runtime/eval.gd` 只检查 broker 对象存在且有 `request` 方法，然后直接在编辑器进程
调用 `EvalService.execute()`。插件启动时 broker 对象始终存在，因此游戏未运行时也可能
执行成功，而不是返回 `conflict`。

protocol 虽增加 `VERSION_V2 = 2` 和 v2 validation，但：

- request/reply/event builder 仍固定写 `VERSION = 1`。
- broker status 仍报告 v1。
- broker receive 只接受 v1。
- probe rejection 和 handshake 仍固定 v1。
- 没有真实的 v2 negotiation 或 `eval` probe handler。

这违反“runtime 能力经 broker → probe 在游戏进程执行”的架构边界。

### 缺口 2：网络 SSRF 防护不完整

`network_service.gd` 只解析 URL 字符串并比较 scheme/host/port，没有：

- DNS 解析及解析后 IP 分类。
- DNS rebinding 防护。
- 完整 IPv4 loopback/private/link-local/multicast/unspecified 分类。
- IPv6 literal 和 IPv4-mapped IPv6 分类。
- 每次 redirect 的重新解析和授权。

当前 `_is_private_host()` 只覆盖 `localhost`、`127.0.0.1`、`::1`、`10.*`、
`192.168.*` 和 `172.16.*`，遗漏大量禁止目标。

实现把 `HTTPRequest.max_redirects` 设为 0；这可以视为“拒绝所有 redirect”，但不能支持
文档声称的“每个重定向重新验证”。代码和安全文档必须选择并落实同一语义。

### 缺口 3：异步操作没有按终态审计

`process/run` 在进程注册成功后立即写 `ok:true` 审计。之后进程即使超时、退出失败或插件
关闭，审计仍显示成功。

`network/http_request` 只审计 policy/validation rejection；请求完成、HTTP错误、timeout 和
deferred cancellation 没有终态审计。

设计要求成功、失败、超时、安全拒绝均产生去敏审计，必须把审计写入 deferred task 的唯一
终态完成路径。

### 缺口 4：eval allowlist 不完整

`EvalService._validate_source()` 使用 substring blacklist：

- `=` 会同时拒绝设计声称允许的 `==`、`<=`、`>=` 比较。
- `ALLOWED_GLOBALS` 循环没有产生任何拒绝效果。
- 未建立 token/identifier 级 allowlist。
- 只检查输入是否包含 Object，没有在返回前拒绝 Object/RID/Callable/Script/Resource 等逃逸值。

这既造成误拒绝，也不足以作为高风险表达式的安全边界。

### 缺口 5：批量文件操作不是全事务

`bulk_file_service.gd` 的 replace 逐文件写入：

- 第 N 个文件失败时，前 N-1 个文件不会回滚。
- `regex` 参数被读取但未实现，实际始终使用字面替换。
- staging 文件失败时可能留下 `.gdcli-replace-tmp`。
- apply 后没有集中 reimport 或变更摘要。

delete 会移动同名 `.uid` 并把 `uid_trash` 写入 manifest，但 recover 只恢复主文件，不恢复
`.uid`。recover 成功后也没有明确清理 manifest/trash 目录或防止重复恢复的终态合同。

### 缺口 6：批量部署验证不足

`deploy_many` 有 plan hash 和排序后的 serial，但没有专项测试证明：

- dry-run 与 apply 间 APK 内容变化会 conflict。
- 设备集合或设备状态变化会 conflict。
- 部分设备失败时所有设备都有明确终态。
- 没有设备或 adb 不可用时返回稳定错误。
- 每个设备结果和整体结果均被正确审计。

### 缺口 7：没有 M6 E2E

仓库没有 `tests/e2e/m6/`。`tests/fixtures/m6_project/` 只有三个 process runner Python 脚本，
没有 Godot project、policy variants、网络 fixture、批量文件 fixture 或 fake Android bridge。

原 M6 implementation plan 的 41 个 checkbox 全部仍为未完成状态。当前提交一次性增加大量
实现，但没有执行 plan 中的 red-green 和逐任务验收。

## 统一 route contract 评价

### 已满足

- 所有公开 route 都能被 router 发现。
- `command/doc` 完整性检查通过。
- literal error code 静态检查通过。
- M1–M4 mutation 普遍明确 `undoable`。
- 大部分文件覆盖和危险 mutation 要求 `force:true`。

### 尚未满足

- M6 异步 route 的终态审计不完整。
- M6 的成功、失败、timeout、cancel 尚无自动化合同。
- M5 大部分 mutation 没有无副作用和恢复验证。
- runtime namespace 的跨里程碑 manifest 已失配。
- 全量 E2E 无法在现有默认外层时限内稳定取得终态。

## 文档一致性

以下文档已过期或与实现矛盾：

1. `docs/reports/2026-07-29-gdcli-roadmap-implementation-status.md` 仍称 M4–M6 不存在。
2. 主设计头部仍写“等待后续 implementation plan”，但 M2–M6 已有实现提交。
3. README 仍称 runtime route 为 35 条且所有 `runtime/**` 都经 broker；当前共有 36 条，
   `runtime/eval` 也没有经 broker。
4. `docs/security/high-risk-capabilities.md` 声称网络会重新校验目标和重定向，当前实现没有
   DNS/IP 校验且禁用了 redirect。
5. M3 closure report 的 232 passed 是历史基线，不代表加入 M4–M6 后的当前完整套件。

在代码修复前应避免用文档修改掩盖实现缺口；文档应在对应行为通过后同步更新。

## 整改优先级

### P0：高风险安全与语义

1. 让 `runtime/eval` 真正经 protocol v2、broker 和 probe 执行。
2. 建立 DNS/IP 级网络目标验证；明确 redirect 是“全部拒绝”还是“逐跳验证”。
3. 把 process/network 的审计移动到唯一终态路径。
4. 把 eval 从 substring blacklist 改为 identifier allowlist，并拒绝对象型输出。
5. 为上述行为增加真实 M6 E2E。

### P1：数据完整性与验收

1. 让批量 replace 全量 stage、全量验证、原子 apply 或完整 rollback。
2. 完成 delete/recover 的 `.uid` 和 manifest 生命周期。
3. 补齐 bulk deploy 的 stale artifact/device 和部分失败测试。
4. 补齐 M5 全部正式验收。

### P2：合同、性能和文档

1. 按里程碑集合修复 M3/M4/M5 route inventory。
2. 优化 M2/M4 的 editor fixture 复用与 reset。
3. 恢复全量 E2E 单命令可重复完成。
4. 更新 README、主设计、安全文档和状态报告。

## 完成判定

只有同时满足以下条件，才能把路线图标记为完整：

- M1–M6 每个里程碑都有与设计验收一一对应的自动化证据。
- `cargo fmt --check`、`cargo clippy --workspace`、`cargo test --workspace` 全部通过。
- `python scripts/format-gd.py --check` 和修改 GDScript 的 `gdlint` 通过。
- `uv run pytest tests/e2e/ -v` 在 Godot 4.7.x 上一次性通过，无 skip、无超时。
- M3 原始 35 route、M4 51 route、M5 27 route 和 M6 8 route 分别由独立集合锁定。
- `runtime/eval` 在运行游戏进程执行，断开和未运行状态稳定失败且无 pending。
- 网络对解析后 IP 和 redirect 逐跳执行同一策略，或明确拒绝所有 redirect。
- 高风险操作的成功、失败、timeout、cancel 和安全拒绝均产生去敏终态审计。
- 批量文件失败时没有部分修改，删除可完整恢复文件和 `.uid`。
- 文档描述与最终代码、route 数量和验证结果一致。

