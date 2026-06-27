# Godot 操控工具生态重新研究报告（含 gdcli 对比）

> 日期：2026-06-27  
> 范围：`D:\AI\godot-ws\godot-tools` 下 9 个项目 + 本仓库 `gdcli`。  
> 方法：重新阅读源码、插件入口、通讯层、工具注册表、配置与 license；未参考既有 `docs/papers` 报告。  
> 目标：总结各项目通讯方式、插件形态、语言栈、Godot 操控能力，以及 gdcli 可借鉴/复刻的能力素材。本文不提供实现计划。

## 分析项目目录索引

| 项目 | 本地目录 |
|---|---|
| gdcli | `D:\AI\godot-ws\gdcli` |
| Coding-Solo/godot-mcp | `D:\AI\godot-ws\godot-tools\Coding-Solo_godot-mcp` |
| DaxianLee/godot-mcp | `D:\AI\godot-ws\godot-tools\DaxianLee_godot-mcp` |
| ee0pdt/Godot-MCP | `D:\AI\godot-ws\godot-tools\ee0pdt_Godot-MCP` |
| hi-godot/godot-ai | `D:\AI\godot-ws\godot-tools\hi-godot_godot-ai` |
| IvanMurzak/Godot-MCP | `D:\AI\godot-ws\godot-tools\IvanMurzak_Godot-MCP` |
| tomyud1/godot-mcp | `D:\AI\godot-ws\godot-tools\tomyud1_godot-mcp` |
| tugcantopaloglu/godot-mcp | `D:\AI\godot-ws\godot-tools\tugcantopaloglu_godot-mcp` |
| youichi-uda/godot-mcp-pro | `D:\AI\godot-ws\godot-tools\youichi-uda_godot-mcp-pro` |
| yurineko73/Godot-MCP-Native | `D:\AI\godot-ws\godot-tools\yurineko73_Godot-MCP-Native` |

---

## 1. 总览结论

### 1.1 生态共性

1. 主流架构都是三段式：AI 客户端 → MCP/CLI 服务 → Godot 编辑器/运行时。
2. 若目标是实时操控 Godot，几乎都需要 Godot 插件或运行时脚本；纯文件/CLI 模式只能覆盖离线场景编辑与项目启动。
3. 通讯分为 5 类：
   - MCP `stdio` + Godot headless CLI：Coding-Solo、tugcantopaloglu 部分能力。
   - MCP `stdio` + WebSocket 插件：ee0pdt、tomyud1、youichi-uda（README/插件侧）。
   - Python/C#/GDScript HTTP/SSE/streamable HTTP：hi-godot、IvanMurzak、DaxianLee、yurineko73。
   - Runtime 专用通道：EngineDebugger、TCP autoload、WebSocket role、文件 IPC、SignalR。
   - gdcli 自身：CLI 命令 + LSP TCP + Rust GDExtension HTTP addon。
4. 能力覆盖从小到大：
   - 小型：Coding-Solo 14、ee0pdt 16。
   - 中型：gdcli 12 CLI 子命令 + 18 HTTP route、IvanMurzak 39、hi-godot 41、tomyud1 65。
   - 大型：DaxianLee 74 聚合工具、tugcantopaloglu 154、yurineko73 155、youichi-uda 174。
5. 大型项目都开始治理工具数量：hi-godot 用 `*_manage` 聚合；yurineko73 用 30 core + 125 supplementary；DaxianLee 用 category toggle；youichi-uda 的模式过滤在 server 侧（server 未开源）。
6. gdcli 当前强项：Rust CLI、LSP、GDExtension HTTP 安全、嵌入式 addon 安装。主要短板：操控域少、无 UndoRedo、无运行时探针、节点/脚本/资源/信号能力不完整。

### 1.2 项目总表

| 项目 | 语言 | AI ↔ 服务 | 服务 ↔ Godot | 插件 | 工具/命令 | 资源端点 | 许可 |
|---|---|---|---|---|---:|---:|---|
| **gdcli** | Rust + GDScript + Rust GDExtension | CLI | LSP TCP + HTTP addon | 是 | 12 CLI + 18 route | 0 | MIT |
| Coding-Solo/godot-mcp | TS + GDScript | MCP stdio | headless CLI | 否 | 14 | 0 | MIT |
| DaxianLee/godot-mcp | GDScript | HTTP JSON-RPC/MCP | 插件内 EditorInterface | 是 | 74 | 0 | Non-Commercial |
| ee0pdt/Godot-MCP | TS + GDScript | FastMCP stdio | WebSocket 9080 | 是 | 16 | 11 | MIT |
| hi-godot/godot-ai | Python + GDScript | stdio/SSE/HTTP | WebSocket 9500 + EngineDebugger | 是 | 41 | 17 | MIT |
| IvanMurzak/Godot-MCP | C# + TS CLI | streamable HTTP | SignalR | 是 | 39 | 0 | Apache-2.0 |
| tomyud1/godot-mcp | TS + GDScript | stdio + proxy HTTP | WebSocket 6505 | 是 | 65 | 5 | MIT |
| tugcantopaloglu/godot-mcp | TS + GDScript | MCP stdio | headless CLI + TCP 9090 | 否，注入 autoload | 154 | 0 | MIT |
| youichi-uda/godot-mcp-pro | GDScript；server 专有 | README 称 stdio | WS 6505-6514 + file IPC | 是 | 174 | 0 | addon MIT/server proprietary |
| yurineko73/Godot-MCP-Native | GDScript | HTTP/SSE 或 stdio | 插件内 + EngineDebugger | 是 | 155（30 默认） | 7 | MIT |

---

## 2. gdcli 当前能力画像

### 2.1 元信息与技术栈

- 版本：workspace `0.2.0`，见 `Cargo.toml:5-8`。
- 许可：MIT，见 `Cargo.toml:5-8`。
- Godot 兼容：GDExtension `compatibility_minimum = "4.3"`，见 `gdapi/addon/gdapi.gdextension:1-4`；Rust crate `godot` 使用 `api-4-3`，见 `gdapi/rust/Cargo.toml:11-14`。
- 语言：Rust CLI + Rust GDExtension + GDScript addon runtime。
- CLI 依赖：`clap`、`tokio`、`serde`、`ureq`、`include_dir`、`toon-format`，见 `cli/Cargo.toml:12-23`。
- gdapi 依赖：`godot = 0.5`、`tokio`、`httparse`，见 `gdapi/rust/Cargo.toml:11-14`。

### 2.2 通讯方式

- 用户/AI 通过 shell 直接调用 CLI。全局参数：`--host`、`--port`、`--project`、`--json`，见 `cli/src/main.rs:51-68`。
- LSP：TCP + JSON-RPC `Content-Length` framing，见 `cli/src/lsp/transport.rs:1-12`、`cli/src/lsp/transport.rs:243-288`。
- LSP 端口发现：`--port` → `.godot/gdapi.json:lsp_port` → 默认 `6005`，见 `cli/src/main.rs:247-270`。
- gdapi HTTP：addon 默认 hint `7890`，写 `.godot/gdapi.json`，见 `gdapi/addon/plugin.gd:13-18`、`gdapi/addon/plugin.gd:173-189`。
- HTTP server 只绑定 `127.0.0.1`，扫描 64 个端口，见 `gdapi/rust/src/server.rs:23-24`、`gdapi/rust/src/server.rs:118-128`。
- CLI `exec` POST 到 `http://127.0.0.1:{http_port}/{command}`，见 `cli/src/exec.rs:43-72`。
- Bearer token：CLI 发送，server 校验，见 `cli/src/exec.rs:78-87`、`gdapi/rust/src/server.rs:419-435`。

### 2.3 插件形态

- addon 配置：`gdapi/addon/plugin.cfg:1-7`。
- 插件入口：`gdapi/addon/plugin.gd:7-8`，`@tool extends EditorPlugin`。
- GDExtension：`gdapi/addon/gdapi.gdextension:1-14`。
- Rust 暴露 `GdApiServer.create/start/stop/poll_request/send_response`，见 `gdapi/rust/src/lib.rs:45-87`、`gdapi/rust/src/lib.rs:113-201`。
- GDScript runtime 层：router/request/response/route_handler，见 `gdapi/addon/runtime/router.gd:1-23`、`request.gd:7-24`、`response.gd:7-30`。
- 当前无 dock/panel UI；插件负责 server 生命周期、路由扫描、metadata、请求轮询。

### 2.4 CLI 命令清单

| 命令 | 协议 | 能力 |
|---|---|---|
| `status` | HTTP `/ping` + LSP initialize | 检查 gdapi 与 LSP |
| `install [--force] [--no-enable]` | 文件系统 | 安装/启用嵌入 addon |
| `exec <command> [args...] [--data JSON|@file|-]` | HTTP | 调用 gdapi route |
| `lsp rename` | LSP | 重命名符号 |
| `lsp references` | LSP | 查找引用 |
| `lsp definition` | LSP | 定义跳转 |
| `lsp declaration` | LSP | 声明跳转 |
| `lsp symbols` | LSP | 文档符号 |
| `lsp hover` | LSP | Hover 文档 |
| `lsp native-symbol` | Godot LSP extension | 原生类/成员元数据 |
| `lsp diagnostics` | LSP notification cache | 诊断 |
| `lsp capabilities` | LSP initialize | capabilities |

证据：`cli/src/main.rs:77-141`、`cli/src/lsp/client.rs:218-361`。

### 2.5 gdapi HTTP routes

所有 route 均为 HTTP `POST`，router 强制 POST，见 `gdapi/addon/runtime/router.gd:139-150`。

| Route | 能力 |
|---|---|
| `/ping` | 健康检查、gdapi/editor version |
| `/routes` | route 名称列表 |
| `/help` | route 文档 |
| `/commands` | 详细命令列表 |
| `/command-help` | 单命令文档 |
| `/godot/version` | Godot version |
| `/project/info` | 项目信息 |
| `/uid/get` | 读取 `.uid` |
| `/uid/update_all` | 扫描资源并更新 UID |
| `/scene/save` | 保存/另存场景 |
| `/scene/create` | 创建场景 |
| `/scene/add_node` | 添加节点并设置属性 |
| `/scene/load_sprite` | 设置 Sprite/TextureRect texture |
| `/scene/export_mesh_library` | 导出 MeshLibrary |
| `/project/run` | 运行主场景/指定场景 |
| `/project/stop` | 停止运行 |
| `/log/output` | 读取 Editor Output |
| `/log/level` | 查询/设置日志等级 |

### 2.6 gdcli 对比定位

**优势**

- Rust 网络层安全性更好：loopback、token、header/body limit、CR/LF header 防注入，见 `gdapi/rust/src/http.rs:11-13`、`gdapi/rust/src/http.rs:104-130`。
- 嵌入式 addon 安装成熟：`include_dir!`，见 `cli/src/embedded_addon.rs:1-18`；install 解包并可启用插件，见 `cli/src/install.rs:23-76`。
- LSP 能力是多数 MCP 工具不具备的强项：rename/references/definition/diagnostics/nativeSymbol。

**短板**

- 无 UndoRedo；scene mutation 直接保存，例：`gdapi/addon/routes/editor/scene/add_node.gd:72-85`。
- 节点能力只有 add，缺 delete/duplicate/move/rename/reparent/property query/select。
- 脚本能力主要靠 LSP，缺 create/read/patch/attach/detach。
- 资源、信号、组、动画、TileMap、材质/Shader、UI、音频、导航、物理几乎缺失。
- 无 runtime scene tree、runtime input、runtime screenshot、runtime node inspect、EngineDebugger probe。

---

## 3. 外部项目研究

### 3.1 Coding-Solo/godot-mcp

- 通讯：AI ↔ MCP 用 `stdio`，见 `src/index.ts:17`、`src/index.ts:2204-2206`；MCP ↔ Godot 用 `godot --headless --script godot_operations.gd`，见 `src/index.ts:511-528`。
- 插件：无 `addons/`；使用 standalone `src/scripts/godot_operations.gd`，`extends SceneTree`，一次执行后退出，见 `godot_operations.gd:1-2`、`godot_operations.gd:59-78`。
- 语言：TypeScript + GDScript。版本 `0.1.1`，MIT。
- 工具 14：`launch_editor`、`run_project`、`get_debug_output`、`stop_project`、`get_godot_version`、`list_projects`、`get_project_info`、`create_scene`、`add_node`、`load_sprite`、`export_mesh_library`、`save_scene`、`get_uid`、`update_project_uids`。
- 特点：路径遍历拒绝、class name regex、`execFile` 参数数组、stderr logging，见 `src/index.ts:207-225`、`src/index.ts:265`、`src/index.ts:528`。
- 局限：无 EditorInterface、无 UndoRedo、无运行时 RPC，只能捕获运行进程 stdout/stderr。

### 3.2 DaxianLee/godot-mcp

- 通讯：纯 GDScript 插件内置 HTTP JSON-RPC/MCP server，默认 `127.0.0.1:3000`，见 `addons/godot_mcp/mcp_server.gd:45-47`、`addons/godot_mcp/mcp_server.gd:118-129`。
- endpoints：`POST /mcp`、`GET /health`、`GET /api/tools`、`OPTIONS`，见 `mcp_server.gd:321-330`。
- 插件：`addons/godot_mcp/plugin.cfg:1-7`；右侧 dock，Server/Tools/Config tabs，见 `plugin.gd:111-142`。
- 语言：纯 GDScript。版本 `1.0.0`，Non-Commercial。
- 工具 74，按 category prefix 暴露，注册见 `mcp_server.gd:200-239`。
- 能力：scene management/hierarchy/run；node query/lifecycle/transform/property/hierarchy/signal/group/process/metadata/call/visibility/physics；resource；project settings/input/autoload；script manage/attach/edit/open；editor status/settings/UndoRedo/notification/inspector/filesystem/plugin；debug log/performance/profiler/ClassDB；filesystem；animation/AnimationTree；material/shader/light/particle；TileMap/geometry/physics/navigation/audio/UI/signal/group。
- 特点：工具分类与 UI toggle 很完善；i18n 9 语言，见 `i18n/localization.gd:17-40`；UndoRedo 能力暴露，见 `editor_tools.gd:548-556`；Variant 转换见 `tools/base_tools.gd:516-687`。
- 风险：无 auth；CORS `*`，见 `mcp_server.gd:604-607`。

### 3.3 ee0pdt/Godot-MCP

- 通讯：FastMCP stdio，见 `server/src/index.ts:1`、`server/src/index.ts:72-74`；Node 连接 Godot WebSocket `ws://localhost:9080`，见 `server/src/utils/godot_connection.ts:42-68`；Godot 插件监听 9080，见 `addons/godot_mcp/mcp_server.gd:4-6`。
- 插件：GDScript `@tool EditorPlugin`，见 `addons/godot_mcp/mcp_server.gd:1-2`；有 UI 文件，但主流程更像直接启动 server。
- 语言：TypeScript + GDScript。版本 `1.0.0`，MIT。
- MCP 工具 16：node 5、script 4、scene/project/resource 6、editor 1（`execute_editor_script`）。
- MCP resources 11：scenes/current scene/script/scripts/script metadata/project structure/settings/resources/editor state/selected node/current script。
- 特点：小而清楚的 WebSocket 插件架构；MCP resources 提供上下文；`execute_editor_script` 灵活但高风险。
- UndoRedo：部分 mutation 使用，create/delete 不完整。

### 3.4 hi-godot/godot-ai

- 通讯：Python FastMCP 支持 `stdio`、`sse`、`streamable-http`，见 `src/godot_ai/__init__.py:50-61`；Python ↔ Godot 用 WebSocket `127.0.0.1:9500`，见 `src/godot_ai/transport/websocket.py:102-130`。
- Runtime：EditorDebuggerPlugin + runtime autoload + EngineDebugger；截图通过 viewport texture → PNG/base64，见 `runtime/game_helper.gd:51-86`、`runtime/game_helper.gd:140-180`。
- 插件：GDScript addon，右侧 dock `Godot AI`，见 `plugin.gd:401-406`。
- 语言：Python + GDScript。版本 `2.8.0`，MIT。
- 工具 41 named tools，注册见 `src/godot_ai/server.py:341-395`；核心模式为 `*_manage` rollup。
- 能力：session/editor/scene/node/script/project/filesystem/game/runtime/input map/autoload/resource/material/particle/camera/audio/theme/UI/signal/testing/API/ClassDB/batch/logs/screenshot/client config。
- resources 17：sessions、scene、selection、logs、project、node properties/children/groups、script、editor state、materials、input map、performance、test results、class metadata。
- 特点：19 客户端配置，见 `clients/_registry.gd:8-28`；batch rollback，见 `handlers/batch_handler.gd:73-87`；UndoRedo 注入，见 `plugin.gd:240-264`；Origin/Host/Sec-Fetch guard，见 `transport/origin_guard.py:275-418`；路径校验，见 `utils/path_validator.gd:68-147`。

### 3.5 IvanMurzak/Godot-MCP

- 通讯：AI ↔ server 为 streamable HTTP MCP `<host>/mcp`；Godot ↔ server 为 SignalR `<host>/hub/mcp-server`，见 `Runtime/Connection/GodotMcpConfig.cs:271-282`。
- 插件：C# `EditorPlugin`，右上 dock，见 `addons/godot_mcp/plugin.cfg:1-7`、`Editor/GodotMcpPlugin.cs:206-220`。
- 语言：C#/.NET 8/Godot.NET.Sdk 4.3 + TypeScript CLI。版本 `0.13.3`，Apache-2.0。
- 工具 39：ping、console logs、runtime errors、reflection method find/call、editor state/selection、filesystem、node CRUD、resource CRUD、scene open/save/list/data、screenshot viewport/camera/isolated、script CRUD/attach/validate。
- 特点：`[AiToolType]` / `[AiTool]` 反射扫描注册，见 `GodotMcpConnection.cs:378-413`；C# 反射可调用 private/static/instance 方法，见 `Tool_Reflection.MethodCall.cs:109-156`；下载 server 做 SHA256 校验，见 `GodotMcpServerView.cs:373-399`。
- 局限：未发现 UndoRedo；强依赖 C#/.NET/SignalR。

### 3.6 tomyud1/godot-mcp

- 通讯：MCP stdio；第一个进程 primary，后续 stdio proxy 通过本地 HTTP 转发，见 `mcp-server/src/index.ts:8-20`、`primary-http.ts:81-127`。
- Godot 通道：WebSocket `127.0.0.1:6505`；editor/runtime 用 `godot_ready.role` 区分，见 `types.ts:55-61`、`mcp_client.gd:100-106`、`runtime/mcp_runtime.gd:43-52`。
- 插件：GDScript addon，toolbar 状态 label；runtime helper autoload `MCPRuntime`，见 `plugin.gd:104-132`、`plugin.gd:47-55`。
- 语言：TypeScript + GDScript + browser visualizer JS/CSS/HTML。版本 `0.5.0`，MIT。
- 工具 65：built-in 2、file 4、script/file 6、scene 27、project/editor/runtime 24、asset 1、visualizer 1。
- resources 5：testing-loop、scene-editing、asset-generation、troubleshooting、tool-index。
- 特点：editor/runtime 双 role 模型清楚；多客户端 primary/proxy；`generate_2d_asset` SVG→PNG，见 `asset_tools.gd:75-83`；`map_project` 浏览器可视化，见 `visualizer-server.ts:60-83`；文件删除需 confirm、备份、拒绝打开 tab，见 `script_tools.gd:273-352`。
- 局限：未见 UndoRedo；loopback 但无 token。

### 3.7 tugcantopaloglu/godot-mcp

- 通讯：MCP stdio；headless CLI 操作；runtime 注入 TCP autoload `127.0.0.1:9090`，见 `src/index.ts:613-632`、`src/index.ts:337-367`、`src/scripts/mcp_interaction_server.gd:21-26`。
- 插件：无 addon；复制/注入 `mcp_interaction_server.gd` 到项目 autoload。
- 语言：TypeScript + GDScript。版本 `1.0.0`，MIT；是 Coding-Solo 衍生，见 `LICENSE:4`。
- 工具 154：editor/process/discovery 7；headless/project/file mutation 32；export/build/CI 5；runtime general/node/input/signal 49；network 4；3D/mixed 25；2D 8；UI 9；animation/audio/render/resource/media 15。
- 特点：运行时能力最广；Variant 转换覆盖 Vector/Color/Quaternion/Basis/Transform/Rect/AABB/NodePath/PackedArray/Resource/Node，见 `mcp_interaction_server.gd:791-1004`；busy flag + 30s timeout，见 `mcp_interaction_server.gd:10-13`；2D/3D 自动检测，见 `mcp_interaction_server.gd:1397-1498`。
- 局限：无 UndoRedo；runtime TCP 无 auth；`game_eval` 高风险。

### 3.8 youichi-uda/godot-mcp-pro

- 通讯：public repo 只有 addon；server 未开源，`LICENSE:25-27` 说明 TypeScript MCP server proprietary。README 称 AI ↔ Node server 用 stdio/MCP，Node ↔ Godot 用 WebSocket，见 `README.md:5-9`。
- Godot 插件：WebSocket client 扫描 `6505-6514`，见 `websocket_server.gd:17-18`、`websocket_server.gd:35-41`。
- Runtime：file IPC，`user://mcp_game_request`、`mcp_game_response`、`mcp_input_commands`、screenshot files，见 `mcp_game_inspector_service.gd:5-6`、`runtime_commands.gd:314-356`。
- 插件：GDScript addon，bottom panel `MCP Pro`，Activity/Clients/Tools tabs，见 `plugin.gd:37-41`、`ui/status_panel.gd:91-93`。
- 版本 `1.15.0`；addon MIT，server proprietary。
- 工具 174（源码 registry，`plugin.cfg` 声称 175）：project 10、scene 10、node 17、script 7、editor 13、input 5、runtime advanced 19、animation 6、TileMap 6、theme/UI 7、profiling 2、batch/refactor 7、shader 6、export 3、resource 4、input map 2、3D scene 6、physics 6、analysis 6、AnimationTree 8、audio 6、navigation 5、particles 5、testing/QA 5、Android 3。
- 特点：能力覆盖最完整；UndoRedo 广泛使用，见 `base_command.gd:217-237`、`node_commands.gd:89-95`；文件冲突保护，见 `base_command.gd:165-209`；runtime crash recovery，见 `mcp_game_inspector_service.gd:59-70`；图标匹配避免本地化问题，见 `plugin.gd:131-154`。
- 局限：server 不开源，模式过滤无法验证。

### 3.9 yurineko73/Godot-MCP-Native

- 通讯：纯 GDScript MCP server，支持 HTTP/SSE 与 stdio，见 `native_mcp/mcp_server_core.gd:13-16`、`mcp_server_native.gd:21-31`。
- HTTP：Godot `TCPServer`，`POST /mcp` 或 `/`；SSE 通过 `Accept: text/event-stream`，见 `mcp_http_server.gd:38-42`、`mcp_http_server.gd:449-492`。
- Runtime：EditorDebuggerPlugin + `MCPRuntimeProbe` autoload + EngineDebugger，见 `mcp_debugger_bridge.gd:1-3`、`runtime/mcp_runtime_probe.gd:24-38`。
- 插件：主屏插件，UI 有 Settings/Tool Manager，见 `mcp_server_native.gd:322-333`、`ui/mcp_panel_native.gd:103-123`。
- 语言：GDScript。版本 `1.0.7-pre1`，MIT。
- 工具 155 注册；默认暴露 30 core，125 supplementary 可启用。resources 7。
- Core 30：editor logs/print/clear；editor script/state/run/stop；node props/list/tree；node CRUD/duplicate/move/rename；project info/settings/resources；scene create/save/open/current；script execute/list/read/create/modify/current/attach。
- Supplementary：debugger/breakpoints/stack/variables/step/runtime probe/runtime scene/input/animation/material/theme/shader/tilemap/audio/screenshot/condition/assert；editor selection/export/screenshot/signals/reload；project input/autoload/global classes/ClassDB/tests/C# support/render compare/resource UID/deps/audit；script symbols/definition/references/rename/analyze/validate/search。
- resources：`godot://scene/list`、`scene/current`、`script/list`、`script/current`、`project/info`、`project/settings`、`editor/state`，见 `mcp_server_native.gd:595-681`。
- 特点：Core/supplement 分层；Bearer token auth，见 `mcp_auth_manager.gd:11-79`；UndoRedo，见 `node_tools_native.gd:147-154`；Vibe Coding policy，见 `vibe_coding_policy.gd:7-32`；MCP protocol negotiation，见 `mcp_server_core.gd:315-355`；audit log，见 `mcp_server_core.gd:890-986`。

---

## 4. 能力域对比矩阵

| 能力域 | gdcli | Coding | Daxian | ee0 | hi | Ivan | tomy | tugcan | youichi | yurineko |
|---|---|---|---|---|---|---|---|---|---|---|
| 项目信息/Godot version | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠️ | ✅ | ✅ | ✅ | ✅ |
| 场景创建/保存 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 场景结构查询 | ❌ | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 节点 CRUD | ⚠️ add | ⚠️ add | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 节点属性 get/set | ⚠️ | ⚠️ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| hierarchy/reparent/move | ❌ | ❌ | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 信号/分组 | ❌ | ❌ | ✅ | ❌ | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ |
| 脚本 CRUD/attach | ❌ | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| LSP rename/ref/diag | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ⚠️ |
| filesystem read/write/search | ❌ | ⚠️ | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 资源 CRUD/deps | ⚠️ | ⚠️ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| material/shader | ❌ | ❌ | ✅ | ❌ | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ runtime |
| animation/AnimationTree | ❌ | ❌ | ✅ | ❌ | ✅ | ❌ | ⚠️ | ✅ | ✅ | ✅ runtime |
| TileMap | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ runtime |
| physics/navigation | ❌ | ❌ | ✅ | ❌ | ✅/❌ | ❌ | ✅/❌ | ✅ | ✅ | ⚠️ runtime |
| UI/theme/audio | ❌ | ❌ | ✅ | ❌ | ✅ | ❌ | ⚠️ | ✅ | ✅ | ✅ runtime |
| run/stop | ✅ | ✅ | ✅ | ❌ | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ |
| runtime scene/node | ❌ | ❌ | ❌ | ❌ | ✅ | ⚠️ | ✅ | ✅ | ✅ | ✅ |
| runtime input | ❌ | ❌ | ❌ | ❌ | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ |
| screenshot/frame capture | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| code execution/eval | ❌ | ❌ | ❌ | ✅ editor | ✅ | reflection | ❌ | ✅ | ✅ | ✅ |
| export/deploy/CI | ❌ | ⚠️ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ Android | ✅ |
| Testing/QA | ❌ | ❌ | ❌ | ❌ | ✅ | ❌ | guide | ❌ | ✅ | ✅ |
| UndoRedo | ❌ | ❌ | ✅ | ⚠️ | ✅ | ❌ | ❌ | ❌ | ✅ | ✅ |
| Auth/token | ✅ | ❌ | ❌ | ❌ | Origin guard | ✅ | ❌ | ❌ | server unknown | ✅ |
| 工具数治理 | N/A | N/A | category | ❌ | rollup | reflection | proxy/guides | ❌ | modes | core/supp |

---

## 5. gdcli 可借鉴/复刻的能力素材

### 5.1 基础编辑能力

- 场景：open/current/tree/save_as/close/list_open_scenes。参考 DaxianLee scene、yurineko core scene、youichi scene 10。
- 节点：delete/duplicate/rename/move/reparent/property get/set/select/groups/signals。参考 DaxianLee node 12 类、youichi node 17、yurineko core node。
- 属性类型转换：JSON ↔ Godot Variant，包括 Vector2/3、Color、Quaternion、Basis、Transform、Rect2、AABB、NodePath、Resource。参考 tugcantopaloglu `mcp_interaction_server.gd:791-1004`、DaxianLee `base_tools.gd:516-687`。
- UndoRedo：所有编辑器 mutation 尽量通过 `EditorUndoRedoManager`。参考 youichi `base_command.gd:217-237`、yurineko `node_tools_native.gd:147-154`、hi-godot node handler。

### 5.2 脚本与 LSP 融合

- gdcli 已有 LSP rename/references/definition/diagnostics，是优势。
- 可借鉴：script create/read/edit/patch/attach/detach/validate/open_at_line/current_script。
- 高级：symbols、definition、references、rename 可统一包装成 HTTP route 或 future MCP resource。
- 高风险能力：`execute_editor_script`/runtime eval 需 opt-in、安全等级、审计日志。参考 yurineko 将 `execute_editor_script` 标注破坏性并带 audit。

### 5.3 资源与游戏系统

- Resource CRUD/info/deps/preview/reimport/UID/fix UID。参考 yurineko project advanced、youichi resource。
- Material/Shader：create/read/edit/assign/set params。参考 DaxianLee、youichi、hi-godot。
- Animation/AnimationTree：AnimationPlayer、track、keyframe、state machine、blend tree。参考 DaxianLee、youichi。
- TileMap/TileSet：set cell/fill/get used cells/clear/info。参考 DaxianLee、youichi。
- Physics/navigation/audio/UI/theme/input map：这些都是真实游戏开发高频域，DaxianLee 和 youichi 覆盖最完整。

### 5.4 运行时闭环

- runtime scene tree、runtime node inspect/set/call。
- runtime input：key/mouse/gamepad/action/touch。
- runtime screenshot/frame capture/property monitor/log/error buffer。
- runtime wait/assert/condition，用于 AI 自测。
- 首选参考：EngineDebugger 方案（hi-godot、yurineko），更符合 Godot 架构；备选：tomyud1 role WebSocket；简单方案：youichi file IPC；快速但侵入：tugcan TCP autoload。

### 5.5 工具面治理

- 若未来 gdcli 提供 MCP server 或大量 HTTP route，需提前分类：
  - core/default：少量高频安全工具。
  - supplementary：高级/危险/领域工具按需启用。
  - rollup：`node_manage {op, params}`、`scene_manage {op, params}` 形式减少工具数。
  - mode：lite/full/runtime/debug。
- 参考：hi-godot `*_manage`；yurineko core/supplement；DaxianLee category toggle。

### 5.6 安全与可恢复性

- 保留 gdcli 现有 loopback + Bearer token + header/body limit。
- 增加路径 validator：限制 `res://`/`user://`，拒绝 `..`、绝对系统路径、敏感文件。
- 增加 UndoRedo 与 dry-run/force 机制：尤其 cross-scene、file delete、script overwrite。
- 增加 file conflict safety：打开的 scene/script/shader 默认拒绝离线覆盖。参考 youichi `base_command.gd:165-209`。
- 增加 audit log：记录危险工具调用、参数摘要、结果。参考 yurineko `mcp_server_core.gd:890-986`。
- 对 eval、OS、file delete、export、network、CI 生成等工具分级。

---

## 6. 架构模式评价

### 6.1 Headless CLI

代表：Coding-Solo、tugcantopaloglu 部分能力。  
优点：零插件、易打包、权限边界清楚。  
缺点：启动慢、无实时 editor state、无 UndoRedo、无法控制已打开编辑器。  
适合：离线创建场景、简单资源处理、项目扫描。

### 6.2 WebSocket 插件 + 外部 server

代表：ee0pdt、hi-godot、tomyud1、youichi-uda。  
优点：实时双向、实现简单、Node/Python MCP SDK 成熟。  
缺点：需要外部进程与插件配对，端口/生命周期/多客户端要处理。  
适合：MCP-first 工具、实时编辑器控制。

### 6.3 插件内置 MCP/HTTP

代表：DaxianLee、yurineko73。  
优点：安装插件即服务，无外部 server。  
缺点：GDScript 自实现 HTTP/SSE/MCP 较复杂，安全细节容易漏。  
适合：纯 Godot 生态、零依赖、局域/本机工具。

### 6.4 GDExtension HTTP addon

代表：gdcli。  
优点：Rust 承担网络层，安全/性能/协议解析强；GDScript 专注 Editor API。  
缺点：GDExtension 编译与平台分发复杂；当前功能覆盖不足。  
适合：长期做高质量 CLI/agent bridge。

### 6.5 EngineDebugger Runtime Probe

代表：hi-godot、yurineko73。  
优点：Godot 原生调试链路，适合运行时截图、输入、断点、变量、scene tree。  
缺点：实现复杂，需要 editor debugger plugin + runtime autoload/probe。  
适合：gdcli 未来做运行时闭环验证。

---

## 7. 研究附录：代码规模粗略对比

| 项目 | 主要 LOC 概况 |
|---|---|
| gdcli | Rust ~6.6k；GDScript ~2.3k |
| Coding-Solo | TS ~2.2k；GDScript ~1.2k |
| DaxianLee | GDScript ~23k |
| ee0pdt | GDScript ~1.9k；TS ~1.1k |
| hi-godot | core GDScript ~25.6k；core Python ~7.7k |
| IvanMurzak | C# ~37.7k；TS ~11.4k |
| tomyud1 | GDScript ~6.6k；TS ~3.9k；JS/CSS visualizer sizable |
| tugcantopaloglu | TS source ~6.9k；GDScript ~6.2k |
| youichi-uda | GDScript ~13.8k；server 源码未公开 |
| yurineko73 | addon GDScript ~22.3k |

---

## 8. 总结

gdcli 现在更像“安全、轻量、LSP 友好”的 Godot CLI bridge；生态中成熟 MCP 项目已经演化成“编辑器操控 + 运行时验证 + 工具面治理 + 安全分级”的完整系统。最值得学习的不是单个项目，而是能力组合：

1. gdcli 保持 Rust/GDExtension HTTP 安全底座。
2. 基础编辑能力参考 DaxianLee/yurineko/youichi。
3. 工具治理参考 hi-godot/yurineko。
4. 运行时闭环参考 hi-godot/yurineko EngineDebugger，辅以 tomyud1 role 模型。
5. 安全与恢复参考 gdcli 现有 token、youichi file conflict、yurineko audit、hi-godot origin/path guard。

若目标是让 AI agent 真正操控 Godot，最低能力闭环应覆盖：场景树查询、节点 CRUD、属性读写、脚本 CRUD/attach、信号/组、资源管理、运行/停止、日志、截图、runtime node inspect、输入模拟、UndoRedo、安全审计。gdcli 当前只覆盖其中小部分，但底层架构适合继续扩展。