# 外部 godot-mcp 能力对比（抽样复核）

日期：2026-10-03
目的：原始需求曾要求「完整实现 `D:\AI\godot-ws\godot-mcp` 的功能」——该参考目录在本机已不存在。本报告用 `D:/AI/godot-ws/godot-tools/` 下的同类仓库做**抽样复核**，给出能力域级差距矩阵，作为「外部功能对等」这一项的收口证据。

## 抽样与口径

- 目录中共 9 个仓库：tugcantopaloglu、yurineko73、tomyud1、youichi-uda、DaxianLee、hi-godot、ee0pdt、IvanMurzak、Coding-Solo。
- 抽样 3 个（其余仅作基线）：
  - **youichi-uda_godot-mcp-pro**：命令数最多（25 个命令类 / 174 个方法，覆盖 3D、批量、测试、运行时录制）。
  - **IvanMurzak_Godot-MCP**：与 gdcli 最同构（39 工具 / 11 family，含 runtime-errors、reflection、截图）。
  - **DaxianLee_godot-mcp**：覆盖面广，含 lighting/particles/geometry/editor-UI，能照出 gdcli 弱项。
- gdcli 侧以**真实注册路由**为准：193 条 = 189 个文件路由 + 4 个内置（`gdapi/health/ping`、`gdapi/routes`、`command/list`、`command/doc`）；里程碑清单 M3/M4/M5/M6 = 35/51/25/7（`tests/e2e/route_manifests.py`）。
- 对比按**能力域**归并，不逐工具名对齐（gdcli 明确不复刻外部命名/参数）。

## 能力域矩阵

| 能力域 | 外部代表（有据） | gdcli 路由 | 判定 |
|---|---|---|---|
| 通信/健康 | `ping`（IvanMurzak README:139） | `gdapi/health/ping`、`gdapi/routes`、`command/list`、`command/doc` | 等价 |
| 项目信息/运行控制 | run/stop_project、version；project_info | `project/info`、`project/run`、`project/stop`、`godot/version` | 等价 |
| 列磁盘项目/启动编辑器 | list_projects、launch_editor（Coding-Solo index.ts:671/730） | 路由与 CLI 子命令均无（`main.rs` 只有 `lsp`/`status`/`install`/`exec`） | 部分 |
| 场景 | scene 命令 10 条（youichi:9-20） | `scene/{create,open,save,close,list_open,current,current/save,tree,add_node,load_sprite,export_mesh_library}` | 部分（缺 add_scene_instance、delete_scene） |
| 节点/属性/分组 | node 17（youichi:9-27）、12（DaxianLee） | `node/*` 10、`node/property/*` 5、`node/group/*` 4 | 部分（缺 set_meta 元数据、编辑期任意方法调用） |
| 信号 | connect/disconnect、watch_signals、find_signal_connections | `node/signal/*` 4、`runtime/signal/*` 4、`runtime/assert/signal_received` | 等价（管理面；全项目信号流审计缺） |
| 脚本 | script 7（youichi:6-14）、4（DaxianLee） | `script/{create,read,write,patch,validate,open,attach,detach,current}`；删除走 `filesystem/batch/delete` | 等价 |
| 文件系统 | tree/search/search_in_files、filesystem 4 | `filesystem/{list,read,write,search,grep,reimport}` + `batch/{delete,replace,recover}` | 等价 |
| 资源 | resource 4（youichi）、resource-modify（IvanMurzak） | `resource/{search,info,create,assign,delete,move,reimport,deps}` | 部分（无通用资源属性写入、纹理专用与预览） |
| 编辑器 UI | editor 13（youichi:6-20）、7（DaxianLee） | `editor/selection/{get,set}`、`editor/main_screen/set`、`console/output`、`gdapi/{loglevel,audit/*}` | 部分（缺 undo/redo 触发、通知、inspector/dock、插件管理、编辑器设置/相机/截图） |
| 运行时 | runtime 19（youichi:9-29）、runtime-errors（IvanMurzak:147） | `runtime/status`、`scene/tree`、`node/*` 10、`log/*` 2、`assert/*` 4、`debug/*` 4、`eval` | 部分（缺录制回放、跨帧属性监视、UI 查找/点击、导航辅助、get_autoload） |
| 输入模拟 | input 5（youichi:8-14） | `runtime/input/{key,mouse,gamepad,touch,action,sequence}` | 等价 |
| 截图/视觉 | screenshot×3（IvanMurzak:144）、编辑器/游戏截图与对比 | `runtime/screenshot/{viewport,camera,frames}` | 部分（无编辑器视口、孤立节点渲染、差异对比） |
| 动画/动画树 | animation 6 + tree 8（youichi）、tween（DaxianLee） | `animation/*` 8、`animation_tree/{state/add,transition/add,blend/set}` | 部分（缺 state/transition 删除、blend tree 节点、tween） |
| TileMap | tilemap 6（youichi）、2（DaxianLee） | `tilemap/{info,cell/get,cell/set,rect/fill,layer/clear,used_cells}` | 等价 |
| 3D 场景搭建 | scene_3d 6（youichi:9-16）、lighting+geometry（DaxianLee） | 仅 `scene/export_mesh_library` | **缺失** |
| 粒子 | particle 5（youichi:6-12）、2（DaxianLee） | 无 | **缺失** |
| 物理/导航（2D） | physics 6、navigation 5（youichi） | `physics/*` 5、`navigation/*` 4（3D 已批准排除） | 等价（2D） |
| 音频 | audio 6（youichi）、2（DaxianLee） | `audio/{bus/list,bus/add,bus/remove,player/create,play,stop}` | 部分（缺 bus 属性与 effect） |
| 材质/Shader | shader 6、material 2+shader 2 | `material/*` 6、`shader/*` 5 | 等价 |
| UI/Theme | theme 7（youichi）、ui 2（DaxianLee） | `theme/*` 5、`ui/{control/set_anchor,text/set,layout/build}` | 部分（缺 theme 读取） |
| 项目设置/InputMap/Autoload/ClassDB/UID | project 10 + input_map 2；class_db；uid | `project/settings` 4、`input_map` 6、`autoload` 3、`classdb` 6、`uid/{get,repair,update_all}` | 等价 |
| 诊断/代码分析 | analysis 6 + profiling 2 | `diagnostics/*` 4、`runtime/debug/{performance,monitors}` | 部分（缺信号流、复杂度、引用、项目统计） |
| 批量/跨场景重构 | batch 7–8（youichi:9-17） | `filesystem/batch/*`（文件级）、`node/find`（单场景） | **缺失**（跨场景节点/属性） |
| 测试/QA | test 6（youichi:9-15） | `runtime/assert/*` 4 | 部分（无场景测试/压力/报告） |
| 导出 | export 3 | `export/{presets,run}` | 等价（桌面；Android 明确非目标） |
| 进程/网络/受限求值 | 外部无同类 | `process/run`、`network/http_request`、`editor/eval`、`runtime/eval` | **gdcli 独有** |
| 反射/任意方法调用 | reflection find/call（IvanMurzak:146） | `editor/eval`（受限）+ `runtime/node/call` | 部分（C# 专属能力） |
| 运行时错误捕获 | runtime-errors get/clear | `runtime/log/read`、`runtime/debug/errors`（空列表为已批准受限语义） | 等价（受限语义） |

## 缺失清单（按重要性，附外部证据）

1. **3D 场景搭建**：lighting/environment/sky/camera3d/gridmap/CSG/MultiMesh（youichi `scene_3d_commands.gd:9-16`；DaxianLee `lighting_tools.gd:11/94/161`、`geometry_tools.gd:11/97/175`）。
2. **粒子系统**（youichi `particle_commands.gd:6-12`；DaxianLee `particle_tools.gd:11/102`）。
3. **跨场景批量重构**：batch_set_property、find_nodes_by_type、find_node_references、get_scene_dependencies（youichi `batch_commands.gd:9-17`）。
4. **运行时录制/回放与交互**：start/stop/replay_recording、monitor_properties、find_ui_elements、click_button_by_text、wait_for_node（youichi `runtime_commands.gd:9-29`）。
5. **编辑器 UI 控制面**：undo/redo 触发、通知、inspector/dock、插件启用与重载、编辑器设置/相机/截图（youichi `editor_commands.gd:6-20`；DaxianLee `editor_tools.gd:11-307`）。
6. **代码分析扩展**：信号流分析、场景复杂度、脚本引用、项目统计（youichi `analysis_commands.gd:6-13`）。
7. **测试/QA 框架化**：run_test_scenario、assert_screen_text、run_stress_test、get_test_report（youichi `test_commands.gd:9-15`）。
8. **资源通用属性写入/纹理预览**（IvanMurzak resource-modify；youichi edit_resource/get_resource_preview）。
9. **音频 bus 属性与 effect**（youichi `audio_commands.gd:6-13`）。
10. **动画树删除与 blend tree 构建、tween**（youichi `animation_tree_commands.gd:6-15`；DaxianLee `animation_tools.gd:173`）。
11. **场景实例化 add_scene_instance / delete_scene**（youichi `scene_commands.gd:9-20`）。
12. **反射任意方法调用**（IvanMurzak reflection，C# 专属）。

## 口径与不确定项

- 外部工具合计（抽样三仓）**287 条**：youichi 174 个方法（`command_router.gd:12-54`；`llms.txt` 宣传 162，存在营销口径差）、IvanMurzak 39（README:137）、DaxianLee 74（`mcp_server.gd:200-243` + `tools/*.gd`）。
- 判定统计：**等价 13 域、部分 11 域、缺失 3 域、gdcli 独有 1 域**（共 27 域）。
- 不确定项：youichi 副本缺少 `server/` 目录，工具名以 addon 命令表为准；DaxianLee 计数按代码注册（README 未列全）。
- 已批准的非目标不重复计入差距：MCP 1:1 兼容、3D 物理/导航、Android 平台、断点详细回溯（见 `docs/superpowers/specs/2026-10-03-gdcli-branch-goal-and-scope.md:20-38`）。

## 结论

gdcli 在**编辑器/运行时操控的主干能力域上与外部项目大体对齐**（13 域等价、11 域部分），差距集中在**3D 场景搭建、粒子、跨场景批量重构**三个缺失域，以及运行时录制回放、编辑器 UI 控制面、代码分析扩展等增强项。这些都不属于本分支已批准的目标范围；如需补齐，应按新需求逐域立项，而不是作为当前收口的遗留缺陷。
