# gdcli M4 游戏系统域收口报告

日期：2026-07-29

## 结果

M4 的 51 条 public route 已实现并锁定，覆盖 Animation/AnimationTree、TileMap、Material/Shader、Audio、UI/Theme、2D Physics 与 2D Navigation。M4 专项 E2E 最终结果为 **31 passed**；M3 的 `runtime/**` manifest 仍为 **35 条**。

所有 M4 editor mutation 按领域接入 UndoRedo；资源、shader、Audio bus layout 与 navigation bake 为 `undoable:false`，已有目标遵守 `force:true` 覆盖保护。Physics/Navigation 的 3D 输入在 mutation 前返回 `not_supported`。

## 验证证据

- `cargo fmt --check`：通过。
- `cargo clippy --workspace`：通过；仅保留既有 clippy warnings，无 error。
- `cargo test --workspace`：通过，196 个 Rust tests。
- `uv run pytest tests/e2e/m4 -v --basetemp ...`：31 passed。
- `uv run pytest tests/e2e/m1_contracts.py -v`：3 passed。
- `uv run pytest tests/e2e/m2/test_m2_contract.py -v`：4 passed。
- `uv run pytest tests/e2e/m3/test_m3_contract.py -v`：4 passed。
- `tests/fixture_project/tests/test_runtime_route.gd`：167 passed。
- `git diff --check`：通过；仅有 Git 的 LF/CRLF 提示。

全量 E2E 曾在未设置 `GODOT_BIN` 时回退到 4.6.3，随后改用 AGENTS 指定的 Godot 4.7.1；一次长跑还触发了 pytest 临时目录编号上限。相关失败均已通过定向测试复核，M1/M2/M3 contract 与完整 M4 suite 当前均为绿色。

## 隔离性

M4 测试只复制 `tests/fixtures/m4_project` 到独立临时目录；保存的材质、shader、theme、navigation bake 与 Audio bus layout 均写入测试副本。checked-in fixture 未被测试修改。
