# gdcli

与 Godot 内置 LSP 服务器通过 TCP 通信，支持跨项目重命名、查找引用、跳转定义等代码智能能力。

## 安装

源码构建：

```bash
cargo build --release
# 产物：target/release/gdcli (Windows 下为 .exe)
```

## 前置条件

打开 Godot 编辑器即可（LSP 默认监听 6005 端口）。

或者

无头模式：

```bash
godot --editor --headless --lsp-port 6005 --path /path/to/project
```

## 命令

支持两种定位方式：**行列号** 和 **符号路径**。

### 行列号模式（传统）

行列号 0-based（LSP 约定）。

| 命令 | 说明 |
|---|---|
| `rename <file> <line> <col> <new_name>` | 跨项目重命名 |
| `references <file> <line> <col>` | 查找全部引用 |
| `definition <file> <line> <col>` | 跳转定义 |
| `declaration <file> <line> <col>` | 跳转声明 |
| `symbols <file>` | 列出文件符号 |
| `hover <file> <line> <col>` | 悬停信息 |
| `native-symbol <class> [member]` | Godot 内置类文档 |
| `diagnostics [file]` | 显示诊断 |
| `capabilities` | 显示 LSP 服务器能力 |
| `status` | 验证 LSP 服务器连接状态 |

### 符号路径模式（新功能）

使用 `文件:符号` 格式定位符号，无需手动查找行列号。

| 命令 | 说明 |
|---|---|
| `rename <target> <new_name>` | 按符号路径重命名 |
| `references <target>` | 查找符号的全部引用 |
| `definition <target>` | 跳转到符号定义 |
| `declaration <target>` | 跳转到符号声明 |
| `hover <target>` | 查看符号悬停信息 |

**符号路径格式**：`文件路径:符号路径`

```bash
# 简写形式（推荐）
gdcli definition player.gd:counter

# 完整形式（仅当文件名不含 '.' 时可用）
gdcli definition player.gd:Player.health

# 多级形式
gdcli definition player.gd:Player.Inventory.Item.name

# res:// 路径
gdcli definition res://player.gd:Player.health
```

**使用示例**：

```bash
# 查找定义
gdcli definition player.gd:counter

# 查找引用
gdcli references player.gd:counter

# 重命名符号
gdcli rename player.gd:counter new_counter

# 悬停信息
gdcli hover player.gd:counter

# JSON 模式输出
gdcli definition player.gd:counter --json
```

**错误处理**：

当符号找不到时，gdcli 会提供建议：

```
$ gdcli definition player.gd:count
Symbol 'count' not found. Did you mean: counter?
```

**限制**：

- 文件名包含 `.`（如 `2d_in_3d.gd`）时，只能使用简写形式
- 不支持真正的全局符号搜索（需要文件路径）

## 全局选项

| Flag | 默认 | 说明 |
|---|---|---|
| `--host <host>` | `127.0.0.1` | LSP 主机 |
| `--port <port>` | `6005` | LSP 端口 |
| `--project <path>` | — | 项目根，启用相对路径 |
| `--json` | — | 输出 JSON |

## 与 TS 版差异

- 参数缺失时 clap 退出码为 2（TS 版为 1）；正常错误退出码仍为 1。
- 其余行为（输出格式、超时、URI 解码）均与 TS 版逐字节一致。

## License

MIT
