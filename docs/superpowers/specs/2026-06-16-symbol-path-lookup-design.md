# Symbol Path Lookup Design

**Date**: 2026-06-16  
**Status**: Approved  
**Author**: OpenCode

## Overview

为 gdcli 引入基于全局符号路径的检索方式，允许用户使用 `文件路径:符号路径` 格式定位符号，而不必手动查找行号和列号。

## Motivation

当前 gdcli 的所有子命令都基于 `文件名 + 行 + 列` 的符号定位方式，这要求用户：
1. 知道符号所在的文件
2. 知道符号的行号和列号
3. 手动输入这些信息

这在大型项目中非常不便。符号路径功能允许用户直接使用符号名称定位，提高开发效率。

## Design

### 1. Symbol Path Format

**基本格式**：`文件路径:符号路径`

**示例**：
```bash
# 完整形式
gdcli definition player.gd:Player.health

# 简写形式（省略类名）
gdcli definition player.gd:health

# 多级形式
gdcli definition player.gd:Player.Inventory.Item.name

# res:// 路径
gdcli definition res://player.gd:Player.health
```

**解析规则**：
- 以第一个 `:` 分割文件和符号
- 符号路径以 `.` 分隔各级符号
- 第一段为类名（可选），后续段为成员路径

### 2. Command Integration

**自动检测**：根据第一个参数是否包含 `:` 判断模式

```bash
# 符号路径模式
gdcli definition player.gd:Player.health

# 文件+位置模式（现有功能）
gdcli definition player.gd 10 5
```

**支持符号路径的子命令**：
- definition
- declaration
- references
- hover
- rename

**rename 命令特殊格式**：
```bash
gdcli rename player.gd:Player.health new_health
```

### 3. Parsing Flow

1. **分割文件和符号**：`player.gd:Player.health` → 文件=`player.gd`，符号=`Player.health`
2. **解析文件路径**：支持相对路径、绝对路径、res:// 路径
3. **调用 `documentSymbols`**：获取文件符号树
4. **查找符号**：
   - 完整形式：`Player.health` → 查找 `Player` → 查找 `health`
   - 简写形式：`health` → 直接在顶层符号中查找
5. **调用 LSP 请求**：使用 `selectionRange` 的位置

### 4. Error Handling

**友好错误消息**：
```
Error: Symbol 'Player.health' not found in file 'player.gd'
```

**模糊匹配建议**：
```
Error: Symbol 'Player.health' not found in file 'player.gd'
Did you mean?
  - Player.health_bar
  - Player.heal
```

### 5. Output Format

**普通模式**（同一行）：
```
[Variable] Player.health @ player.gd:10:5
```

**JSON 模式**：
```json
{
  "symbol": {
    "name": "health",
    "kind": "Variable",
    "kindId": 13,
    "detail": "var health: int",
    "documentation": ""
  },
  "location": {
    "file": "player.gd",
    "range": {
      "start": { "line": 10, "character": 5 },
      "end": { "line": 10, "character": 11 }
    }
  }
}
```

### 6. Implementation Plan

#### 6.1 Symbol Path Parser

新增 `src/symbol_path.rs`，实现符号路径解析：

```rust
pub struct SymbolPath {
    pub file: PathBuf,
    pub segments: Vec<String>,
}

impl SymbolPath {
    pub fn parse(input: &str) -> Result<Self>;
    pub fn is_symbol_path(input: &str) -> bool;
}
```

#### 6.2 Symbol Resolver

在 `src/client.rs` 中新增符号解析方法：

```rust
impl GodotLspClient {
    pub async fn resolve_symbol_path(&self, file: &Path, segments: &[String]) -> Result<SymbolLocation>;
}
```

#### 6.3 Command Integration

修改 `src/main.rs`，集成符号路径功能：

1. 添加参数解析逻辑，自动检测符号路径模式
2. 对于支持符号路径的子命令，调用符号解析器
3. 增强输出格式

#### 6.4 Error Handling

新增错误类型和模糊匹配逻辑：

```rust
pub enum SymbolError {
    NotFound { symbol: String, file: String },
    PartialMatch { symbol: String, suggestions: Vec<String> },
}
```

### 7. Testing Strategy

**单元测试**：
- 符号路径解析逻辑
- 简写形式处理
- 错误处理和模糊匹配

**手动测试**：
- 使用真实 Godot LSP Server 测试完整流程
- 测试各种符号类型（类、方法、属性、常量、信号等）

### 8. Limitations

1. **Godot LSP 不支持 `workspace/symbol`**：无法实现真正的全局符号搜索（不带文件路径）
2. **性能影响**：每次使用符号路径都需要调用 `documentSymbols`
3. **符号树变化**：符号树可能随时变化，不缓存

### 9. Future Work

1. **支持更多符号类型**：信号、枚举、内部类等
2. **支持通配符**：如 `Player.*` 匹配所有成员
3. **支持正则表达式**：如 `Player./health.*/` 匹配所有 health 相关成员
