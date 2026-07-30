# E2E Walltime 优化评估报告

日期：2026-07-30  
分支：`feat/full-capability`  
相关提交：`237f94e test: exclude budget suite by default`

## 结论

核心 E2E 套件的 walltime 优化目标已基本达成：普通 `tests/e2e/` 运行不再重复执行预算元测试，实测耗时从约 329 秒降至约 166 秒，减少约 49.4%。

当前核心套件已远低于 6 分钟预算；继续优化存在空间，但主要集中在少数慢测试和重复 reset/setup，收益将逐渐递减。

## 实测结果

### 优化前的完整默认命令

命令：

```powershell
$env:GODOT_BIN = 'D:\app\devel\Godot\v4.7.1\godot_console.exe'
uv run pytest tests/e2e/ -q
```

结果：

- `321 passed, 29 skipped`
- 总耗时：`328.67s`
- 包含 `test_full_suite_budget.py`，该测试会嵌套再次运行完整 E2E 套件。

### 优化后的普通核心套件

结果：

- `320 passed, 29 skipped, 1 deselected`
- 总耗时：`166.33s`
- 预算测试自动排除
- walltime 减少：约 `162.34s`
- 相对减少：约 `49.4%`

### 预算测试入口

预算测试现在使用 `budget` marker，普通运行默认排除；显式入口为：

```powershell
$env:GODOT_BIN = 'D:\app\devel\Godot\v4.7.1\godot_console.exe'
uv run pytest tests/e2e/test_full_suite_budget.py -m budget -q
```

预算测试内部仍会执行不包含自身的完整核心套件，并检查：

- 核心套件退出码为 0
- `GODOT_EDITOR_STARTS=1`
- 总耗时不超过 360 秒

## 已实施变更

- `pyproject.toml`
  - 默认 pytest 参数加入 `-m 'not budget'`
  - 注册 `budget` marker
- `tests/e2e/test_full_suite_budget.py`
  - 添加 `budget` marker
  - 保留显式预算验收入口
  - 排除自身，避免嵌套递归
  - 为预算测试设置独立的较长 timeout
- `tests/e2e/conftest.py`
  - 不对 `budget` 测试套用普通 180 秒 deadlock timeout

## 当前架构收益

- M2–M6 共用一个 session-scoped editor fixture。
- 普通核心套件只启动一个 editor session。
- 模块 fixture 通过共享环境别名复用同一 editor PID、项目目录和 metadata。
- pytest collection order 将契约测试、轻量路由和慢路径分桶排列。

## 剩余优化空间

根据已有 `--durations=20` 输出，主要瓶颈是：

1. `m6/test_process_run.py::test_process_run_async_timeout_returns_conflict`，约 29 秒。
2. 共享 editor readiness/setup，单次约 12 秒。
3. M3 runtime 测试重复 reset/setup，多个测试各消耗约 3–4 秒。

建议后续只针对这些路径做 profiling：

- 检查 `process/run` 超时取消流程是否存在不必要的等待或轮询间隔。
- 合并安全的 M3 runtime reset/setup 操作，避免每个测试重复进行昂贵初始化。
- 优化 editor readiness polling，但保留启动失败诊断和稳定性边界。

由于当前核心套件已约 166 秒，进一步优化应以稳定性不下降为前提；不建议为小幅收益引入并行共享 editor 请求。

## 已知限制

- 仍有 29 个 skipped 测试，主要包括缺失 GDScript fixture、Android 环境限制、既有审计日志交互问题以及已移除的 recovery API；本报告暂不处理这些问题。
- 最近一次显式预算测试复验遇到既有的 runtime input flaky 断言失败；失败发生在嵌套核心套件内部，不是 budget marker 或排除逻辑导致。
- 尚未建立迁移前可重复的独立基线，因此无法给出相对于旧架构的精确加速倍数；本报告的 49.4% 是相对于“包含重复预算测试的当前默认命令”计算的。

## 验证记录

- 核心 E2E：`320 passed, 29 skipped, 1 deselected, 166.33s`
- 先前完整命令：`321 passed, 29 skipped, 328.67s`
- Rust workspace tests：通过
- `cargo fmt --check`：通过
- `cargo clippy --workspace`：通过
- 修改过的 GDScript `gdlint`：通过
- 工作树在提交时保持干净
