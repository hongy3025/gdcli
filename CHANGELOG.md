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
- 新增 `scene3d/{create,set,info}` 与 `particles/{create,set,info}`：支持 Light/Environment/Sky/Camera/GridMap/CSG/MultiMesh 与 GPUParticles2D/3D 的可配置场景编辑；新增跨场景 `scene/batch/{plan,validate,apply,recover}` 事务、节点/引用/依赖扫描，并对失败回滚做真实持久化验证。
- 扩展 editor 与资源工作流：支持 editor Undo/Redo、Inspector、Dock、插件和设置控制、真实视口 PNG/相机覆盖、节点 meta 和显式 allowlist 方法调用、场景实例化/受保护删除、通用资源属性落盘读回/纹理预览及 Theme 读取。
- 扩展运行时与分析：增加输入录制分页/回放/取消、跨帧属性监视、声明式场景测试/压力测试/报告、实际 PNG 像素比较；增加 `signal_flow`、`scene_complexity`、`script_references` 与 `project_statistics` 只读诊断。
- 新增音频 bus 属性及 AudioEffect 编辑、AnimationTree blend graph 增删连线与参数持久化、运行时 Tween 进度/停止。

### Fixes
- 修复合并审查 R01/R02/R09：跨 origin 重定向永久剥离认证/Cookie 等敏感头；受限 eval 在 Variant 解码/资源加载前递归拒绝危险输入；通用审计摘要清除 URL userinfo，包括错误路径及嵌套字段。
- 修复 R03 与 Unix 任务生命周期：保持生产默认 30 秒期限，用请求级绝对期限/取消原因协调 HTTP、实际进程和审计；超时、断连、shutdown、drop 先清理后返回失败。Unix 原子创建独立进程组，Windows 保留 Job Object；自然退出也清理持有管道的后代，输出线程可停止并有界排空。
- 修复 R04/R05：场景另存前检查可写性，读取实际磁盘场景并比较解码后的 SceneState，而非不稳定的 PackedScene 内部索引；失败恢复路径/dirty 状态和目标字节。`scene/current.edited` 返回真实未保存状态；删除依赖扫描覆盖 GDScript preload/load 的资源、相对和 UID 路径，扫描不执行脚本。
- 修复 R06/R07/R08：UID 修复使用统一写权限及全计划预检；InputMap 保存失败恢复真实的完整前态；资源赋值验证原生/自定义子类并确认实际属性值后提交 undo action，失败不破坏 undo/redo 历史。
- 修复文本写入失败误报成功：`filesystem/write` 与脚本创建/写入/patch 现在检查写入、关闭和 rename 结果，失败清理临时文件且不记成功审计；Windows `PathGuard` 同时按大小写不敏感保护受限目录别名。
- `node/meta/set` 与 `node/call` 在 Variant 解码前递归拒绝嵌套 Object/Resource 标签，避免拒绝请求仍加载资源；场景依赖扫描继续保持静态，不执行脚本。
- 收紧网络审计与重定向：拒绝的凭据 URL 不再记录原文；query-only/相对路径保留 URI-reference 语义，等价压缩/展开 IPv6 地址视为同一 origin；拒绝空 host/非法端口，空响应体也能返回正确 SHA-256/base64。
- 修复 save-as 后未保存场景状态按编辑器 tab/root 对齐（包括空场景 tab），并从磁盘核验场景外部依赖；UID 批量失败回滚资源/sidecar 字节及 UID 注册映射，InputMap 恢复按键/鼠标修饰键。
- 请求响应仅在 HTTP 响应入队被原子接受后完成审计；TCP half-close 仍可收到响应，RST/读错误才取消请求。Windows 子进程在 Job Object 归属前保持挂起，避免快速派生的后代逃逸。
- `gdcli --json` 只把 `ok` 前置，不再套用 TOON 有损压缩：空数组保持 `[]`、单元素数组保持数组（此前 `--json` 会把表格行里的 `[]` 写成 `""`）。
- `scene/current.edited` 按场景索引对齐编辑器的未保存记录（`save-as` 之后编辑器内部的场景条目路径仍指向旧文件），另存为之后再改动仍报告未保存；写权限探测不再创建会被编辑器扫描到的空 `.tscn`。
- `network/http_request` 为 `http://host?query` 这类缺少路径的 URL 补上 `/`，避免 Godot `HTTPRequest` 直接拒绝请求（此前报 `HTTP request could not start`）。
- 运行时 `runtime/input/key` 注入后立即刷新 Godot 缓冲输入事件，使按键被运行期接收端与录制器在同一派发周期内观察；`runtime/node/find` 结果新增规范化 `node_path` 字段，保留原有 `path`。
- `resource/preview` 在 headless 编辑器中使用与 Godot 内置 Gradient 预览生成器相同的 `GradientTexture1D` 渲染，避免等待 headless 模式下不会派发的 EditorResourcePreview 回调；活动预览队列仍按原 `deadline_ms` 超时。
- 修复 runtime file transport 的 hello 发布状态：此前一次文件 open/rename 失败也会提前标记为“已发送”，导致 probe 永久停在 `connecting / transport=none`；现在只有 `hello.json` 原子发布成功才标记为已发送，否则在原定延迟到期后继续完成发布，不重启游戏、不扩大 harness 超时或重试次数。新增真实文件系统故障回归，覆盖立即写入失败、延迟 rename 失败及已断开端点不复活。
- 修复 `export/run` 在编辑器内必然失败的问题：`GdApiExportService` 现在在子进程运行期间持续排空 stdout/stderr（Godot 管道缓冲仅约 4 KiB，写满会阻塞子进程，直到超时被杀），并用 `--editor --headless --recovery-mode` 启动导出子进程，避免它重复加载 gdapi 插件后覆盖并删除父编辑器正在使用的 `.godot/gdapi.json`。
- `export/run` 超时改为返回 `timeout` 并删除半成品产物；响应 `messages` 已去除 ANSI 转义与控制字符，可被严格 JSON 解析器读取。
- `project/input_map/*` 与 `project/autoload/*` 变更现在会写回 `project.godot`（此前只改内存 InputMap，重载后丢失）；新增动作会先导入项目已保存的 deadzone/按键和鼠标事件；保存失败时回滚内存状态并记录失败审计。
- 批量文件操作失败时给出 `details.rollback_failures`：replace/delete 的回滚与 recover 的中途失败都会检查每一步结果，并回滚已应用/已恢复项；`plan_hash` 现在绑定 `root`/`find`/`replace`（此前只绑定文件哈希与替换计数）。
- `network/http_request` 与 `process/run` 的失败/超时/断连均按真实终态写入审计，即使客户端断开导致响应无法入队也不会漏审计（deferred registry 不再以「响应已发送」推断成功）；Windows 下 `process/run` 通过 Job Object 管理子进程树，超时/取消时清理后代，避免其继承的 stdout/stderr 管道延迟终态响应。进程 spawn 失败与任务注册失败也会入审计。
- `audio/player/create` 返回 `/root/<场景根>/...`（此前返回编辑器内部路径，无法再被其它路由使用）；`physics/*` 的 `node_path` 同时接受绝对路径、场景根相对路径与裸节点名，并回传规范化绝对路径。
- 修复 `uid/repair` 失败响应的类型错误：此前把 `changes`(Array) 当作 `res.error()` 的第 4 个参数（要求 Dictionary），失败路径会在 GDScript 抛类型错误、响应永远发不出去（CLI 只能等到超时）；现在返回带 `changes` 与失败详情的 `details`。
- 项目设置/InputMap/Autoload/`uid/repair` 现在会**回读校验落盘结果**：Godot 在目标文件不可写时会返回 OK 却什么都没写（临时文件 rename 失败被吞），此前会误报成功；现在改为回滚内存状态并返回 `godot_error`，`uid/repair` 还会回滚已写入的 UID 并在 `details` 给出 `expected_uid`/`written_uid`/`rollback_failures`。
- mutation 审计统一改为请求级 `RouteDoc.mutates()` 契约：有效 mutation 无论成功、业务失败还是 JSON/参数校验失败都准确补记一条；handler 自行记录的条目不重复，纯只读失败不误记为 mutation。审计支持 safety 过滤，容量达到 1000 时优先淘汰普通 mutation，保留危险/文件类记录。
- `scene/open` 现在等待 Godot 编辑器完成实际场景切换（最多 5s）再返回；避免后续请求作用于旧场景，并让超时以失败终态进入请求级 mutation 审计。
- `scene/batch/apply`/`recover` 更新受影响文件的 `EditorFileSystem` 元数据并扫描；`scene/open` 等待排队扫描开始/结束后再重载 scene cache，确保重新打开读取落盘版本。
- `scene3d` 修复 `MeshLibrary` item-ID 检查对不存在 `has_item()` 的调用；真实渲染器 gate 验证 GridMap/MultiMesh 状态读回，headless 下非空 MultiMesh 返回 `not_supported` 而不伪报 RenderingServer dummy values。

### Maintenance
- CLI 的同步 HTTP/install 路径不再创建 Tokio 多线程池，LSP 按需创建单线程运行时；E2E 文件隔离在遍历前剪枝 `.godot` 和安装目录，保留相同文件基线与实际字节核验。
- 完整门禁的 file/budget 共用同一次新鲜父进程计时，移除重复全套运行；独立 budget 命令仍执行完整套件。E2E 不再覆盖生产 handler 期限；格式/lint 合并有命令行长度上限的批次，去重 junction 的同一物理源码，不减少检查覆盖。
- 修正 E2E 隔离：`default_bus_layout.tres` 由 Godot 自身维护，不再纳入文件基线（此前导致 M2/M4 隔离断言间歇失败）；`restore_file_state` 写回后校验并在失败时重试，仍不一致则报错而不是静默吞掉。
- E2E 项目基线排除 Godot 保存 `project.godot` 时生成的瞬态 `.tmp` 文件，避免快照读取到已被重命名的中间文件。
- E2E harness 收口：会话级断言「只允许启动一个编辑器」（并打印 pid/时间线/调用栈），修掉测试模块导入 fixture 函数导致的重复定义（实测会真的启动两个编辑器）；`scene/open` 之后等待场景切换完成（避免 UndoRedo 绑到旧场景）；M6 增加每测试文件恢复；`teardown_environment` 不再吞掉重置失败；只有缺少 cargo 才 skip；undo 桥等待放宽到 10s（m2/m4 两份）、`wait_for` 默认与 m3 输入等待放宽；budget 测试默认排除（`pyproject.toml` 与文档一致）；`attach_game` 握手失败时打印 status/运行期目录/编辑器 console 诊断。
- undo/redo 文件桥改为带 `request_id` 的幂等协议：插件对同一 id 只执行一次并重发结果，harness 超时后重投命令即可覆盖「命令在编辑器读取前被上一帧删除」的竞态与编辑器短暂卡顿，读取结果容忍 Windows rename 共享冲突；m5 InputMap 用例自建动作后自行清理，不再依赖文件基线回滚运行时状态。编辑器终止改为整棵进程树（Windows 的 `godot_console.exe` 会以子进程启动真正的 `godot.exe`，只终止 wrapper 会留下编辑器占用内存/端口/项目目录）。
- 新增 `GDAPI_E2E_TRANSPORT=engine_debugger`：让整套 E2E 走 EngineDebugger 数据面（默认仍是确定性的 file transport），并补 [外部 godot-mcp 能力对比](docs/reports/2026-10-03-external-parity-comparison.md) 与 [遗留问题清单](docs/todos/2026-10-03-open-issues.md)。
- 里程碑 route manifest 调整为 M5 = 25、M6 = 7；新增桌面导出验收 `tests/e2e/m5/test_export.py`。
- 修正 fixture 导出预设平台名（`Windows` → `Windows Desktop`）——此前 Godot 会忽略该预设，导致桌面导出用例无法执行。
- Godot 开发验证基线更新为 4.7.2，Windows 测试默认路径改为 `D:\app\devel\Godot\v4.7.2\godot_console.exe`；其他平台仍默认使用 PATH 中的 `godot`。
- 共享 E2E fixture 接入现有二进制解析器，保留显式 `godot_bin` 参数及 `GODOT_BIN` 环境变量覆盖，修复其绕过 Windows 默认路径的问题。
- 完成 [Godot 4.7.1 → 4.7.2 变更与兼容性核对](docs/reports/2026-10-03-godot-4.7.2-upgrade.md)；保持 godot-rust 0.5.4 / `api-4-7` 和最低兼容版本 4.7，不新增补丁版本适配分支。
- 新增 `scripts/check.py` 顺序门禁与 `.github/workflows/verify.yml`：GDScript/Rust 格式与 lint、clippy、workspace 单测、独立单编辑器 file/EngineDebugger/真实 OpenGL renderer E2E 及完整 headless 360s 预算；成功等待分布（P50/P95/P99/max）仅提供 P99×3 建议，不自动改变原验收阈值。CI 固定 Godot 4.7.2 与校验 SHA256 的 Mesa 软件 OpenGL。
- E2E walltime 优化保持测试选择与 360s 默认预算不变：M3 数据面共享 package-scoped runtime session 且每测试仍恢复状态；导出覆盖回归预置旧产物，用一次真实导出验证覆盖与摘要。
- GUI E2E readiness 现在要求 OpenGL renderer 与 gdapi HTTP API 同时就绪，并验证 readiness 失败时终止且回收 editor 进程，避免误判启动成功和遗留孤儿进程。
