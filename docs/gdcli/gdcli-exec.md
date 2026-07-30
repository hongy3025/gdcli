# gdcli exec — 调用 Godot 编辑器命令

通过 gdapi HTTP 插件与运行中的 Godot 编辑器通信。需要编辑器运行中且 gdapi 插件已启用。

```bash
gdcli exec <command> [--data <json>] [--timeout <secs>] --project <path>
```

| 选项 | 默认 | 说明 |
|------|------|------|
| `--data <json>` | `{}` | 请求数据：字面 JSON、`@file`（从文件读取）、`-`（从 stdin 读取） |
| `--timeout <secs>` | 30 | 请求超时秒数 |

## 特殊命令

`command/list` 和 `command/doc` 使用位置参数，不接受 `--data`：

```bash
gdcli exec command/list              # 列出所有可用路由
gdcli exec command/doc scene/save    # 查看路由的完整文档
```

## 在线文档查询

gdapi 路由自带自描述文档，无需翻阅静态手册：

```bash
# 查看所有路由
gdcli exec command/list --project .

# 查看某个路由的详细文档（参数、返回值、示例）
gdcli exec command/doc scene/create --project .
gdcli exec command/doc node/property/set --project .
gdcli exec command/doc runtime/input/key --project .
```

`command/doc` 输出包含：功能描述、参数名/类型/必填/说明、返回值字段、调用示例。

## 输出格式

| 条件 | 格式 |
|------|------|
| 默认 | TOON（人类可读键值对/表格/树状列表） |
| `--json` | 原始 JSON（脚本友好） |
| `command/list` | clap 风格（命令名 + 摘要） |
| `command/doc` | clap 风格（参数/返回值/示例） |

## 退出码

| 码 | 含义 |
|----|------|
| 0 | 成功（2xx 响应） |
| 1 | 服务器错误（5xx 响应） |
| 2 | 客户端错误（4xx 响应或参数错误） |
| 3 | 网络错误、超时或元数据缺失 |

## 全路由一览表

### gdapi（插件系统）

| 路由 | 说明 |
|------|------|
| gdapi/health/pathcheck | 校验并规范化项目路径 |
| gdapi/audit/list | 读取 gdapi 审计日志 |
| gdapi/audit/clear | 清空 gdapi 审计日志 |
| gdapi/loglevel | 查询或设置全局日志级别 |

### godot（引擎信息）

| 路由 | 说明 |
|------|------|
| godot/version | 获取 Godot 引擎版本详细信息 |

### scene（场景操作）

| 路由 | 说明 |
|------|------|
| scene/create | 创建新 Godot 场景文件 |
| scene/open | 在编辑器中打开 res:// 路径场景 |
| scene/close | 关闭当前或指定场景 |
| scene/save | 保存 Godot 场景文件 |
| scene/current | 返回当前编辑场景信息 |
| scene/current/save | 保存当前编辑场景 |
| scene/tree | 返回场景节点树 |
| scene/list_open | 列出编辑器当前打开的场景路径 |
| scene/add_node | 向场景中添加新节点 |
| scene/load_sprite | 为精灵节点加载纹理 |
| scene/export_mesh_library | 从场景导出 MeshLibrary 资源 |

### node（节点操作）

| 路由 | 说明 |
|------|------|
| node/create | 在指定父节点下创建节点 |
| node/delete | 删除节点并接 UndoRedo |
| node/duplicate | 复制节点及子结构并接 UndoRedo |
| node/rename | 重命名节点接 UndoRedo |
| node/reparent | 把节点挂接到新父节点接 UndoRedo |
| node/move | 调整 sibling index 接 UndoRedo |
| node/get | 按 NodePath 读取节点摘要 |
| node/set | 批量原子设置节点属性接 UndoRedo |
| node/list | 列出节点直接子节点 |
| node/select | 选中一个或多个节点 |
| node/property/get | 读取节点属性，Variant 编码为 JSON |
| node/property/set | 设置节点属性接 UndoRedo |
| node/property/list | 列出节点的属性 schema |
| node/property/reset | 重置属性为类默认值接 UndoRedo |
| node/property/revert | 还原节点属性到默认值 |
| node/group/add | 节点加入 group |
| node/group/remove | 节点退出 group |
| node/group/list | 列出节点所属的所有 group |
| node/group/nodes | 列出属于给定 group 的当前编辑场景节点 |
| node/signal/connect | 连接节点信号到目标方法 |
| node/signal/disconnect | 断开节点信号与目标方法的连接 |
| node/signal/list | 列出节点的信号和已连接信号 |
| node/signal/emit | 在编辑器中触发节点信号（不可撤销） |

### script（脚本操作）

| 路由 | 说明 |
|------|------|
| script/create | 创建 .gd 脚本文件 |
| script/read | 读取 .gd 脚本文件内容 |
| script/write | 覆盖写入 .gd 脚本文件 |
| script/patch | 替换脚本中 [start_line, end_line] 行区间 |
| script/validate | 校验 .gd 脚本语法 |
| script/open | 把 .gd 脚本加载到 Script Editor |
| script/attach | 挂接脚本到节点 |
| script/detach | 卸下节点的脚本 |
| script/current | 读取 Script Editor 当前编辑的脚本路径 |

### resource（资源操作）

| 路由 | 说明 |
|------|------|
| resource/create | 创建并保存 Resource 子类 |
| resource/search | 通过 EditorFileSystem 搜索资源 |
| resource/info | 读取资源元数据 |
| resource/deps | 读取资源的依赖列表 |
| resource/move | 在编辑器文件系统中移动资源 |
| resource/delete | 删除资源文件 |
| resource/assign | 将 Resource 赋给节点的属性（UndoRedo） |
| resource/reimport | 重新导入一组资源 |

### project（项目操作）

| 路由 | 说明 |
|------|------|
| project/info | 获取当前 Godot 项目基本信息 |
| project/run | 运行 Godot 场景 |
| project/stop | 停止当前正在运行的场景 |
| project/settings/list | 列出项目设置 |
| project/settings/get | 读取项目设置 |
| project/settings/set | 写入项目设置 |
| project/settings/reset | 删除项目设置 |
| project/input_map/list | 列出输入动作 |
| project/input_map/bind | 绑定输入事件 |
| project/input_map/unbind | 解除输入事件 |
| project/input_map/action/add | 添加输入动作 |
| project/input_map/action/remove | 删除输入动作 |
| project/autoload/list | 列出自动加载 |
| project/autoload/add | 添加自动加载 |
| project/autoload/remove | 删除自动加载 |

### animation（动画）

| 路由 | 说明 |
|------|------|
| animation/create | 创建动画 |
| animation/delete | 删除动画 |
| animation/play | 播放动画 |
| animation/stop | 停止动画 |
| animation/key/add | 添加动画 key |
| animation/key/remove | 删除动画 key |
| animation/track/add | 添加动画 value track |
| animation/track/remove | 删除动画 track |

### animation_tree（动画树）

| 路由 | 说明 |
|------|------|
| animation_tree/blend/set | 设置 AnimationTree blend |
| animation_tree/state/add | 添加 AnimationTree state |
| animation_tree/transition/add | 添加 AnimationTree transition |

### audio（音频）

| 路由 | 说明 |
|------|------|
| audio/play | 播放音频 |
| audio/stop | 停止音频 |
| audio/bus/add | 添加音频总线 |
| audio/bus/list | 列出音频总线 |
| audio/bus/remove | 删除音频总线 |
| audio/player/create | 创建音频播放器 |

### classdb（ClassDB 查询）

| 路由 | 说明 |
|------|------|
| classdb/classes | 列出 Godot ClassDB 类 |
| classdb/class | 查询 ClassDB 类详情 |
| classdb/methods | 查询 ClassDB 方法 |
| classdb/properties | 查询 ClassDB 属性 |
| classdb/signals | 查询 ClassDB 信号 |
| classdb/inheriters | 查询 ClassDB 派生类 |

### console（控制台）

| 路由 | 说明 |
|------|------|
| console/output | 读取编辑器控制台日志 |

### editor（编辑器）

| 路由 | 说明 |
|------|------|
| editor/eval | 执行受限的无副作用编辑器表达式 |
| editor/selection/get | 返回编辑器当前选中的节点 |
| editor/selection/set | 设置编辑器 selection |
| editor/main_screen/get | 获取当前主屏幕 |
| editor/main_screen/set | 切换 Godot 编辑器主面板 |

### export（导出）

| 路由 | 说明 |
|------|------|
| export/run | 执行受控项目导出 |
| export/presets | 发现导出预设 |
| export/android/devices | 列出 Android 设备 |
| export/android/deploy | 部署并启动单个 Android 设备 |
| export/android/deploy_many | 确认后的多设备 Android 部署 |

### filesystem（文件系统）

| 路由 | 说明 |
|------|------|
| filesystem/read | 读取文件文本内容 |
| filesystem/write | 写入文本文件（非脚本资源） |
| filesystem/search | 按 glob 模式查找项目文件 |
| filesystem/list | 列出项目目录 |
| filesystem/grep | 在 root + glob 范围内搜索 pattern |
| filesystem/reimport | 重新导入一组项目资源 |
| filesystem/batch/delete | 可恢复的批量删除 |
| filesystem/batch/recover | 恢复批量删除操作 |
| filesystem/batch/replace | 可验证计划的批量文本替换 |

### material（材质）

| 路由 | 说明 |
|------|------|
| material/create | 创建并赋值受支持的材质 |
| material/assign | 通过 UndoRedo 赋值项目材质 |
| material/set | 设置受支持材质属性 |
| material/info | 查询节点材质 |
| material/save | 保存节点材质到项目资源 |
| material/duplicate | 复制材质到新的项目资源 |

### navigation（导航）

| 路由 | 说明 |
|------|------|
| navigation/region/list | 列出 2D 导航区域 |
| navigation/path/get | 查询 2D 导航路径 |
| navigation/mesh/bake | 烘焙并保存 2D 导航网格 |
| navigation/agent/target | 设置运行期 2D 导航 agent 目标 |

### network（网络）

| 路由 | 说明 |
|------|------|
| network/http_request | 策略约束的 HTTP 请求 |

### physics（物理）

| 路由 | 说明 |
|------|------|
| physics/raycast | 执行 2D 物理射线检测 |
| physics/shape/create | 创建 2D 碰撞形状 |
| physics/layer/set | 设置 2D 碰撞层 |
| physics/joint/create | 创建 2D 物理关节 |
| physics/body/create | 创建 2D 物理体 |

### process（进程）

| 路由 | 说明 |
|------|------|
| process/run | 执行无 shell 的受限外部进程 |

### runtime（运行时）

| 路由 | 说明 |
|------|------|
| runtime/status | 查询运行期 broker 状态 |
| runtime/eval | 执行受限的运行时表达式 |
| runtime/node/call | 调用运行期节点方法（allowlist） |
| runtime/node/create | 创建运行期节点 |
| runtime/node/get | 读取运行期节点属性 |
| runtime/node/info | 查询运行期节点的类型和公开属性 |
| runtime/node/set | 设置运行期节点属性 |
| runtime/node/remove | 删除运行期节点（异步 queue_free） |
| runtime/node/rename | 重命名运行期节点 |
| runtime/node/reparent | 重新挂载运行期节点 |
| runtime/node/duplicate | 复制运行期节点 |
| runtime/node/find | 在运行期场景树中查找节点 |
| runtime/scene/tree | 查询运行期场景树 |
| runtime/signal/await | 等待运行期信号发送一次 |
| runtime/signal/connect | 连接运行期信号 |
| runtime/signal/disconnect | 断开运行期信号连接 |
| runtime/signal/emit | 主动 emit 运行期信号 |
| runtime/log/read | 增量读取运行期日志 |
| runtime/log/clear | 清空运行期日志 ring buffer |
| runtime/debug/breakpoints | 编辑断点 |
| runtime/debug/errors | 列出运行期错误 |
| runtime/debug/monitors | 读取标准 Performance 监控指标 |
| runtime/debug/performance | 读取 Performance 自定义 monitor 值 |
| runtime/assert/condition | 按条件 grammar 等待断言 |
| runtime/assert/node_exists | 等待节点出现在指定路径 |
| runtime/assert/property_equals | 等待节点属性等于期望值 |
| runtime/assert/signal_received | 等待节点 signal 至少发送一次 |
| runtime/screenshot/viewport | 截主视口当前帧 |
| runtime/screenshot/camera | 截 Camera2D/3D 的视口 |
| runtime/screenshot/frames | 按间隔连续截多帧 |
| runtime/input/key | 注入 InputEventKey |
| runtime/input/mouse | 注入 InputEventMouseButton/Motion |
| runtime/input/action | 触发 InputMap action |
| runtime/input/gamepad | 注入 joypad button/axis |
| runtime/input/touch | 注入 touch 事件 |
| runtime/input/sequence | 顺序触发多个输入事件 |

### shader（着色器）

| 路由 | 说明 |
|------|------|
| shader/read | 读取项目 Shader 源码 |
| shader/write | 创建或覆盖项目 Shader |
| shader/uniforms | 列出 Shader uniform |
| shader/param/set | 设置已声明的 ShaderMaterial uniform |
| shader/material/create | 创建 ShaderMaterial 资源 |

### theme（主题）

| 路由 | 说明 |
|------|------|
| theme/create | 创建 Theme 资源 |
| theme/stylebox/set | 设置 Theme StyleBox |
| theme/font_size/set | 设置 Theme 字体大小 |
| theme/constant/set | 设置 Theme 常量 |
| theme/color/set | 设置 Theme 颜色 |

### tilemap（瓦片地图）

| 路由 | 说明 |
|------|------|
| tilemap/info | 查询 TileMapLayer 信息 |
| tilemap/used_cells | 列出 TileMap 已用单元格 |
| tilemap/cell/get | 读取 TileMap 单元格 |
| tilemap/cell/set | 设置 TileMap 单元格 |
| tilemap/layer/clear | 清空 TileMapLayer |
| tilemap/rect/fill | 填充 TileMap 矩形 |

### uid（资源 UID）

| 路由 | 说明 |
|------|------|
| uid/get | 查询资源文件的 UID |
| uid/update_all | 批量更新项目中所有资源的 UID |
| uid/repair | 扫描并修复资源 UID |

### ui（UI）

| 路由 | 说明 |
|------|------|
| ui/control/set_anchor | 设置控件锚点 |
| ui/layout/build | 构建固定 UI 布局 |
| ui/text/set | 设置控件文本 |

### diagnostics（诊断）

| 路由 | 说明 |
|------|------|
| diagnostics/health | 返回项目诊断健康状态 |
| diagnostics/script_errors | 检查 GDScript 语法错误 |
| diagnostics/cycle_deps | 检测资源依赖环 |
| diagnostics/unused_resources | 查找未引用资源 |
