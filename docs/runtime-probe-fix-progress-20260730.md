# 运行时 Probe 连接修复 — 进度报告

> 日期: 2026-07-30
> 目标: 修复 `runtime/status` 显示 probe 为 "disconnected" 的问题

## 已完成的修改

### 1. `gdapi/addon/routes/project/stop.gd`

**问题**: 原实现先 detach broker 再 stop scene，导致 `wait_stopped()` 在场景仍在运行时误判为已停止。

**修复**: 调换顺序 —— 先 `EditorInterface.stop_playing_scene()` 并忙等场景真正停止（最多 10 秒），再 `broker.detach("game stopped")`。

```gdscript
# 先停止场景
if EditorInterface.is_playing_scene():
    EditorInterface.stop_playing_scene()
    var deadline: int = Time.get_ticks_msec() + 10000
    while Time.get_ticks_msec() < deadline and EditorInterface.is_playing_scene():
        ;  # 忙等
# 再 detach broker
if broker != null:
    broker.detach("game stopped")
```

### 2. `gdapi/addon/routes/runtime/status.gd`

**问题**: `broker.status()` 返回 `_state = "connecting"`（因 broker 已 attach 到 engine debugger session），但编辑器未播放场景时预期应返回 `"stopped"`。

**修复**: 在返回 broker 状态前检查 `editor_playing`，当编辑器未播放时强制覆盖 `state = "stopped"`。

```gdscript
var status: Dictionary = broker.status()
status["ok"] = true
status["broker_registered"] = true
status["editor_playing"] = editor_playing
if not editor_playing:
    status["state"] = "stopped"
res.json(status)
```

### 3. `tests/e2e/shared_fixture.py` — 回退 `--display-driver headless`

**问题**: 尝试将 `--headless` 替换为 `--display-driver headless`（Godot 4.7.x 推荐用法），但该 flag 导致 `EditorInterface.play_main_scene()` 无法启动游戏。

**状态**: 已回退到 `--headless`。Godot 4.7.1 仍支持 `--headless` 作为别名。

### 4. `tests/e2e/m3/conftest.py` — `wait_stopped()` 函数

`wait_stopped()` 已有正确实现：检查 `state == "stopped"`、`pending == 0`、`editor_playing == false`。`project/stop.gd` 的修复确保此函数不会在场景仍在运行时误返回。

## 遗留问题

### 1. `EditorInterface.play_main_scene()` 在 headless 模式下不工作

**症状**: `m3_lifecycle` fixture 中 `project_run()` 调用 `project/run` 路由 → `EditorInterface.play_main_scene()` 后，`editor_playing` 仍为 `false`，`wait_for_connected()` 等待 60 秒后超时。

**错误信息**:
```
HarnessFailure: runtime probe never reached connected state within 60.0s
(last status: {..., 'editor_playing': false, 'state': 'stopped', 'transport': 'none'})
```

**影响范围**: 所有使用 `m3_lifecycle` fixture 的测试：
- `test_runtime_status_initial_state_is_stopped`
- `test_runtime_lifecycle_scenario`
- `test_reset_connected_game_cleans_stale_transport`
- 以及 `m3/test_runtime_*` 下所有需要运行时的测试

**可能原因**: Godot 4.7.1 headless 模式下 `EditorInterface.play_main_scene()` 行为异常，无法启动游戏进程。可能与 `--headless` flag 的兼容性有关。

### 2. `require_godot_47` 版本门禁

**问题**: `tests/e2e/conftest.py` 中的 `require_godot_47()` 函数强制要求 Godot 4.7.x。当前环境 PATH 上的 Godot 为 4.6.3。

**缓解**: 通过 `GODOT_BIN` 环境变量指向 `D:\app\devel\Godot\v4.7.1\godot_console.exe` 可绕过，但 `EditorInterface.play_main_scene()` 在 4.7.1 headless 模式下存在兼容性问题。

### 3. 测试基础设施依赖

- 需要 Godot 4.7.x 编辑器（当前 PATH 上为 4.6.3）
- 部分测试需要 Android SDK（M6 `test_bulk_deploy`）
- GDScript 单元测试依赖 `gdformat`/`gdlint` 工具

## 通过的测试

在没有 `m3_lifecycle` 依赖的测试中：
- `test_runtime_status_doc_has_returns` ✅
- `test_m3_editor_session_reuses_one_process_and_setup` ✅
- `test_unified_fixture_contract.py` 下全部 3 个测试 ✅
- `test_shared_editor_lifecycle.py` 相关测试 ✅

## 下一步建议

1. **排查 headless 模式下 `play_main_scene()` 不工作的原因**：尝试使用 `--display-driver headless --audio-driver Dummy` 组合，或升级 Godot 到 4.7.2+ 看是否有修复。
2. **降级回 `--display-driver headless` 并测试**：如果 `--headless` 与 `--display-driver headless` 行为不一致，需确认哪个 flag 能同时支持 editor 启动和场景播放。
3. **考虑非 headless 启动方式**：在 Windows CI 上可以不使用 `--headless`，直接启动 editor（无显示服务器时自动降级）。