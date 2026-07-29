# gdcli M3 Runtime Remediation Closure Report

日期：2026-07-29

结论：**本地可修复阻塞已闭环；由于仍无本次 CI 运行证据，M3 保持 🟡。**

验证基线：

- 分支：`feat/full-capability`
- fix round 基线 HEAD：`dab58a296a997e0e4d1521a965ad41fee1017731`
- remediation range：`d13e01efaff88e6bfd5430cf34f14c5e061ac246..dab58a296a997e0e4d1521a965ad41fee1017731` 加本次 Task 17 fix round
- Godot：`D:\app\devel\Godot\v4.7.1\godot_console.exe`
- Python：3.14.0
- pytest：9.1.1

## 验证矩阵

Task 17 初始 closure 基线：

| 命令 | Exit code | 结果 | Duration |
|---|---:|---|---:|
| `cargo fmt --check` | 0 | 通过，无输出 | 1.0s |
| `cargo clippy --workspace` | 0 | 通过；3 个 warning，0 error | 1.9s |
| `cargo test --workspace` | 0 | 196 passed，0 failed，0 ignored | 19.9s |
| `$env:GODOT_BIN='D:\app\devel\Godot\v4.7.1\godot_console.exe'; uv run pytest tests/e2e/test_gdscript_units.py -v` | 0 | 17 passed | 13.49s pytest / 14.2s wall |
| `$env:GODOT_BIN='D:\app\devel\Godot\v4.7.1\godot_console.exe'; uv run pytest tests/e2e/m3 -v --durations=20` | 0 | 122 passed | 49.01s pytest / 49.7s wall |

本次 fix round 新鲜验证：

| 命令 | Exit code | 结果 | Duration |
|---|---:|---|---:|
| `$env:GODOT_BIN='D:\app\devel\Godot\v4.7.1\godot_console.exe'; uv run pytest tests/e2e/test_m1_contracts.py::test_all_command_docs_are_complete -v` | 0 | 1 passed | 7.96s pytest / 9.1s wall |
| `$env:GODOT_BIN='D:\app\devel\Godot\v4.7.1\godot_console.exe'; uv run pytest tests/e2e/test_fixture_harness.py tests/e2e/m3/test_harness.py tests/e2e/m3/test_m3_contract.py -v` | 0 | 16 passed；runtime route 精确 35 条 | 14.65s pytest / 15.7s wall |
| `$env:GODOT_BIN='D:\app\devel\Godot\v4.7.1\godot_console.exe'; uv run pytest tests/e2e/ -v --durations=20` | 0 | 232 passed，0 failed | 516.54s pytest / 517.4s wall |

没有把跳过、弱化或未运行的测试计为通过。上述 pytest 运行没有 skip。

## Fix round 修复与回归

### M1 command-doc

初始独立复现稳定失败：

```text
tests/e2e/test_m1_contracts.py::test_all_command_docs_are_complete
AssertionError: node/signal/emit
assert []
```

根因是 `gdapi/addon/routes/node/signal/emit.gd` 的参数化 `doc()` 缺少 example。修复仅补充符合现有 JSON command-doc contract 的 `.example(...)`，未修改或弱化 M1 合同测试。独立 M1 test 和完整 E2E 均通过。

### Source fixture stale-root cleanup

通用 `godot_env` 直接在 `tests/fixture_project` 启动编辑器；原 teardown 只终止 Godot，没有清理由 file transport 创建的 `.godot/gdapi_runtime`，因此 `generation.json` 会留在 source fixture。

修复在 fixture harness 中集中实现：

- 启动前和编辑器停止后只清理解析后的 `<fixture>/.godot/gdapi_runtime`。
- 路径守卫要求目标 basename 为 `gdapi_runtime`，且父目录精确等于该 fixture 的 `.godot`。
- 回归测试验证 `generation.json` 被删除，同时 `.godot/keep.json` 同级文件保留。
- teardown 超时会先 kill 并等待编辑器退出，再清理 transport root。
- M1 独立测试和完整 E2E 结束后，`tests/fixture_project/.godot/gdapi_runtime` 与 `generation.json` 均不存在。

## Contract、transport 与 cleanup

- Runtime route：精确 35 条。
- Broker-dispatched data route：34 条，均继承 `runtime/runtime_route.gd`。
- Editor-side route：仅 `runtime/status`。
- Headless M3 transport：fixture 明确强制 `file` fallback。
- EngineDebugger：GDScript 单元套件中的 debugger registration/priority/fallback 行为测试通过；本次 headless E2E 不声称使用 EngineDebugger data plane。
- Lifecycle：2 个 run/stop cycle；共享 data plane 合计 1 个 editor start、3 个 game starts。
- Recovery：0 fixture reset restarts、0 recovery markers、0 recovery events。
- Pending：每个 lifecycle stop 和 timeout/disconnect 回归均验证 `pending == 0`；M3 session finalizer 通过。
- Timer/signal：signal timeout、reset、transport disconnect 回归验证临时 Timer/connection 清零。
- Source fixture final check：精确 runtime root 不存在；同级文件保留合同通过。
- Process cleanup：完整矩阵结束后 Godot/gdcli 进程数为 0。

## 性能与 CI 边界

本地 warm-build M3 基线为 49.01s，满足 ≤60s。完整 E2E fix round 为 516.54s。当前仓库没有可引用的本次 CI 运行证据，因此不声称 CI M3 ≤120s。

## 验收结论

| 条件 | 状态 | 证据 |
|---|---|---|
| 35 routes / 34 broker data routes | 通过 | M3 manifest 4/4 |
| 正向、负向、mutation、async、bounds、audit/redaction | 通过 | M3 基线 122/122；完整 E2E 232/232 |
| EngineDebugger priority + file fallback | 通过 | GDScript 17/17 + headless file E2E |
| 两次 lifecycle、pending zero、Timer/signal cleanup | 通过 | M3 基线与 session finalizer |
| M1 command-doc 完整性 | 通过 | 独立 1/1 + 完整 E2E |
| Source fixture stale-root cleanup | 通过 | cleanup/manifest 聚焦 16/16 + 两次最终磁盘检查 |
| 本地 M3 ≤60s | 通过 | 49.01s |
| 完整 `tests/e2e/` | 通过 | 232 passed，exit 0 |
| CI M3 ≤120s | **未证实** | 无本次 CI 运行证据 |

因此不修改 roadmap 的 M3 🟡 状态；本次只提交修复代码、回归测试和本 closure report。
