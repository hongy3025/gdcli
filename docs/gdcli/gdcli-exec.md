# gdcli exec — 调用 Godot 编辑器命令

通过 gdapi HTTP 插件与运行中的 Godot 编辑器通信。需要编辑器运行中且 gdapi 插件已启用。

```bash
gdcli exec <command> [--data <json>] [--timeout <secs>] [--project <path>]
```

| 选项 | 默认 | 说明 |
|------|------|------|
| `--data <json>` | `{}` | 请求数据：字面 JSON、`@file`（从文件读取）、`-`（从 stdin 读取） |
| `--timeout <secs>` | 30 | 请求超时秒数 |

## 特殊命令

`command/doc` 需要位置参数（路由名），两者都不接受 `--data`；`command/list` 不接受位置参数：

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

## 路由能力概览

路由按 addon 文件结构动态注册，以下按能力域概述，不是逐条路由清单。当前完整列表以运行中的编辑器返回结果为准：

```bash
gdcli exec command/list --project .
gdcli exec command/doc scene/close --project .
```

`command/list` 列出已注册路由及摘要；`command/doc <route>` 返回该路由的参数、返回字段和调用示例。路由参数或行为以 `command/doc` 为准。

| 能力域 | 主要内容 | 路由示例 |
|------|------|------|
| gdapi 与命令发现 | 健康检查、路由发现、审计和日志级别 | `gdapi/health/ping`、`gdapi/routes`、`command/list`、`command/doc` |
| 场景与节点 | 场景打开/保存/关闭、节点与属性编辑、信号/分组、场景批处理和引用扫描 | `scene/*`、`scene/batch/*`、`scene/project/*`、`node/*` |
| 脚本、文件与资源 | 脚本编辑、文件读写/搜索/事务、资源操作与 UID 修复 | `script/*`、`filesystem/*`、`resource/*`、`uid/*` |
| 编辑器控制 | 选择、Undo/Redo、Inspector、Dock、插件/设置、相机和视口截图 | `editor/*` |
| 项目与诊断 | 项目设置、InputMap、Autoload、ClassDB、静态诊断和受控导出 | `project/*`、`classdb/*`、`diagnostics/*`、`export/*` |
| 游戏系统 | Animation/AnimationTree、Audio、TileMap、Material/Shader、UI/Theme、2D Physics/Navigation、3D 场景和粒子 | `animation*`、`audio/*`、`tilemap/*`、`physics/*`、`navigation/*`、`scene3d/*`、`particles/*` |
| 运行时与 QA | 游戏进程内节点/输入/信号操作、日志、截图、录制、监视、断言、测试、Tween 和像素比较 | `runtime/*` |
| 自动化与网络 | 无 shell 进程、HTTP(S) 请求和批量文件操作 | `process/run`、`network/http_request`、`filesystem/batch/*` |

### 行为边界

- `scene/close` 仅关闭当前编辑场景；`path` 可省略或指向当前场景，不能用它关闭另一个已打开场景。
- Physics 与 Navigation 当前仅支持 2D；对应的 3D 操作返回 `not_supported`。非空 `MultiMeshInstance3D` 读回需要活动渲染器，headless 下返回 `not_supported`。
- Runtime 请求经 broker 转发，优先使用 EngineDebugger，条件不满足时回退到项目内 file transport。当前协议范围内，`runtime/debug/errors` 返回空列表，`runtime/debug/breakpoints` 不支持。
- 导出仅面向桌面预设；Android 平台能力不属于当前范围，详见[分支总目标与范围](../superpowers/specs/2026-10-03-gdcli-branch-goal-and-scope.md)。
