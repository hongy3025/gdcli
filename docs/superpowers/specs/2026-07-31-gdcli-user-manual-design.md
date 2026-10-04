# gdcli 用户手册设计

## 概要

为 gdcli 编写一套渐进式披露的 Markdown 用户手册，中文。主文档 + 每个子命令独立文件。
exec 子命令因路由众多，采用"教用户查在线文档 + 全路由一览表"策略，不逐路由详细描述。

## 文档结构

```
docs/gdcli/
  gdcli-manual.md        ← 入口文档：简介、安装、快速上手、子命令索引、全局选项
  gdcli-lsp.md           ← lsp 子命令：9 个子命令、两种定位方式、native-symbol
  gdcli-status.md        ← status 子命令（极简）
  gdcli-install.md       ← install 子命令（极简）
  gdcli-exec.md          ← exec 子命令：语法、在线文档查询、全路由一览表
```

### gdcli-manual.md（入口文档）

- 简介：gdcli 是什么，与 Godot 编辑器交互的 CLI，两种工作模式（LSP + exec）
- 安装：`cargo build --release`
- 前置条件：Godot 4.7.x，LSP 需编辑器运行，exec 需 gdapi 插件
- 快速上手：2-3 条典型命令
- 子命令索引表：每个子命令一行 + 文档链接
- 全局选项：`--project`、`--port`、`--json`、`--timeout` 等

### gdcli-lsp.md

- 概述：LSP 模式功能 + 需要编辑器运行中
- 两种定位方式：行列号（1-based）与符号路径
- 子命令速查表：9 个子命令，一行一个
- 符号路径格式：简写、完整、多级、res:// 前缀、限制条件
- native-symbol 渐进式披露：默认 / `--members` / `--full` 三级

### gdcli-status.md

极简。语法 + 输出说明 + 典型用途。

### gdcli-install.md

精简。语法 + 参数说明 + 安装效果 + 注意事项。

### gdcli-exec.md

- 概述：exec 模式通过 gdapi HTTP 插件通信
- 语法：`gdcli exec <command> [--data <json>] [--timeout <secs>]`
- 数据来源：字面 JSON、`@file`、`-`（stdin）
- 特殊命令：`command/list`、`command/doc <route>`（位置参数、不接受 `--data`）
- 在线文档查询（重点）：展示 `command/list` 和 `command/doc` 用法
- 输出格式：默认 TOON、`--json`、`command/list`/`command/doc` 的 clap 风格
- 退出码：0（成功）、1（服务器错误）、2（客户端错误）、3（网络/元数据错误）
- 全路由一览表：按功能域分组，每行"路径 | 一句话描述"

#### 路由表分组

| 分组 | 覆盖路由前缀 |
|------|-------------|
| gdapi | gdapi/health/, gdapi/audit/, gdapi/loglevel |
| godot | godot/version |
| scene | scene/ 全部 |
| node | node/ 全部（含 property/, group/, signal/） |
| script | script/ 全部 |
| resource | resource/ 全部 |
| project | project/ 全部（含 settings/, input_map/, autoload/） |
| animation | animation/ 全部（含 key/, track/） |
| animation_tree | animation_tree/ 全部 |
| audio | audio/ 全部（含 bus/, player/） |
| classdb | classdb/ 全部 |
| console | console/output |
| editor | editor/ 全部 |
| export | export/ 全部 |
| filesystem | filesystem/ 全部 |
| material | material/ 全部 |
| navigation | navigation/ 全部 |
| network | network/http_request |
| physics | physics/ 全部 |
| process | process/run |
| runtime | runtime/ 全部（含 node/, scene/, signal/, log/, debug/, assert/, screenshot/, input/） |
| shader | shader/ 全部 |
| theme | theme/ 全部 |
| tilemap | tilemap/ 全部 |
| uid | uid/ 全部 |
| ui | ui/ 全部 |
| diagnostics | diagnostics/ 全部 |

## 写作风格

- 中文，Markdown
- 精确、简洁、信息密度高
- 不解释 CLI 惯用法
- 不逐路由展开 exec 文档（使用 `command/doc` 在线查询替代）