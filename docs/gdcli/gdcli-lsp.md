# gdcli lsp — LSP 代码智能操作

通过 Godot 内置 LSP 服务器操作代码。需要编辑器运行中。

## 定位方式

支持两种方式指定目标符号：

**行列号**（1-based，与编辑器显示一致）：

```bash
gdcli lsp definition player.gd 10 5
gdcli lsp rename player.gd 10 5 new_name
```

**符号路径**（无需手动查找行列号）：

```bash
gdcli lsp definition player.gd:health
gdcli lsp definition player.gd:Player.Inventory.name
```

## 子命令

| 子命令 | 参数 | 功能 |
|--------|------|------|
| `rename` | `<target> <new_name>` | 重命名符号 |
| `references` | `<target>` | 查找引用 |
| `definition` | `<target>` | 跳转到定义 |
| `declaration` | `<target>` | 跳转到声明 |
| `symbols` | `<file>` | 列出文件符号 |
| `hover` | `<target>` | 悬浮提示 |
| `native-symbol` | `<class> [member]` | 查询 Godot 原生类文档 |
| `diagnostics` | `[file]` | 诊断信息（编译错误/警告） |
| `capabilities` | — | 服务器能力列表 |

## 符号路径格式

- 简写：`player.gd:counter` — 符号名在当前文件内唯一时使用
- 完整：`player.gd:Player.health` — 类名.成员
- 多级：`player.gd:Player.Inventory.Item.name` — 嵌套类
- `res://` 前缀：`res://player.gd:Player.health` — 完整项目路径
- 限制：文件名含 `.`（如 `2d_in_3d.gd`）时只能用简写形式

## native-symbol 渐进式披露

查询 Godot 内置类文档。三个披露级别：

| 模式 | 示例 | 输出 |
|------|------|------|
| 默认 | `gdcli lsp native-symbol Node3D` | 类名、签名、描述全文 |
| `--members` | `gdcli lsp native-symbol --members Node3D` | 按 Constants/Properties/Signals/Methods 分组列表 |
| `--full` | `gdcli lsp native-symbol --full Node3D` | 所有成员完整展开（detail + 全部 documentation） |
| 查询成员 | `gdcli lsp native-symbol Node3D get_parent` | 单个成员详情 |

`--members` 与 `--full` 互斥。`--json` 模式下输出完整 JSON，不受 flag 影响。