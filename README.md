# gdcli

`godot-lsp-cli` 的 Rust 复刻版本，与 Godot 内置 LSP 服务器通过 TCP 通信，支持跨项目重命名、查找引用、跳转定义等代码智能能力。

## 安装

源码构建：

```bash
cargo build --release
# 产物：target/release/gdcli (Windows 下为 .exe)
```

## 前置条件

打开 Godot 编辑器即可（LSP 默认监听 6005 端口）。无头模式：

```bash
godot --editor --headless --lsp-port 6005 --path /path/to/project
```

## 命令

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
