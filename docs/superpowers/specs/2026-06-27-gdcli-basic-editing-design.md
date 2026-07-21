# gdcli 基础编辑闭环扩展设计

日期：2026-06-27

> **已被取代：** 本文保留为历史设计记录。当前 route 命名、Godot 4.7 基线和里程碑以 [gdcli 全功能能力路线图设计](2026-06-27-gdcli-full-capability-roadmap-design.md) 为准，不得据此生成新的 implementation plan。

## 背景

`docs/papers` 下的研究报告显示，Godot MCP/编辑器操控工具已经形成稳定能力谱系：场景管理、节点操作、脚本管理、文件/资源管理、信号/分组、运行时验证、导出与高级游戏系统等。gdcli 当前优势是 Rust CLI、Godot LSP、GDExtension HTTP 安全底座和嵌入式 addon 安装；短板是编辑器操控域少、无 UndoRedo、缺节点/脚本/资源/信号基础能力，也没有运行时探针。

本设计采用能力等价，而不是逐个复刻外部项目的工具/API 名称。目标是先建立可验证的基础编辑闭环，再渐进扩展到其它能力域。

## 目标

第一阶段交付“编辑 + 资源”的最小但完整闭环：

- 通过 `gdcli exec <route> --data ...` 操控 Godot 编辑器。
- 支持场景树查询、节点 CRUD/属性/层级操作。
- 支持脚本读写、创建、patch、attach/detach。
- 支持信号、分组、文件系统、资源信息/依赖/搜索/重导入。
- 所有里程碑都有基于 `GODOT_BIN` 的端到端验证脚本。
- 最低 Godot 版本升级到 4.6。

## 非目标

第一阶段不做以下能力：

- MCP server 或 MCP tool schema。
- runtime probe、运行时截图、输入模拟、wait/assert、运行时节点 inspect。
- 任意 editor/runtime eval。
- 动画、AnimationTree、TileMap、材质、Shader、音频、UI、主题、物理、导航、网络、导出、Android 部署。
- 对外部项目工具名的一比一兼容。

这些进入后续里程碑族：Runtime 验证闭环、游戏系统域、发布/诊断域。

## API 表面

第一阶段只扩展 `gdcli exec`，不新增每个功能对应的 CLI 子命令。CLI 仍负责：

- 读取 `.godot/gdapi.json`。
- 发送 Bearer token。
- POST JSON 到 gdapi route。
- 输出 TOON 或 JSON。
- 映射 HTTP 错误到退出码。

Godot 编辑器能力通过 route path 暴露。route path 是稳定 API。

## 路由分类

采用细粒度路由，优先可发现性和清晰目录边界。

第一阶段的新公开 route 使用 `editor/**` 命名空间，例如 `editor/node/create`。现有无前缀 route（如 `scene/create`、`project/run`、`log/output`）保留为兼容入口，不在第一阶段删除；新增能力只发布到新命名空间。M1 需要调整 router 的扫描/注册策略，使 `gdapi/addon/routes/editor/**` 可以暴露为 `editor/**`，并为现有 route 提供兼容别名。

### Scene

- `editor/scene/current`
- `editor/scene/open`
- `editor/scene/save`
- `editor/scene/tree`
- `editor/scene/list_open`

### Node

- `editor/node/create`
- `editor/node/delete`
- `editor/node/duplicate`
- `editor/node/rename`
- `editor/node/reparent`
- `editor/node/move`
- `editor/node/get`
- `editor/node/set`
- `editor/node/list`
- `editor/node/select`

### Node property

- `editor/node/property/get`
- `editor/node/property/set`
- `editor/node/property/list`

### Node signal

- `editor/node/signal/list`
- `editor/node/signal/connect`
- `editor/node/signal/disconnect`

### Node group

- `editor/node/group/list`
- `editor/node/group/add`
- `editor/node/group/remove`

### Script

- `editor/script/read`
- `editor/script/create`
- `editor/script/patch`
- `editor/script/write`
- `editor/script/attach`
- `editor/script/detach`
- `editor/script/current`
- `editor/script/open`

### Filesystem

- `editor/filesystem/list`
- `editor/filesystem/read`
- `editor/filesystem/write`
- `editor/filesystem/search`
- `editor/filesystem/grep`
- `editor/filesystem/reimport`

### Resource

- `editor/resource/info`
- `editor/resource/deps`
- `editor/resource/search`
- `editor/resource/reimport`
- `editor/resource/assign`

### Future route families

以下目录作为后续扩展分类，不在第一阶段实现：

- `editor/runtime/**`
- `editor/animation/**`
- `editor/tilemap/**`
- `editor/material/**`
- `editor/shader/**`
- `editor/audio/**`
- `editor/ui/**`
- `editor/physics/**`
- `editor/navigation/**`
- `editor/export/**`

## 共享基础设施

第一阶段先建设共享 GDScript 工具层，供 route 复用。

### 路径校验

路径工具负责把用户输入解析为 `res://`，并执行安全检查：

- 允许 `res://` 和项目相对路径。
- 拒绝 `..`。
- 拒绝绝对系统路径。
- 拒绝写入 gdcli addon 内部运行时代码、metadata token 等敏感位置。
- 读操作和写操作使用不同策略，写操作更严格。

### Variant 转换

统一 JSON ↔ Godot Variant 转换，支持 Godot 4.6 常用类型：

- `Vector2`、`Vector2i`
- `Vector3`、`Vector3i`
- `Vector4`、`Vector4i`
- `Color`
- `Rect2`、`Rect2i`
- `Transform2D`
- `Quaternion`
- `Basis`
- `Transform3D`
- `AABB`
- `NodePath`
- Resource path 自动加载

输入建议采用显式结构，例如：

```json
{"type":"Vector2","value":[10,20]}
```

简单 JSON 标量、数组、对象保持原样。

### 编辑动作包装

普通 editor mutation 尽量通过 `EditorUndoRedoManager` 包装：

- 节点创建、删除、重命名、reparent、属性设置。
- 脚本 attach/detach。
- 信号 connect/disconnect。
- 分组 add/remove。

保存、文件写入、资源重导入属于文件/资源操作，返回明确的 `changed`、`saved`、`reimported` 字段。

### 错误模型

所有 route 使用统一错误 code：

- `missing_param`
- `invalid_param`
- `invalid_path`
- `not_found`
- `conflict`
- `not_supported`
- `godot_error`

错误响应保留现有 HTTP status 语义。

### 危险操作策略

采用平衡策略：

- 删除、覆盖写、批量替换必须传 `force: true`。
- 普通 create、set、patch、attach 默认执行。
- 文件写入如果目标存在且未传 `force: true`，返回 `conflict`。
- 后续 eval/OS/export/network 类能力默认不进入第一阶段。

## 里程碑

### M1：基础设施与 Godot 4.6

- 将最低 Godot 兼容要求升级到 4.6。
- 更新 gdapi GDExtension 配置和 Rust `godot` crate feature。
- 增加共享路径校验、Variant 转换、编辑动作包装、统一错误辅助。
- 增加 E2E harness：`scripts/e2e-basic-edit.ps1` 和 `scripts/e2e-basic-edit.sh` 的基础框架。
- E2E 要求设置 `GODOT_BIN`，使用 `tests/fixture_project`。

验收：脚本能启动 Godot fixture project，安装/启用 addon，等待 `.godot/gdapi.json`，执行 `gdcli exec ping` 和 negative auth/route/path smoke case。

### M2：Scene/Node 闭环

- 实现场景 current/open/save/tree/list_open。
- 实现节点 create/delete/duplicate/rename/reparent/move/get/set/list/select。
- 实现属性 get/set/list。
- 节点 mutation 走 UndoRedo。

验收：E2E 创建测试场景，新增节点，设置 Vector/Color/Resource 属性，重命名/reparent/delete，保存后重开场景并验证树结构精确匹配。

### M3：Script/Filesystem 闭环

- 实现脚本 read/create/patch/write/attach/detach/current/open。
- 实现 filesystem list/read/write/search/grep/reimport。
- 写入和删除类操作遵守 `force:true` 策略。

验收：E2E 创建脚本，patch 函数或变量，attach 到节点，保存后通过文件内容和场景引用验证；覆盖写未传 force 返回 conflict。

### M4：Resource/Signal/Group 闭环

- 实现 resource info/deps/search/reimport/assign。
- 实现 node signal list/connect/disconnect。
- 实现 node group list/add/remove。

验收：E2E 创建或使用 fixture 资源，查询依赖，重导入，分配到节点；连接/断开信号；添加/移除分组；保存后重新查询确认状态。

### M5：整理与收口

- 更新 README 命令示例。
- 更新 route help/commands 文档完整性。
- 增加能力矩阵，标注已覆盖、后续规划、明确非目标。
- 固化 E2E fixture 数据和清理策略。

验收：`cargo test --workspace`、`cargo clippy --workspace`、`cargo fmt --check`、所有 E2E 脚本通过。

## E2E 验证夹具设计

E2E 脚本以 `GODOT_BIN` 为唯一外部依赖：

1. 构建 workspace。
2. 使用 `gdcli install --project tests/fixture_project --force` 安装 addon。
3. 启动 Godot 4.6 editor/headless editor 指向 fixture project。
4. 等待 `.godot/gdapi.json` 出现并包含 `http_port`、`token`。
5. 通过 `gdcli exec` 执行当前里程碑的正例和反例。
6. 读取场景、脚本、资源文件或再次调用查询 route 验证最终状态。
7. 清理 fixture 中本次测试生成的文件。
8. 停止 Godot。

每个里程碑的 E2E 必须验证“精确收口”：不仅检查命令成功，还检查目标对象存在、属性值正确、错误分支按预期拒绝、未产生额外文件或节点。

## 成功标准

第一阶段完成后，gdcli 能通过 `exec` 安全、可撤销、可端到端验证地完成常见 Godot 编辑器自动化：创建/修改场景树，读写和挂载脚本，管理资源、信号和分组，并能用程序验证结果。

## 后续扩展顺序

第一阶段后建议继续拆分为独立 spec：

1. Runtime 验证闭环：runtime scene tree、input、screenshot、wait/assert、log/error buffer。
2. 游戏系统域：animation、TileMap、material/shader、audio、UI/theme、physics、navigation。
3. 发布与诊断域：export、project audit、unused resource、cycle dependency、test runner。
4. 工具面治理：core/supplement、route category enable/disable、future MCP server 映射。
