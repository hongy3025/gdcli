# native-symbol 渐进式文档展示设计

## 概述

扩展 `gdcli native-symbol` 命令，通过 `--members` 和 `--full` 选项实现渐进式披露的文档展示，替代当前仅显示类名+描述+成员数量的简略输出。

## 命令语法

```bash
gdcli native-symbol <class>                  # 默认：类概览
gdcli native-symbol --members <class>        # 成员列表
gdcli native-symbol --full <class>           # 完整文档
gdcli native-symbol <class> <member>         # 单成员详情
```

`--members` 和 `--full` 互斥（clap conflict）。

## 四种输出形态

### 1. 默认（无 flag，无 member）

与当前行为一致。显示类名、detail、class documentation 全文。

```
Node3D — <Native> class Node3D extends Node

A 3D node in the scene tree with 3D transformation.
...（class documentation 全文）
```

### 2. `--members`

按 kind 分组，每行显示：成员名 + 类型签名 + documentation 首行简述。

```
Constants:
  NOTIFICATION_ENTER_TREE    const NOTIFICATION_ENTER_TREE: int = 10    Constant to notify when entering tree
  NOTIFICATION_EXIT_TREE     const NOTIFICATION_EXIT_TREE: int = 11     Constant to notify when exiting tree

Properties:
  position    var position: Vector3    Position in global coordinates
  rotation    var rotation: Vector3    Rotation in radians

Signals:
  visibility_changed    signal visibility_changed() -> void    Emitted when visibility changed

Methods:
  get_parent       func get_parent() -> Node       Returns the parent node
  get_child_count  func get_child_count() -> int   Returns the number of children
```

简述取 `documentation` 第一行，截断去除首尾空白。无 documentation 时留空。

### 3. `--full`

类信息 + 所有成员完整展开。按 kind 分组，每个成员显示 detail + 全部 documentation。

```
Node3D — <Native> class Node3D extends Node

A 3D node in the scene tree with 3D transformation.
...（class documentation 全文）

── Constants ──

NOTIFICATION_ENTER_TREE
  const NOTIFICATION_ENTER_TREE: int = 10

  Constant to notify when the node enters the scene tree.
  ...（完整 documentation）

NOTIFICATION_EXIT_TREE
  const NOTIFICATION_EXIT_TREE: int = 11
  ...

── Properties ──

position
  var position: Vector3

  Position of this node in global coordinates.
  ...

── Signals ──

visibility_changed
  signal visibility_changed() -> void

  Emitted when the node's visibility changes.
  ...

── Methods ──

get_parent
  func get_parent() -> Node

  Returns the parent node of the current node.
  ...
```

### 4. `<class> <member>`

单成员完整输出。不受 `--members` / `--full` 影响，始终显示 detail + 全部 documentation。

```
get_parent
  func get_parent() -> Node

  Returns the parent node of the current node, or null if the
  node has no parent. A node's parent is the node last added
  as a child of this node.
```

## LSP 请求

无需新方法或新参数。已有 `textDocument/nativeSymbol` 返回含 `children` 的完整符号树。

| 场景 | 请求参数 | 响应内容 |
|------|----------|----------|
| 默认 / `--members` / `--full` | `symbol_name = class` | 类符号 + children 数组 |
| `<class> <member>` | `symbol_name = member` | 单成员符号，无 children |

当前代码（`client.rs:361-371`）请求逻辑不变。

## 实现要点

### CLI 参数变更（main.rs）

`Cmd::NativeSymbol` 增加两个 bool flag：

```rust
#[command(name = "native-symbol")]
NativeSymbol {
    #[arg(long, conflicts_with = "full")]
    members: bool,
    #[arg(long, conflicts_with = "members")]
    full: bool,
    class: String,
    member: Option<String>,
},
```

### 输出格式化函数（main.rs）

新增三个函数：

- `format_native_members_table(children: &[Value])` — 按 kind 分组，输出成员表（名字 + detail 首行 + documentation 首行）
- `format_native_full(children: &[Value])` — 按 kind 分组，完整展开每个成员
- `format_native_member(v: &Value)` — 单成员完整输出（detail + documentation）

### Kind 分组顺序

按 Godot 文档惯例排列：

1. Constants（kind=14）
2. Properties（kind=13）
3. Signals（kind=24, Event）
4. Methods（kind=6）
5. Constructors（kind=9）
6. Operators（kind=25）
7. Annotations（kind=15）

末尾出现的未知 kind 归入 "Other" 组。

### 简述提取

从 `documentation` 字段取首行：

```rust
fn first_line(doc: &str) -> &str {
    doc.lines().next().unwrap_or("").trim()
}
```

### handle 分发逻辑

```rust
if member.is_some() {
    // 单成员详情
    format_native_member(&v);
} else if full {
    // 完整文档
    print_class_header(&v);
    format_native_full(children);
} else if members {
    // 成员表
    format_native_members_table(children);
} else {
    // 默认：类概览（当前行为）
    format_native_class_overview(&v);
}
```

## 测试

- `native-symbol Node3D` — 默认输出不变
- `native-symbol --members Node3D` — 分组成员表
- `native-symbol --full Node3D` — 完整展开
- `native-symbol Node3D get_parent` — 单成员详情
- `native-symbol --members --full Node3D` — clap 报互斥错误
- `--json` 模式下所有形态输出完整 JSON（不受 flag 影响）

## 不做的事情

- 不添加 BBCode→Markdown 转换（保持原样输出，Godot 文档的 BBCode 本身可读）
- 不支持 `--members` + `<member>` 组合（指定 member 时忽略 flag）
- 不缓存 LSP 响应
