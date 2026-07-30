# Runtime Probe Headless 启动修复设计

## 目标

让 Godot 4.7.1 Windows headless editor 下的 `project/run` 稳定启动主场景，使 `runtime/status` 从 `stopped` 进入 `connecting`/`connected`，并保持停止流程可验证、可重复。

验收重点：

- `gdformat` 和 `gdlint` 能通过所有本次涉及的 GDScript。
- 现有无 Godot 的单元/集成测试不回归。
- 显式运行 M3 runtime E2E 时，`EditorInterface.play_main_scene()` 能真正进入播放状态，probe 能连接。
- 停止后状态为 `stopped`，pending 为 0，且编辑器不再播放。

## 根因与约束

当前上一轮修复包含一个非法的 GDScript 裸分号等待语句，导致 formatter/linter 无法解析 `project/stop.gd`；`runtime_probe.gd` 还存在 class 定义顺序 lint 错误。除此之外，`project/run` 在 HTTP 路由处理期间同步调用 `EditorInterface.play_main_scene()`，没有验证编辑器是否在后续主循环中真正开始播放。

测试 fixture 固定启动一个 session-scoped editor，目标 Godot 是 `D:\app\devel\Godot\v4.7.1\godot_console.exe`。启动参数必须适合 Windows headless；命令构造应可被 Python 单测验证，避免依赖 live Godot 才能覆盖。

## 方案

### 编辑器启动

在 `tests/e2e/shared_fixture.py` 中集中构造 editor 命令，保留 `--editor --headless --path`，并增加 `--audio-driver Dummy`，避免 headless 下音频设备初始化影响场景播放。为每个临时项目设置独立可写的 `APPDATA` 和 `LOCALAPPDATA`，避免宿主机 Godot 4.6 配置 junction 被 Godot 4.7.1 复用。命令和环境构造均由单测覆盖。

不采用 `--display-driver headless` 作为默认值：已有进度记录表明该组合曾导致 `EditorInterface.play_main_scene()` 不启动；保留 `--headless` 以兼容当前 Godot 4.7.1 Windows 构建。

### project/run

`project/run` 继续先调用 `broker.begin_connect()`，从 `application/run/main_scene` 读取主场景路径，并通过常驻 `EditorPlugin` 调用 `EditorInterface.play_custom_scene()`。路由 handler 是临时对象，不能持有 deferred 请求；常驻插件保证播放调用的接收者和生命周期稳定。路由响应包含 `editor_playing`；fixture 负责轮询 `runtime/status`，确认 `editor_playing == true` 后再等待 probe 连接。

如果主场景或指定场景无法启动，路由返回明确错误，不伪造成功响应。停止路由使用合法的 `pass` 等待体，并在 detach 前等待 `EditorInterface.is_playing_scene()` 变为 false。

### runtime/status

保留当前语义：编辑器未播放时对外报告 `state = stopped`，同时返回 `editor_playing`。编辑器播放时透传 broker 的连接状态，避免仅凭 broker 已注册就报告 connected。

### 测试

先以测试驱动方式增加/调整以下测试：

1. Python 单测验证 editor 命令构造包含 `--editor`、`--headless`、`--audio-driver Dummy`、`--path`。
2. GDScript 单测验证停止等待逻辑使用合法语法，并覆盖未播放与已停止路径。
3. M3 harness 单测验证 `project/run` 后等待 `editor_playing`，再等待 connected；失败诊断保留最后 status payload。
4. 显式 E2E 验证 M3 lifecycle 两次 run/stop，且连接、停止和 runtime 目录清理均满足既有断言。

## 错误处理

- editor 进程提前退出或 gdapi 不可达：沿用现有日志尾部诊断。
- `project/run` 请求被接受但 editor 未进入播放：fixture 超时错误必须包含最后一次 status、editor 日志尾部和命令参数。
- stop 超时：仍 detach broker，并由现有 harness 报告 pending、状态和日志，避免留下静默连接。
- formatter/linter 失败：在任何单元测试前停止，不降级执行。

## 范围

只修改 runtime probe 启动/停止链路、相关 E2E fixture/harness 及回归测试。保留工作区中其他未提交文件，不做无关重构；不默认运行预算测试。
