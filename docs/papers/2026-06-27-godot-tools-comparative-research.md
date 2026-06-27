# Godot 操控工具生态深度调研报告

> **日期**: 2026-06-27
> **范围**: `D:\AI\godot-ws\godot-tools` 目录下 9 个开源项目的全面分析
> **目标**: 为 gdcli 项目借鉴、引入操控能力提供决策依据

## 分析项目目录索引

| 项目 | 本地目录 |
|------|----------|
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

## 目录

1. [项目总览](#1-项目总览)
2. [通讯协议对比](#2-通讯协议对比)
3. [编程语言与技术栈对比](#3-编程语言与技术栈对比)
4. [Godot 插件架构对比](#4-godot-插件架构对比)
5. [操控能力全景分类](#5-操控能力全景分类)
6. [各项目操控能力详细清单](#6-各项目操控能力详细清单)
7. [操控能力矩阵汇总](#7-操控能力矩阵汇总)
8. [架构模式与设计决策分析](#8-架构模式与设计决策分析)
9. [gdcli 可借鉴的能力清单](#9-gdcli-可借鉴的能力清单)
10. [附录：各项目原始数据](#10-附录各项目原始数据)

---

## 1. 项目总览

| # | 项目 | 作者 | 语言 | 工具数 | 通讯方式 | 插件类型 |
|---|------|------|------|--------|----------|----------|
| 1 | Coding-Solo/godot-mcp | Solomon Elias | TS + GDScript | 14 | stdio + headless CLI | 无插件（headless 脚本） |
| 2 | DaxianLee/godot-mcp | LIDAXIAN | 纯 GDScript | ~100+ | HTTP (内置 TCPServer) | 纯 GDScript 插件 |
| 3 | ee0pdt/Godot-MCP | ee0pdt | TS + GDScript | 26 | stdio + WebSocket:9080 | GDScript 插件 |
| 4 | hi-godot/godot-ai | hi-godot | Python + GDScript | 120+ | stdio/SSE/HTTP + WebSocket:9500 | GDScript 插件 |
| 5 | IvanMurzak/Godot-MCP | Ivan Murzak | C# + TS | 39 | stdio/HTTP + SignalR | C# 插件 |
| 6 | tomyud1/godot-mcp | tomyud1 | TS + GDScript | 42+ | stdio + WebSocket:6505 | GDScript 插件 |
| 7 | tugcantopaloglu/godot-mcp | Tugcan Topaloglu | TS + GDScript | 149 | stdio + headless CLI + TCP:9090 | 无插件（autoload 注入） |
| 8 | youichi-uda/godot-mcp-pro | Youichi Uda | GDScript (+ 专有 TS) | 175 | WebSocket:6505-6514 | GDScript 插件 |
| 9 | yurineko73/Godot-MCP-Native | yurineko73 | 纯 GDScript | 155 | HTTP (内置 TCPServer) + stdio | 纯 GDScript 插件 |

---

## 2. 通讯协议对比

### 2.1 三层通讯架构

所有项目都遵循一个共同的三层架构模式：

```
AI Agent (Claude/Cursor/Codex)
    │
    │ MCP Protocol (JSON-RPC 2.0)
    ▼
MCP Server (中间层)
    │
    │ 各种协议
    ▼
Godot Editor / Runtime
```

### 2.2 AI ↔ MCP Server 层

| 传输方式 | 使用项目 | 说明 |
|----------|----------|------|
| **stdio** | Coding-Solo, ee0pdt, tomyud1, tugcantopaloglu | 最常见，AI 客户端直接 spawn 子进程 |
| **HTTP (streamable-http)** | DaxianLee, hi-godot, IvanMurzak, yurineko73 | 支持远程/云端连接 |
| **SSE** | hi-godot, yurineko73 | Server-Sent Events 用于服务端推送 |
| **SignalR (WebSocket)** | IvanMurzak | 基于 ASP.NET Core SignalR 的持久连接 |

### 2.3 MCP Server ↔ Godot 层

| 传输方式 | 使用项目 | 端口 | 说明 |
|----------|----------|------|------|
| **Headless CLI 子进程** | Coding-Solo, tugcantopaloglu | 无端口 | `godot --headless --script xxx.gd` 一次性执行 |
| **WebSocket (插件为客户端)** | ee0pdt, hi-godot, tomyud1, youichi-uda | 9080/9500/6505 | 插件主动连接 MCP Server |
| **HTTP (插件内置服务器)** | DaxianLee, yurineko73 | 3000/9080 | 插件本身就是 HTTP 服务器 |
| **SignalR** | IvanMurzak | 8080 | 插件通过 SignalR 连接外部 MCP Server |
| **TCP (原始 Socket)** | tugcantopaloglu (运行时) | 9090 | 运行中游戏的交互通道 |
| **文件 IPC** | youichi-uda (运行时) | 无端口 | 通过 `user://` 文件交换 JSON |
| **Godot Debugger 协议** | yurineko73 (运行时) | 无端口 | 通过 `EngineDebugger` 消息通道 |

### 2.4 运行时 (Runtime) 通讯

部分项目区分了 **编辑器时** 和 **运行时** 两种操控模式：

| 项目 | 编辑器通讯 | 运行时通讯 | 说明 |
|------|-----------|-----------|------|
| tomyud1 | WebSocket:6505 | WebSocket:6505 (role="runtime") | 同一端口，不同角色标识 |
| tugcantopaloglu | Headless CLI | TCP:9090 | 完全分离的通道 |
| youichi-uda | WebSocket:6505-6514 | 文件 IPC | 编辑器写文件，游戏 autoload 轮询 |
| yurineko73 | HTTP:9080 | EngineDebugger 消息 | 通过 Godot 内置调试器协议 |
| hi-godot | WebSocket:9500 | WebSocket:9500 + EditorDebugger | 运行时通过 debugger bus 捕获帧缓冲 |
| IvanMurzak | SignalR | SignalR (同一连接) | 运行时通过 Runtime autoload |

---

## 3. 编程语言与技术栈对比

### 3.1 MCP Server 端

| 语言 | 项目 | 框架/库 |
|------|------|---------|
| **TypeScript (Node.js)** | Coding-Solo, ee0pdt, tomyud1, tugcantopaloglu | `@modelcontextprotocol/sdk`, FastMCP |
| **Python** | hi-godot | FastMCP v3, websockets, pydantic |
| **C# (.NET 8)** | IvanMurzak | McpNetPackage, ReflectorNet |
| **纯 GDScript** | DaxianLee, yurineko73 | 自实现 HTTP/JSON-RPC |
| **专有 (未开源)** | youichi-uda | TypeScript (推测) |

### 3.2 Godot 端

| 语言 | 项目 | 说明 |
|------|------|------|
| **GDScript** | 全部 9 个项目 | 所有项目都在 Godot 端使用 GDScript |
| **C#** | IvanMurzak | 插件主体用 C#，运行时也用 C# |

### 3.3 关键依赖

| 依赖 | 用途 | 使用项目 |
|------|------|----------|
| `@modelcontextprotocol/sdk` | MCP 协议实现 | Coding-Solo, ee0pdt, tomyud1 |
| `fastmcp` (Python) | MCP 协议框架 | hi-godot |
| `ws` (npm) | WebSocket 客户端 | ee0pdt, tomyud1 |
| `websockets` (Python) | WebSocket 服务端 | hi-godot |
| `zod` | 参数校验 | ee0pdt, tomyud1 |
| `SignalR` | 实时双向通讯 | IvanMurzak |
| `ReflectorNet` | 反射/序列化 | IvanMurzak |

---

## 4. Godot 插件架构对比

### 4.1 插件存在形式

| 形式 | 项目 | 特点 |
|------|------|------|
| **纯 GDScript 插件** | DaxianLee, hi-godot, ee0pdt, tomyud1, youichi-uda, yurineko73 | 零外部依赖，直接放入 addons/ |
| **C# 插件** | IvanMurzak | 需要 .NET SDK，NuGet 依赖 |
| **无插件 (Headless)** | Coding-Solo, tugcantopaloglu | 通过 CLI 脚本操作，不需要安装插件 |
| **注入式 autoload** | tugcantopaloglu | 运行时自动注入 `mcp_interaction_server.gd` |

### 4.2 插件 UI 功能

| 项目 | Dock 面板 | 服务启停 | 端口配置 | 工具管理 | 语言切换 | 客户端配置 |
|------|-----------|----------|----------|----------|----------|------------|
| DaxianLee | ✅ 3 标签页 | ✅ | ✅ | ✅ 按类别勾选 | ✅ 9 语言 | ✅ 一键配置 |
| hi-godot | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ 19+ 客户端 |
| ee0pdt | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ |
| tomyud1 | ✅ 状态指示器 | ❌ 自动 | ❌ | ❌ | ❌ | ❌ |
| youichi-uda | ✅ 底部面板 | ✅ | ✅ | ✅ 按类别 | ❌ | ✅ |
| yurineko73 | ✅ 主屏幕标签 | ✅ | ✅ | ✅ 核心/补充分类 | ✅ | ✅ |
| IvanMurzak | ✅ "AI Game Developer" | ✅ | ✅ | ✅ | ❌ | ✅ CLI 工具 |

### 4.3 安全机制

| 机制 | 项目 | 说明 |
|------|------|------|
| **UndoRedo 集成** | DaxianLee, ee0pdt, hi-godot, IvanMurzak, youichi-uda, yurineko73 | 所有修改可 Ctrl+Z 撤销 |
| **路径遍历防护** | Coding-Solo, yurineko73 | 拒绝 `..` 路径 |
| **Bearer Token 认证** | yurineko73 | 可选 HTTP 认证 |
| **Vibe Coding 策略** | yurineko73 | 阻止 AI 改变编辑器焦点 |
| **文件冲突检测** | youichi-uda | 阻止覆盖编辑器打开的文件 |
| **工具开关** | DaxianLee, youichi-uda, yurineko73 | 按需启用/禁用工具 |
| **执行超时** | Coding-Solo, ee0pdt, tomyud1 | 防止命令挂起 |
| **重入保护** | tugcantopaloglu | `_busy` 标志 + 30s 超时 |

---

## 5. 操控能力全景分类

从所有项目中提取的操控能力可归为以下 **25 个功能域**：

| 域 | 说明 | 覆盖项目数 |
|----|------|-----------|
| **场景管理** | 创建/打开/保存/关闭/列举场景 | 9/9 |
| **节点操作** | 创建/删除/复制/移动/重命名/属性设置 | 9/9 |
| **脚本管理** | 创建/读取/编辑/附加/验证脚本 | 9/9 |
| **项目信息** | 项目设置/元数据/文件结构 | 9/9 |
| **文件系统** | 文件读写/搜索/目录管理 | 8/9 |
| **信号管理** | 连接/断开/列举/发射信号 | 7/9 |
| **编辑器控制** | 运行/停止/选择/截图/面板切换 | 8/9 |
| **资源管理** | 创建/加载/修改/删除资源 | 7/9 |
| **动画系统** | AnimationPlayer/AnimationTree/状态机 | 6/9 |
| **材质/着色器** | 材质创建/Shader 编辑/参数设置 | 6/9 |
| **物理系统** | 碰撞体/关节/射线检测/物理层 | 6/9 |
| **粒子系统** | GPU 粒子 2D/3D/预设/材质 | 5/9 |
| **音频系统** | 音频总线/效果/播放器/空间音频 | 5/9 |
| **灯光/环境** | 灯光/环境/天空/后处理 | 5/9 |
| **3D 网格/几何** | CSG/MeshInstance/GridMap/MultiMesh | 5/9 |
| **UI/主题** | Control 操作/Theme 管理/锚点 | 5/9 |
| **导航系统** | NavigationRegion/Agent/寻路 | 5/9 |
| **TileMap** | 格子操作/填充/清除 | 4/9 |
| **输入模拟** | 键盘/鼠标/手柄/触屏模拟 | 5/9 |
| **运行时调试** | 截图/属性监控/帧捕获/日志 | 6/9 |
| **代码执行** | 动态执行 GDScript | 6/9 |
| **ClassDB 内省** | 类信息查询/方法/属性/信号 | 4/9 |
| **输入映射** | InputMap 管理 | 4/9 |
| **网络** | HTTP/WebSocket/Multiplayer/RPC | 2/9 |
| **导出/构建** | 项目导出/预设管理 | 4/9 |

---

## 6. 各项目操控能力详细清单

### 6.1 Coding-Solo/godot-mcp (14 工具)

**进程管理**: `launch_editor`, `run_project`, `stop_project`, `get_debug_output`
**信息发现**: `get_godot_version`, `list_projects`, `get_project_info`
**场景操作**: `create_scene`, `add_node`, `load_sprite`, `export_mesh_library`, `save_scene`
**UID 管理**: `get_uid`, `update_project_uids`

**特色**: 安全措施（路径遍历防护、类名验证、execFile 参数化），跨平台 Godot 检测。

### 6.2 DaxianLee/godot-mcp (~100+ 工具)

**场景** (7): `get_current`, `open`, `save`, `save_as`, `create`, `close`, `reload`, `get_tree`, `get_selected`, `select`, `play_main`, `play_current`, `play_custom`, `stop`

**节点** (12 子类):
- 查询: `find_by_name`, `find_by_type`, `find_children`, `find_parent`, `get_info`, `get_children`, `get_path_to`, `tree_string`
- 生命周期: `create`, `delete`, `duplicate`, `instantiate`, `replace`, `request_ready`
- 变换: `set_position`, `set_rotation`, `set_scale`, `get_transform`, `move`, `rotate`, `look_at`, `reset`
- 属性: `get`, `set`, `list`, `reset`, `revert`
- 层级: `reparent`, `reorder`, `move_up/down`, `move_to_front/back`, `set_owner`
- 信号: `list`, `has`, `get_connections`, `connect`, `disconnect`, `emit`, `add_user_signal`
- 分组: `list`, `add`, `remove`, `is_in`, `get_nodes`, `call_group`, `notify_group`
- 处理: `get_status`, `set_process`, `set_physics_process`, `set_input`, `set_process_mode`, `set_process_priority`
- 元数据: `get`, `set`, `has`, `remove`, `list`
- 方法调用: `call`, `call_deferred`, `propagate_call`, `has_method`, `get_method_list`
- 可见性: `show`, `hide`, `toggle`, `is_visible`, `set_z_index`, `set_modulate`, `set_visibility_layer`
- 物理: `get_collision_info`, `set_collision_layer/mask`, `apply_impulse/force/torque`

**脚本** (4 子类): `create`, `read`, `write`, `get_info`, `delete`, `attach`, `detach`, `add_function`, `remove_function`, `add_variable`, `add_signal`, `add_export`, `open`, `open_at_line`

**资源** (3 子类): `list`, `search`, `get_info`, `get_dependencies`, `create`, `import`, `copy`, `move`, `delete`, `reload`, `get_info`, `assign_to_node`

**文件系统** (4 子类): `list_dir`, `create_dir`, `delete_dir`, `read_file`, `write_file`, `append_file`, `copy_file`, `move_file`, `read_json`, `write_json`, `find_files`, `grep`, `find_and_replace`

**项目** (2 子类): `get_info`, `get_settings`, `get_features`, `get_export_presets`, `set`, `reset`, `list_category`

**编辑器** (5 子类): `get_info`, `get_main_screen`, `set_main_screen`, `get/set_distraction_free`, `get/set_editor_settings`, `undo`, `redo`, `create_action`, `commit_action`, `toast`, `popup`, `confirm`, `edit_object`, `refresh`, `select_file`, `scan`, `reimport`, `list`, `enable`, `disable`

**调试** (4 子类): `print`, `warning`, `error`, `rich`, `get_fps`, `get_memory`, `get_monitors`, `get_render_info`, `start_profiler`, `stop_profiler`, `get_class_list`, `get_class_info`, `get_class_methods`, `get_class_properties`, `get_class_signals`, `get_inheriters`

**动画** (7 子类): `list`, `play`, `stop`, `pause`, `seek`, `create`, `delete`, `duplicate`, `set_length`, `set_loop`, `add_property_track`, `add_method_track`, `remove_track`, `add_key`, `remove_key`, Tween 支持, AnimationTree, 状态机, 混合空间, 混合树

**材质** (2 子类): `create`, `get_info`, `set_property`, `list_properties`, `assign_to_node`, `duplicate`, `save`, `get_mesh_info`, `list_surfaces`, `create_primitive`

**着色器** (2 子类): `create`, `read`, `write`, `get_info`, `get_uniforms`, `set_default`, `create_material`, `set_shader`, `set_param`, `list_params`

**灯光** (3 子类): `create`, `get_info`, `set_color`, `set_energy`, `set_shadow`, `set_range`, `set_angle`, `set_bake_mode`, `create_environment`, `set_background`, `set_fog`, `set_glow`, `set_ssao`, `set_ssr`, `set_sdfgi`, `set_tonemap`, `create_sky`, `set_procedural`, `set_physical`, `set_panorama`

**粒子** (2 子类): `create`, `set_emitting`, `restart`, `set_amount`, `set_lifetime`, `set_one_shot`, `set_explosiveness`, `set_color`, `set_emission_shape`

**TileMap** (2 子类): `get_info`, `list_sources`, `list_tiles`, `get_cell`, `set_cell`, `erase_cell`, `fill_rect`, `clear_layer`, `get_used_cells`

**几何** (3 子类): CSG 操作, GridMap 操作, MultiMesh 操作

**物理** (4 子类): 物理体创建/配置, 碰撞形状创建, 物理关节约束, 物理查询 (raycast, shape_cast, point_check)

**导航** (1 子类): `get_map_info`, `list_regions`, `list_agents`, `bake_mesh`, `get_path`, `set_agent_target`

**音频** (2 子类): 总线管理 (list, add, remove, set_volume, set_mute, add_effect), 流播放 (create_player, play, stop, set_volume, set_pitch, set_loop)

**UI** (1 子类): Theme 创建/设置 (create, set_color, set_constant, set_font, set_font_size, set_stylebox)

**信号** (1 子类): `list`, `get_info`, `list_connections`, `connect`, `disconnect`, `emit`

**分组** (1 子类): `list`, `add`, `remove`, `is_in`, `get_nodes`, `call_group`, `set_group`

### 6.3 ee0pdt/Godot-MCP (26 工具)

**节点**: `create_node`, `delete_node`, `update_node_property`, `get_node_properties`, `list_nodes`
**脚本**: `create_script`, `edit_script`, `get_script`, `get_script_metadata`, `get_current_script`, `create_script_template`
**场景**: `create_scene`, `save_scene`, `open_scene`, `get_current_scene`, `get_scene_structure`
**项目**: `get_project_info`, `list_project_files`, `get_project_structure`, `get_project_settings`, `list_project_resources`
**编辑器**: `get_editor_state`, `get_selected_node`, `create_resource`
**代码执行**: `execute_editor_script` (任意 GDScript 执行)
**MCP 资源**: 11 个只读资源端点

**特色**: 任意代码执行能力，Expression 类型解析，UndoRedo 集成。

### 6.4 hi-godot/godot-ai (120+ 工具)

**核心**: `session_activate`, `session_manage`, `editor_state`
**场景**: `scene_open`, `scene_save`, `scene_get_hierarchy`, `scene_manage`
**节点**: `node_create`, `node_set_property`, `node_find`, `node_get_properties`, `node_manage`
**脚本**: `script_create`, `script_attach`, `script_patch`, `script_manage`
**项目**: `project_run`, `project_manage`
**编辑器**: `editor_screenshot`, `editor_reload_plugin`, `editor_manage`
**动画**: `animation_create`, `animation_manage` (player, track, tween, state machine, blend)
**材质**: `material_manage` (create, set_param, set_shader_param, apply_preset)
**音频**: `audio_manage` (player_create, play, stop, set_stream)
**粒子**: `particle_manage` (create, set_main, apply_preset)
**相机**: `camera_manage` (create, configure, set_limits_2d, follow_2d, apply_preset)
**信号**: `signal_manage` (list, connect, disconnect)
**输入映射**: `input_map_manage` (list, add_action, remove_action, bind_event)
**运行时**: `game_manage` (get_scene_tree, get_node_info, input_key, input_mouse, input_gamepad)
**Autoload**: `autoload_manage` (list, add, remove)
**文件系统**: `filesystem_manage` (read_text, write_text, reimport, search)
**主题**: `theme_manage` (create, set_color, set_constant, set_font_size, set_stylebox_flat)
**UI**: `ui_manage` (set_anchor_preset, set_text, build_layout, draw_recipe)
**资源**: `resource_manage` (search, load, assign, get_info, create, curve_set_points, environment_create, physics_shape_autofit)
**API 内省**: `api_manage` (get_class - ClassDB 元数据)
**客户端配置**: `client_manage` (status, configure, remove)
**测试**: `test_run`, `test_manage`
**批量操作**: `batch_execute` (原子多命令回滚)
**日志**: `logs_read` (游标增量轮询)

**特色**: 19+ 客户端自动配置，批量原子操作，运行时帧缓冲捕获（通过 debugger bus），工具滚动窗口模式（_manage rollup），deferred loading，自更新机制。

### 6.5 IvanMurzak/Godot-MCP (39 工具)

**Ping**: `ping`
**节点**: `node-find`, `node-create`, `node-modify`, `node-set-parent`, `node-duplicate`, `node-delete`
**场景**: `scene-open`, `scene-save`, `scene-create`, `scene-list-opened`, `scene-get-data`
**资源**: `resource-find`, `resource-get-data`, `resource-modify`, `resource-create`, `resource-move`, `resource-delete`
**文件系统**: `filesystem-list`, `filesystem-reimport`
**脚本**: `script-read`, `script-create`, `script-update`, `script-delete`, `script-attach-to-node`, `script-validate`
**截图**: `screenshot-viewport`, `screenshot-camera`, `screenshot-isolated`
**编辑器**: `editor-application-get-state`, `editor-application-set-state`, `editor-selection-get`, `editor-selection-set`
**控制台**: `console-get-logs`, `console-clear-logs`
**反射**: `reflection-method-find`, `reflection-method-call`
**运行时错误**: `runtime-errors-get`, `runtime-errors-clear`

**特色**: 跨引擎共享 MCP 服务器（Unity/Godot/Unreal），C# 反射调用任意方法，Editor/Runtime 编译分离，自定义工具开发框架，设备认证流程，热重载生存机制。

### 6.6 tomyud1/godot-mcp (42+ 工具)

**文件**: `list_dir`, `read_file`, `search_project`, `create_script`
**场景**: `create_scene`, `read_scene`, `add_node`, `remove_node`, `modify_node_property`, `rename_node`, `move_node`, `attach_script`, `detach_script`, `set_collision_shape`, `set_sprite_texture`, `instance_scene`, `set_mesh`, `set_material`, `get_node_spatial_info`, `measure_node_distance`, `snap_node_to_grid`, `set_node_properties`, `set_node_groups`, `find_nodes_in_group`, `set_resource_property`, `save_resource_to_file`, `get_resource_info`, `list_signal_connections`, `connect_signal`, `disconnect_signal`
**脚本**: `edit_script`, `validate_script`, `create_folder`, `delete_file`, `rename_file`, `list_scripts`
**项目**: `get_project_settings`, `list_settings`, `update_project_settings`, `get_input_map`, `configure_input_map`, `get_collision_layers`, `get_node_properties`, `get_console_log`, `get_errors`, `clear_console_log`, `open_in_godot`, `scene_tree_dump`, `classdb_query`, `rescan_filesystem`, `setup_autoload`, `run_scene`, `stop_scene`, `is_playing`, `get_runtime_status`, `wait`, `take_screenshot`, `send_input`, `query_runtime_node`, `get_runtime_log`
**资产生成**: `generate_2d_asset` (SVG→PNG)
**可视化**: `map_project`, `map_scenes` (力导向图可视化)

**特色**: 双连接模型（编辑器+运行时），SVG 资产生成，浏览器可视化工具，非阻塞 wait，ts/GDScript 对齐测试。

### 6.7 tugcantopaloglu/godot-mcp (149 工具)

基于 Coding-Solo 的 fork，扩展到 149 工具。除原始功能外新增：

**运行时输入** (8): `game_click`, `game_key_press`, `game_mouse_move`, `game_key_hold`, `game_key_release`, `game_scroll`, `game_mouse_drag`, `game_gamepad`, `game_touch`, `game_input_state`, `game_input_action`
**运行时检查** (3): `game_get_ui`, `game_get_scene_tree`, `game_get_node_info`
**运行时代码执行**: `game_eval` (支持 await)
**运行时节点操作** (7): `game_get_property`, `game_set_property`, `game_call_method`, `game_instantiate_scene`, `game_remove_node`, `game_change_scene`, `game_reparent_node`
**运行时信号** (5): `game_connect_signal`, `game_disconnect_signal`, `game_emit_signal`, `game_list_signals`, `game_await_signal`
**运行时动画**: `game_play_animation`, `game_tween_property`
**运行时工具**: `game_pause`, `game_performance`, `game_wait`, `game_get_nodes_in_group`, `game_find_nodes_by_class`
**项目创建**: `create_project`, `manage_autoloads`, `manage_input_map`, `manage_export_presets`
**高级运行时** (24): 相机控制, 射线检测, 音频, 节点生成, Shader 参数, 导航, TileMap, 碰撞, 环境后处理, 分组, 定时器, 粒子, 动画创建, 状态序列化, 物理体, 关节, 骨骼, 主题, 视口, 调试绘制
**3D 渲染** (13): CSG, MultiMesh, 程序化网格, 灯光, MeshInstance, GridMap, 3D 效果, GI, Path3D, Sky, 相机属性, Navigation3D, Physics3D
**2D 系统** (7): Canvas, Canvas 绘制, 2D 灯光, 视差, Shape2D, Path2D, Physics2D
**UI 控件** (8): UI Control, Text, Popup, Tree, ItemList, Tabs, Menu, Range
**网络** (4): HTTP 请求, WebSocket, Multiplayer, RPC
**系统** (6): Script, Window, OS Info, TimeScale, ProcessMode, WorldSettings
**导出**: `export_project`

**特色**: 最全面的运行时操控，2D/3D 自动检测，全 Godot 类型系统覆盖，重入保护。

### 6.8 youichi-uda/godot-mcp-pro (175 工具)

工具数量最多，覆盖 25 个类别。除与上述项目重叠的能力外，独特功能包括：

**运行时高级** (19): 帧捕获（多帧截图）、帧录制（保存到磁盘）、属性监控（时序数据）、输入录制/回放、UI 元素查找、按钮文本点击、节点等待、空间邻近查询、AI 导航（pathfinding）、信号实时监控
**AnimationTree** (8): 状态机状态/过渡管理、混合树节点配置
**批处理/重构** (8): 按类型/信号/引用查找、批量属性设置、跨场景操作、依赖分析
**分析** (4): 场景复杂度分析、信号流分析、未使用资源检测、循环依赖检测
**测试/QA** (6): 测试场景运行、断言、压力测试、截图比较
**Android 部署** (3): 设备列举、预设信息、一键部署
**导出** (3): 导出预设管理、项目导出
**Shader** (6): Shader CRUD、材质分配、参数管理
**物理** (6): 物理体设置、碰撞、层管理、射线
**粒子** (5): GPU 粒子 2D/3D、8 种预设（火/烟/火花/雨/雪/爆炸/魔法/尘土）
**导航** (5): NavigationRegion/Agent、网格烘焙、层管理
**音频** (6): 总线/效果/播放器管理
**3D 场景** (6): 网格、相机、灯光、环境、GridMap、材质
**输入** (7): 键盘/鼠标/动作模拟、序列执行
**代码执行**: 编辑器脚本执行（带安全守卫）

**特色**: 4 种工具模式（Full/3D/Lite/Minimal），文件冲突安全系统，崩溃恢复，多客户端同时支持（10 端口），独立于编辑器语言的 UI 交互（通过主题图标匹配）。

### 6.9 yurineko73/Godot-MCP-Native (155 工具)

**节点** (20): 基础 CRUD + 信号/分组/锚点/批量操作/场景审计
**脚本** (14): 基础 CRUD + 分析/验证/搜索/符号索引/定义查找/引用查找/符号重命名
**场景** (8): 基础 CRUD + 结构/列举/关闭标签
**编辑器** (16): 运行/停止/截图/信号/导出/选择/检查器
**调试** (70): 日志/断点/栈帧/变量/性能分析器/运行时探针/动画/音频/Shader/TileMap 运行时控制/DAP 风格事件
**项目** (26): 信息/设置/资源/输入映射/全局类/测试运行器/诊断/UID 修复/资源依赖/循环依赖/脚本检测/项目健康审计
**资源**: 7 个 MCP 资源端点

**特色**: 纯 GDScript 零依赖，核心/补充工具分类（30 核心+125 补充），EngineDebugger 运行时探针，Vibe Coding 安全策略，MCP 协议版本协商，Bearer Token 认证，工具调用日志审计。

---

## 7. 操控能力矩阵汇总

下表标记每个功能域在各项目中的覆盖情况（✅ = 完整支持，⚡ = 部分支持，❌ = 不支持）：

| 功能域 | Coding-Solo | DaxianLee | ee0pdt | hi-godot | IvanMurzak | tomyud1 | tugcantopaloglu | youichi-uda | yurineko73 |
|--------|:-----------:|:---------:|:------:|:--------:|:----------:|:-------:|:---------------:|:-----------:|:----------:|
| 场景管理 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 节点操作 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 脚本管理 | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 项目信息 | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ |
| 文件系统 | ❌ | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| 信号管理 | ❌ | ✅ | ❌ | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ |
| 编辑器控制 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 资源管理 | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 动画系统 | ❌ | ✅ | ❌ | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ |
| 材质/Shader | ❌ | ✅ | ❌ | ✅ | ❌ | ✅ | ✅ | ✅ | ❌ |
| 物理系统 | ❌ | ✅ | ❌ | ✅ | ❌ | ✅ | ✅ | ✅ | ❌ |
| 粒子系统 | ❌ | ✅ | ❌ | ✅ | ❌ | ❌ | ✅ | ✅ | ❌ |
| 音频系统 | ❌ | ✅ | ❌ | ✅ | ❌ | ✅ | ✅ | ✅ | ❌ |
| 灯光/环境 | ❌ | ✅ | ❌ | ✅ | ❌ | ❌ | ✅ | ✅ | ❌ |
| 3D 网格/几何 | ❌ | ✅ | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ | ❌ |
| UI/主题 | ❌ | ✅ | ❌ | ✅ | ❌ | ✅ | ✅ | ✅ | ❌ |
| 导航系统 | ❌ | ✅ | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ | ❌ |
| TileMap | ❌ | ✅ | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ | ✅ |
| 输入模拟 | ❌ | ❌ | ❌ | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ |
| 运行时调试 | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 代码执行 | ❌ | ❌ | ✅ | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ |
| ClassDB 内省 | ❌ | ✅ | ❌ | ✅ | ✅ | ✅ | ❌ | ❌ | ✅ |
| 输入映射 | ❌ | ❌ | ❌ | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ |
| 网络 | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ | ❌ | ❌ |
| 导出/构建 | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ | ✅ |

---

## 8. 架构模式与设计决策分析

### 8.1 三种主流架构模式

**模式 A: Headless CLI（无插件）**
- 代表: Coding-Solo, tugcantopaloglu
- 优点: 零安装，无插件依赖
- 缺点: 每次操作启动 Godot 开销 (~1-2s)，无法访问编辑器实时状态
- 适用: 文件级操作（场景创建/编辑），不适合实时交互

**模式 B: 插件内置 MCP Server（纯 GDScript）**
- 代表: DaxianLee, yurineko73
- 优点: 零外部依赖，直接 API 访问，单进程
- 缺点: GDScript 的 HTTP 实现较脆弱，缺少成熟 HTTP 库支持
- 适用: 追求零安装体验的场景

**模式 C: 外部 MCP Server + 插件（双进程）**
- 代表: ee0pdt, hi-godot, tomyud1, youichi-uda, IvanMurzak
- 优点: 成熟语言的 MCP SDK 支持，更可靠的网络实现
- 缺点: 需要额外运行 Node.js/Python/.NET 进程
- 适用: 生产级工具

### 8.2 运行时操控的四种方案

| 方案 | 项目 | 机制 | 优点 | 缺点 |
|------|------|------|------|------|
| **Autoload TCP** | tugcantopaloglu | 注入 TCP 服务器 autoload | 简单直接 | 需要注入/清理 |
| **文件 IPC** | youichi-uda | 编辑器写文件，游戏轮询 | 跨平台可靠 | 延迟较高 |
| **Debugger Bus** | yurineko73, hi-godot | EngineDebugger 消息通道 | 原生支持，无需注入 | 协议复杂 |
| **SignalR 同连接** | IvanMurzak | 同一 SignalR 连接 | 统一架构 | 需要 C# 运行时 |

### 8.3 关键设计决策

**UndoRedo 集成**: 6/9 项目实现了 EditorUndoRedoManager 集成，这是编辑器操控的"必备特性"。

**类型转换**: 所有项目都实现了 JSON ↔ Godot 类型的双向转换（Vector2/3, Color, Quaternion, Basis, Transform2D/3D, AABB, Rect2 等）。这是最大的工程量之一。

**工具数量管理**: 当工具数量超过 ~40 时，部分 AI 客户端会拒绝。解决方案包括：
- hi-godot: `_manage` rollup 模式（18 个命名工具 + 22 个域滚动工具）
- yurineko73: 核心/补充分类（30 核心默认启用）
- youichi-uda: 4 种模式（Full/3D/Lite/Minimal）

**多客户端支持**: youichi-uda 支持 10 个端口同时连接，hi-godot 支持多编辑器会话路由。

---

## 9. gdcli 可借鉴的能力清单

### 9.1 当前 gdcli 能力现状

gdcli 通过 LSP 和 HTTP (gdapi addon) 两种协议与 Godot 通讯。目前已实现的能力相对有限。

### 9.2 高优先级借鉴（基础能力补全）

| 能力 | 参考项目 | 理由 |
|------|----------|------|
| **节点 CRUD** (创建/删除/复制/移动/属性设置) | 所有项目 | 这是所有操控的基础 |
| **场景管理** (创建/打开/保存/列举) | 所有项目 | 场景是 Godot 的核心概念 |
| **脚本管理** (创建/读取/编辑/附加) | 所有项目 | 脚本是游戏逻辑载体 |
| **信号管理** (连接/断开/列举) | DaxianLee, hi-godot, tomyud1 | 信号是 Godot 的核心通讯机制 |
| **编辑器操作** (运行/停止/截图) | 所有项目 | 验证和调试的基础 |

### 9.3 中优先级借鉴（领域扩展）

| 能力 | 参考项目 | 理由 |
|------|----------|------|
| **资源管理** (创建/加载/修改) | IvanMurzak, hi-godot | 材质、纹理等资源管理 |
| **文件系统操作** (读写/搜索) | DaxianLee, tugcantopaloglu | 项目文件管理 |
| **项目设置管理** | tomyud1, hi-godot | 配置修改 |
| **ClassDB 内省** | DaxianLee, IvanMurzak, yurineko73 | AI 理解可用 API |
| **输入映射管理** | hi-godot, tomyud1 | 输入系统配置 |
| **动画管理** | DaxianLee, youichi-uda | 常见游戏功能 |
| **TileMap 操作** | DaxianLee, youichi-uda | 2D 游戏核心功能 |

### 9.4 低优先级借鉴（高级/利基功能）

| 能力 | 参考项目 | 理由 |
|------|----------|------|
| **运行时操控** (输入模拟/属性查看) | tugcantopaloglu, tomyud1, youichi-uda | 高级调试和测试 |
| **物理系统操作** | DaxianLee, youichi-uda | 3D/2D 物理配置 |
| **材质/Shader 管理** | DaxianLee, youichi-uda | 视觉效果开发 |
| **粒子系统** | DaxianLee, youichi-uda | 特效开发 |
| **音频系统** | DaxianLee, youichi-uda | 音频开发 |
| **导航系统** | DaxianLee, youichi-uda | 寻路功能 |
| **灯光/环境** | DaxianLee, youichi-uda | 3D 场景美化 |
| **3D 网格/几何** | tugcantopaloglu, youichi-uda | 3D 建模辅助 |
| **UI/主题** | DaxianLee, youichi-uda | UI 开发 |
| **网络功能** | tugcantopaloglu | 多人游戏开发 |
| **代码执行** | ee0pdt, tugcantopaloglu, yurineko73 | 最大灵活性 |
| **批量操作** | hi-godot, youichi-uda | 效率提升 |
| **项目分析/诊断** | yurineko73, youichi-uda | 代码质量 |
| **导出/构建** | tugcantopaloglu, youichi-uda, yurineko73 | 发布流程 |

### 9.5 架构层面借鉴

| 借鉴点 | 参考项目 | 说明 |
|--------|----------|------|
| **UndoRedo 集成** | 所有 GDScript 插件项目 | 确保 AI 修改可撤销 |
| **类型转换层** | 所有项目 | JSON ↔ Godot 类型的统一转换 |
| **安全机制** | Coding-Solo, youichi-uda, yurineko73 | 路径验证、文件冲突检测、工具开关 |
| **工具分类/模式** | yurineko73, youichi-uda | 核心/补充分类，适应不同客户端限制 |
| **运行时探针** | yurineko73 (EngineDebugger) | 通过 Godot 调试器协议实现运行时操控 |
| **客户端自动配置** | hi-godot, DaxianLee | 一键配置各种 AI 客户端 |

---

## 10. 附录：各项目原始数据

### 10.1 项目仓库信息

| 项目 | 路径 | GitHub 仓库 | License |
|------|------|-------------|---------|
| Coding-Solo | `D:\AI\godot-ws\godot-tools\Coding-Solo_godot-mcp` | Coding-Solo/godot-mcp | MIT |
| DaxianLee | `D:\AI\godot-ws\godot-tools\DaxianLee_godot-mcp` | DaxianLee/godot-mcp | Non-Commercial |
| ee0pdt | `D:\AI\godot-ws\godot-tools\ee0pdt_Godot-MCP` | ee0pdt/Godot-MCP | MIT |
| hi-godot | `D:\AI\godot-ws\godot-tools\hi-godot_godot-ai` | hi-godot/godot-ai | MIT |
| IvanMurzak | `D:\AI\godot-ws\godot-tools\IvanMurzak_Godot-MCP` | IvanMurzak/Godot-MCP | Apache-2.0 |
| tomyud1 | `D:\AI\godot-ws\godot-tools\tomyud1_godot-mcp` | tomyud1/godot-mcp | MIT |
| tugcantopaloglu | `D:\AI\godot-ws\godot-tools\tugcantopaloglu_godot-mcp` | tugcantopaloglu/godot-mcp | MIT |
| youichi-uda | `D:\AI\godot-ws\godot-tools\youichi-uda_godot-mcp-pro` | youichi-uda/godot-mcp-pro | MIT (addon) / Proprietary (server) |
| yurineko73 | `D:\AI\godot-ws\godot-tools\yurineko73_Godot-MCP-Native` | yurineko73/Godot-MCP-Native | MIT |

### 10.2 版本与 Godot 兼容性

| 项目 | 版本 | 最低 Godot 版本 |
|------|------|-----------------|
| Coding-Solo | 0.1.1 | 4.x |
| DaxianLee | 1.0.0 | 4.x |
| ee0pdt | 1.0.0 | 4.4 |
| hi-godot | 2.8.0 | 4.3 (推荐 4.7+) |
| IvanMurzak | 0.13.3 | 4.3 |
| tomyud1 | 0.5.0 | 4.2+ |
| tugcantopaloglu | 1.0.0 | 4.4+ |
| youichi-uda | 1.15.0 | 4.4 (推荐 4.6) |
| yurineko73 | 1.0.7-pre1 | 4.5+ (推荐 4.6) |

### 10.3 代码规模估算

| 项目 | TS/Python/C# (Server) | GDScript (Plugin) | 总计 |
|------|----------------------|-------------------|------|
| Coding-Solo | ~2,250 行 | ~1,186 行 | ~3,436 行 |
| DaxianLee | 0 | ~10,000+ 行 | ~10,000+ 行 |
| ee0pdt | ~2,000 行 | ~3,000 行 | ~5,000 行 |
| hi-godot | ~5,000+ 行 | ~10,000+ 行 | ~15,000+ 行 |
| IvanMurzak | ~15,000+ 行 | 0 (C# ~20,000+ 行) | ~35,000+ 行 |
| tomyud1 | ~7,000 行 | ~6,200 行 | ~13,200 行 |
| tugcantopaloglu | ~7,000 行 | ~6,200 行 | ~13,200 行 |
| youichi-uda | 未开源 | ~15,000+ 行 | ~15,000+ 行 |
| yurineko73 | 0 | ~15,000+ 行 | ~15,000+ 行 |

---

## 总结

Godot 操控工具生态已经相当成熟，9 个项目覆盖了从基础场景编辑到高级运行时调试的完整能力谱系。核心发现：

1. **通讯协议趋同**: MCP (JSON-RPC 2.0) 已成为事实标准，传输层以 WebSocket 和 stdio 为主
2. **GDScript 是 Godot 端的通用语言**: 所有项目都在 Godot 端使用 GDScript（IvanMurzak 用 C# 是例外）
3. **UndoRedo 和类型转换是必备基础设施**: 这是每个项目都必须实现的核心工程
4. **运行时操控是差异化竞争点**: 输入模拟、帧捕获、属性监控等运行时能力正在成为标配
5. **工具数量管理是实际问题**: AI 客户端的工具数限制要求精心设计工具表面

对于 gdcli 项目，建议优先补全**节点/场景/脚本/信号**四大基础能力，然后逐步扩展到动画、TileMap、资源管理等游戏开发核心域，最后考虑运行时操控和高级调试功能。
