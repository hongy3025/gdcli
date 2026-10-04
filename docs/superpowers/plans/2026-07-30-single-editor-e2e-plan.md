# Single-Editor E2E Fixture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **历史快照（2026-08-01 已废弃）**：本计划中描述的 `capability_policy` 机制、`.godot/gdapi-policy.json` 配置、`temporary_policy(env, override)` 上下文管理器以及 `force:true` 路由参数自 2026-08-01 起已全部移除。gdcli 仅作为开发期工具运行，高风险能力默认可用，受 service 内置硬上限约束（eval 源码 ≤16 KiB、process 超时 ≤60s/输出 ≤1 MiB、network 仅 http(s)/超时 ≤60s/响应 ≤4 MiB/重定向 ≤5、export 超时 ≤600s）。下方涉及的 policy 切换、覆盖与恢复步骤作为历史决策保留，E2E fixture 当前使用默认全能力项目配置，不再依赖策略覆盖。

**Goal:** Run the complete `tests/e2e/` suite against one merged fixture and exactly one Godot editor process while preserving all existing assertions and acceptance behavior.

**Architecture:** Build one `tests/fixtures/e2e_project/` containing the M2–M6 assets and a unified project configuration. A session-scoped `e2e_editor` owns the temporary copy, addon installation, one Godot process, readiness checks, and teardown; legacy module fixture names become aliases returning that environment. A shared reset/policy helper restores deterministic state between tests without recreating projects or processes.

**Tech Stack:** Python 3, pytest fixtures, subprocess, Godot 4.7 headless editor, gdcli JSON routes, existing GDScript fixture/plugin tests.

## Global Constraints
**Goal:** Run the complete `tests/e2e/` suite against one merged fixture and exactly one Godot editor process while preserving all existing assertions and acceptance behavior.

**Architecture:** Build one `tests/fixtures/e2e_project/` containing the M2–M6 assets and a unified project configuration. A session-scoped `e2e_editor` owns the temporary copy, addon installation, one Godot process, readiness checks, and teardown; legacy module fixture names become aliases returning that environment. A shared reset/policy helper restores deterministic state between tests without recreating projects or processes. A pytest-level collection-order hook reshuffles the run order so fast contract tests fire first and long-tail export/process tests sit at the back, shaving wall time without changing the test set.

**Tech Stack:** Python 3, pytest fixtures, pytest collection hooks, subprocess, Godot 4.7 headless editor, gdcli JSON routes, existing GDScript fixture/plugin tests.

## Global Constraints

- Preserve all existing E2E assertions and the six-minute full-suite budget.
- Start exactly one Godot editor process for a full `tests/e2e/` invocation.
- Do not create per-module or per-test project copies; use one temporary copy of `e2e_project` for the session.
- Keep all modified GDScript files formatted with `python scripts/format-gd.py` and linted with `gdlint` before tests.
- Preserve Godot 4.7.x validation and existing failure diagnostics.
- Use pytest collection order to optimize wall time:
  - Contract / lifecycle / lightweight route tests run first so a broken fixture or editor surfaces within seconds.
  - Runtime / m3 input / m4 game tests run in the middle.
  - Slow paths (m5 export_android, m6 process / network / bulk, m3 lifecycle scenario) run last.
  - The reshuffle MUST NOT change the set of test functions or any assertion; it only changes execution order.
---

### Task 1: Inventory and create the merged fixture

**Files:**
- Create: `tests/fixtures/e2e_project/project.godot`
- Create/modify: `tests/fixtures/e2e_project/addons/gdapi_test/**`
- Create/modify: `tests/fixtures/e2e_project/scenes/**`, `scripts/**`, `resources/**`, `bulk/**`, `tools/**`, `main.tscn`, `main.gd`, and M2–M6 fixture assets
- Test: `tests/e2e/test_unified_fixture_contract.py`

**Interfaces:**
- Produces a checked-in fixture root containing every path currently read by M2–M6 tests.
- Produces a project configuration with the gdapi plugin and default all-capability policy enabled.

- [ ] **Step 1: Add a fixture contract test that enumerates required source paths and rejects collisions.**

  Assert that the merged root contains the M2–M6 scene/script/resource/tool paths used by the tests, that `project.godot` enables the test plugin, and that no required path is duplicated under two destination paths.

- [ ] **Step 2: Copy and reconcile fixture assets.**

  Copy source assets from `tests/fixtures/m2_project` through `m6_project` into stable subdirectories under `tests/fixtures/e2e_project`; retain the exact relative names required by current tests where possible. Rename only collisions and record each renamed path in the contract test.

- [ ] **Step 3: Write the merged project configuration and plugin entry point.**

  Combine the required display, input, main scene, addon, and gdapi settings into one `project.godot`; enable all capabilities by default and keep M5/M6 policy files as test fixtures that can be temporarily overlaid.

- [ ] **Step 4: Run the fixture contract test.**

  Run `python -m pytest tests/e2e/test_unified_fixture_contract.py -q`; expected result is PASS before lifecycle migration.

- [ ] **Step 5: Commit the fixture independently.**

  Run `git add tests/fixtures/e2e_project tests/e2e/test_unified_fixture_contract.py` and commit with `test: add unified e2e fixture`.

### Task 2: Implement the single session editor and shared reset API

**Files:**
- Modify: `tests/e2e/conftest.py`
- Create: `tests/e2e/shared_fixture.py`
- Test: `tests/e2e/test_shared_editor_lifecycle.py`

**Interfaces:**
- `e2e_editor(tmp_path_factory) -> dict[str, Any]` owns one temporary project and one `subprocess.Popen`.
- `reset_shared_state(env, *, reason: str) -> None` stops games, clears runtime transport/audit/selection, restores default policy, and raises diagnostic `AssertionError` on failure.
- `temporary_policy(env, override: dict) -> ContextManager[dict]` applies and restores capability policy.

- [ ] **Step 1: Write lifecycle tests using monkeypatches.**

  Verify two calls through dependent fixtures return the same `godot.pid`, project path, and metadata object; verify reset failure includes the phase name; verify `temporary_policy` restores bytes and reports restoration failure.

- [ ] **Step 2: Extract shared command, metadata, log, and cleanup helpers.**

  Move reusable readiness and diagnostic behavior from `tests/e2e/conftest.py` and `tests/e2e/m3/conftest.py` into `shared_fixture.py` without changing command output formats.

- [ ] **Step 3: Replace the root session fixture with `e2e_editor`.**

  Copy `e2e_project` once to `tmp_path_factory.mktemp("e2e") / "project"`, run one workspace build/install, start Godot once, wait for metadata and gdapi ping, expose `editor_pid`, and terminate/clean runtime transport in a `finally` block.

- [ ] **Step 4: Implement reset and policy context managers.**

  Use gdcli routes for `project/stop`, `gdapi/audit/clear`, `editor/selection/set`, runtime reset, and policy reload. Capture command, runtime status, and Godot log tail in every raised diagnostic.

- [ ] **Step 5: Run focused lifecycle tests.**

  Run `python -m pytest tests/e2e/test_shared_editor_lifecycle.py -q`; expected result is PASS with no Godot process required through monkeypatched subprocess calls.

- [ ] **Step 6: Commit the shared lifecycle layer.**

  Commit `tests/e2e/conftest.py`, `tests/e2e/shared_fixture.py`, and lifecycle tests with `test: add shared e2e editor lifecycle`.

### Task 3: Migrate M2–M4 fixtures and tests to the shared environment

**Files:**
- Modify: `tests/e2e/m2/conftest.py`, `tests/e2e/m2/helpers.py`, and M2 test files that hard-code fixture paths
- Modify: `tests/e2e/m3/conftest.py` and M3 test files that hard-code fixture paths
- Modify: `tests/e2e/m4/conftest.py` and M4 test files that hard-code fixture paths
- Test: `tests/e2e/test_shared_editor_contract.py`

**Interfaces:**
- Legacy fixtures `m2_editor`, `m4_env`, and M3 editor fixtures are session-scoped aliases of `e2e_editor`.
- Module autouse fixtures call `reset_shared_state` and never call `Popen`, `copytree`, `attach_editor`, or `detach_editor`.

- [ ] **Step 1: Add the shared PID/path contract test.**

  Request all M2–M4 aliases in one test and assert identical PID, resolved project directory, and metadata endpoint.

- [ ] **Step 2: Replace M2 startup and reset code with aliases.**

  Preserve helper signatures and test data paths, but return the shared env and call the shared reset hook from the autouse fixture.

- [ ] **Step 3: Replace M3 startup/recovery code with aliases.**

  Keep runtime probe helpers and diagnostics; remove independent fixture copy/start/restart paths except an explicit recovery test that exercises the shared editor health check without spawning a replacement.

- [ ] **Step 4: Replace M4 startup/reset code with aliases.**

  Keep scene reset and game lifecycle assertions while removing module-scoped process creation and project copying.

- [ ] **Step 5: Run M2–M4 tests and inspect process count.**

  Run `python -m pytest tests/e2e/m2 tests/e2e/m3 tests/e2e/m4 -q --durations=20`; expected result is PASS and all tests report one `editor_pid`.

- [ ] **Step 6: Commit the M2–M4 migration.**

  Commit with `test: migrate m2-m4 e2e to shared editor`.

### Task 4: Migrate M5–M6 policies, subprocess helpers, and tests

**Files:**
- Modify: `tests/e2e/m5/conftest.py` and M5 tests
- Modify: `tests/e2e/m6/conftest.py` and M6 tests
- Modify: `tests/e2e/route_manifests.py` only if merged paths require manifest updates
- Test: `tests/e2e/test_policy_restore.py`

**Interfaces:**
- `m5_editor`, `m6_editor`, `m6_editor_process`, `m6_editor_eval`, `m6_editor_bulk`, and `m6_editor_network` all alias `e2e_editor` and apply policy through `temporary_policy`.
- Existing local HTTP server and external process helpers remain module-scoped Python resources, not Godot editors.

- [ ] **Step 1: Write policy restoration tests.**

  Apply a disabled capability override, assert the route is rejected, exit the context, and assert the original policy bytes and enabled capability are restored; add an exception-path assertion.

- [ ] **Step 2: Convert M5 fixture setup.**

  Replace per-test temporary project creation with the shared env; redirect snapshot/source-digest checks to the merged fixture baseline and use a dedicated workspace directory for generated files.

- [ ] **Step 3: Convert M6 fixture setup.**

  Remove the five editor-producing fixtures and make each alias apply only its policy overlay. Retain `local_http_server`, process tools, and runtime-game helpers, using shared stop/reset in teardown.

- [ ] **Step 4: Update merged paths and policy assertions.**

  Change hard-coded `m5_project`/`m6_project` paths to the canonical merged paths and ensure tests restore policy files in `finally` blocks.

- [ ] **Step 5: Run M5–M6 tests.**

  Run `python -m pytest tests/e2e/m5 tests/e2e/m6 -q --durations=20`; expected result is PASS with one editor PID.

- [ ] **Step 6: Commit the M5–M6 migration.**

  Commit with `test: migrate m5-m6 e2e to shared editor`.

### Task 5: Enforce one-process acceptance and complete verification

**Files:**
- Modify: `tests/e2e/test_full_suite_budget.py`
- Modify: `tests/e2e/test_fixture_harness.py` and `tests/e2e/test_fixture_isolation.py` to express shared-state contracts
- Modify: `README.md` or `docs/` only if the E2E invocation or fixture workflow changes

**Interfaces:**
- Full-suite subprocess output exposes a machine-checkable `GODOT_EDITOR_STARTS=1` or equivalent lifecycle counter.
- Existing budget test continues to assert total duration <= 360 seconds.

- [ ] **Step 1: Add a process-count acceptance assertion.**

  Instrument the shared fixture with a session counter and assert exactly one editor start and one editor PID in the complete suite; do not count standalone `godot --version` probes as editor starts.

- [ ] **Step 2: Replace obsolete isolation assertions.**

  Assert deterministic reset and no cross-test residue instead of requiring different project directories or process IDs.

- [ ] **Step 3: Run mandatory GDScript formatting and lint gates.**

  Run `python scripts/format-gd.py`, `python scripts/format-gd.py --check`, install `gdtoolkit` with `uv tool install gdtoolkit` if `gdformat` or `gdlint` is missing, then run `gdlint` on every modified `.gd` file.

- [ ] **Step 4: Run the complete E2E suite.**

  Run `uv run pytest tests/e2e/ -v --durations=20`; expected result is PASS, one editor start, one PID, and total duration at or below 360 seconds.

- [ ] **Step 5: Run non-E2E regression checks.**

  Run `cargo test --workspace`, `cargo fmt --check`, and `cargo clippy --workspace`; expected result is PASS.
- [ ] **Step 6: Commit the acceptance changes.**

  Commit with `test: enforce single-editor e2e acceptance`.

### Task 6: Optimize wall time through pytest collection order

**Files:**
- Modify: `tests/e2e/conftest.py` — add `pytest_collection_modifyitems` ordering hook
- Test: `tests/e2e/test_collection_order.py` (asserts the order policy fires)

**Interfaces:**
- `pytest_collection_modifyitems` reorders the collected `items` list before execution without dropping or adding any test.
- Four ordered buckets:
  1. contract / lifecycle / lightweight (no-editor): `test_unified_fixture_contract`, `test_shared_editor_lifecycle`, `test_shared_editor_contract`, `test_collection_order`.
  2. M2 + M4 route / scene / node / signal / resource / script / filesystem tests.
  3. M3 runtime tests that need `m3_running` (`runtime_input`, `runtime_nodes`, `runtime_assert_signal`, `runtime_capture`, `runtime_observability`).
  4. M5 / M6 long-tail (`m5/test_export_android`, `m6/test_process_run`, `m6/test_bulk_files`, `m6/test_bulk_deploy`, `m6/test_network_request`, `m6/test_runtime_eval`, `m6/test_eval`, `m3/test_runtime_status::test_runtime_lifecycle_scenario`).
- Tests within a bucket keep their original relative order.
- The ordering hook MUST be deterministic and idempotent.

- [ ] **Step 1: Add an ordering contract test that snapshots the bucketed sequence.**

  Write a unit test that imports the bucket function, runs it over a hand-rolled list of node ids, and asserts the returned sequence matches the documented bucket order. The test runs without Godot.

- [ ] **Step 2: Implement the `bucketize` helper and the `pytest_collection_modifyitems` hook.**

  Move the bucket function into `shared_fixture.py` so both the hook and the test can import it. The hook iterates `items` once and places each item in the right bucket based on the test module path. Unknown modules fall into bucket 2.

- [ ] **Step 3: Verify deterministic order with two consecutive collection runs.**

  Run `python -m pytest tests/e2e --collect-only -q` twice in the same session; the listing must match exactly. The contract test in step 1 already covers this; add a second smaller assertion that diffs the two collections.

- [ ] **Step 4: Run the full E2E suite with the new order.**

  Run `uv run pytest tests/e2e/ -v --durations=20`. Expected result: PASS, one editor start, one PID, and total wall time at or below the 6-minute budget. The top `--durations=20` list should show the slow m5/m6/m3-lifecycle items at the back.

- [ ] **Step 5: Capture the new wall-time baseline.**

  Record the wall time in `docs/superpowers/specs/2026-07-30-single-editor-e2e-design.md` under “收集顺序优化验收” and commit the doc alongside the code.

- [ ] **Step 6: Commit the ordering changes.**

  Commit with `test: order e2e collection for wall time`.

