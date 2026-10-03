# Changelog

## Unreleased

### Breaking Changes
- `gdcli exec` 默认输出格式从原始 minified JSON 改为 **TOON**。脚本场景请添加 `--json` 标志恢复旧行为。
- `navigation/region/list` 不再返回不稳定的 `map_rid`，改为 `{path, class, vertex_count, polygon_count}`；`navigation/mesh/bake` 改为真实烘焙（失败/空结果不留输出文件）。
- `scene/list_open` 返回全部打开场景（此前只返回当前场景）；`scene/close` 明确为「仅当前场景」。
- `resource/assign` 校验目标属性必须是资源槽位，否则返回 `invalid_param`（与 `doc()` 一致）。
- 移除 Android 平台能力：删除 `export/android/{devices,deploy,deploy_many}` 路由、`android_bridge` 与 `bulk_deploy_service` 服务及其测试/fixture。`export/run` 统一使用 `--export-pack`，`export/presets` 响应不再包含 `templates` 字段。Android 不再属于本分支目标与验收范围。

### Features
- `gdcli exec` 支持 TOON 输出，自动根据响应数据结构选择表格/键值/树状形态
- 新增 `cli/src/format/` 模块，对外暴露 `render_exec_body` API

### Fixes
- 修复 `export/run` 在编辑器内必然失败的问题：`GdApiExportService` 现在在子进程运行期间持续排空 stdout/stderr（Godot 管道缓冲仅约 4 KiB，写满会阻塞子进程，直到超时被杀），并用 `--editor --headless --recovery-mode` 启动导出子进程，避免它重复加载 gdapi 插件后覆盖并删除父编辑器正在使用的 `.godot/gdapi.json`。
- `export/run` 超时改为返回 `timeout` 并删除半成品产物；响应 `messages` 已去除 ANSI 转义与控制字符，可被严格 JSON 解析器读取。
- `project/input_map/*` 与 `project/autoload/*` 变更现在会写回 `project.godot`（此前只改内存 InputMap，重载后丢失）；保存失败时回滚内存状态并记录失败审计。
- 批量文件操作失败时给出 `details.rollback_failures`：replace/delete 的回滚与 recover 的中途失败都会检查每一步结果，并回滚已应用/已恢复项；`plan_hash` 现在绑定 `root`/`find`/`replace`（此前只绑定文件哈希与替换计数）。
- `network/http_request` 与 `process/run` 的失败/超时按真实终态写入审计（deferred registry 不再以「响应已发送」推断成功）；进程 spawn 失败与任务注册失败也会入审计。
- `audio/player/create` 返回 `/root/<场景根>/...`（此前返回编辑器内部路径，无法再被其它路由使用）；`physics/*` 的 `node_path` 同时接受绝对路径、场景根相对路径与裸节点名，并回传规范化绝对路径。
- 修复 `uid/repair` 失败响应的类型错误：此前把 `changes`(Array) 当作 `res.error()` 的第 4 个参数（要求 Dictionary），失败路径会在 GDScript 抛类型错误、响应永远发不出去（CLI 只能等到超时）；现在返回带 `changes` 与失败详情的 `details`。
- 项目设置/InputMap/Autoload/`uid/repair` 现在会**回读校验落盘结果**：Godot 在目标文件不可写时会返回 OK 却什么都没写（临时文件 rename 失败被吞），此前会误报成功；现在改为回滚内存状态并返回 `godot_error`，`uid/repair` 还会回滚已写入的 UID 并在 `details` 给出 `expected_uid`/`written_uid`/`rollback_failures`。
- mutation 审计补全：router 为「响应含 `changed` 且本次请求未新增审计条目」的请求统一补记一条 `safety=mutation` 审计；已自行审计的危险/文件类操作不会被重复记录。HTTP 层拒绝码 `method_not_allowed` 收进 `error_codes.gd`（含 HTTP 405 映射）。

### Maintenance
- 修正 E2E 隔离：`default_bus_layout.tres` 由 Godot 自身维护，不再纳入文件基线（此前导致 M2/M4 隔离断言间歇失败）；`restore_file_state` 写回后校验并在失败时重试，仍不一致则报错而不是静默吞掉。
- E2E harness 收口：会话级断言「只允许启动一个编辑器」（并打印 pid/时间线/调用栈），修掉测试模块导入 fixture 函数导致的重复定义（实测会真的启动两个编辑器）；`scene/open` 之后等待场景切换完成（避免 UndoRedo 绑到旧场景）；M6 增加每测试文件恢复；`teardown_environment` 不再吞掉重置失败；只有缺少 cargo 才 skip；undo 桥等待放宽到 10s（m2/m4 两份）、`wait_for` 默认与 m3 输入等待放宽；budget 测试默认排除（`pyproject.toml` 与文档一致）；`attach_game` 握手失败时打印 status/运行期目录/编辑器 console 诊断。
- 新增 `GDAPI_E2E_TRANSPORT=engine_debugger`：让整套 E2E 走 EngineDebugger 数据面（默认仍是确定性的 file transport），并补 [外部 godot-mcp 能力对比](docs/reports/2026-10-03-external-parity-comparison.md)。
- 里程碑 route manifest 调整为 M5 = 25、M6 = 7；新增桌面导出验收 `tests/e2e/m5/test_export.py`。
- 修正 fixture 导出预设平台名（`Windows` → `Windows Desktop`）——此前 Godot 会忽略该预设，导致桌面导出用例无法执行。
- Godot 开发验证基线更新为 4.7.2，Windows 测试默认路径改为 `D:\app\devel\Godot\v4.7.2\godot_console.exe`；其他平台仍默认使用 PATH 中的 `godot`。
- 共享 E2E fixture 接入现有二进制解析器，保留显式 `godot_bin` 参数及 `GODOT_BIN` 环境变量覆盖，修复其绕过 Windows 默认路径的问题。
- 完成 [Godot 4.7.1 → 4.7.2 变更与兼容性核对](docs/reports/2026-10-03-godot-4.7.2-upgrade.md)；保持 godot-rust 0.5.4 / `api-4-7` 和最低兼容版本 4.7，不新增补丁版本适配分支。
