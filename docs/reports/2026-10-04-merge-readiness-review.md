# gdcli 分支合并质量评价报告

日期：2026-10-04  
分支：`feat/full-capability`  
评估提交：`2fff8d1`  
主干基线：`afbe34a32090261b083641c316526b29375605b1`（`afbe34a`）  
运行环境：Windows x64、Godot `4.7.2`  
评价结论：**尚未达到合并主干标准，建议 Request changes。**

> 本报告记录上述提交快照的审查结果，不代表后续提交的质量状态。源码链接中的行号对应评估时的代码，后续修改可能使行号漂移。后续问题关闭应提供修复提交及对应行为的验证结果，不能仅以门禁再次全绿替代。

## 1. 评估范围与结论

本次评价针对整个分支相对主干的变更，而非仅最后一个提交：

- 170 个提交。
- 785 个变更文件。
- 约新增 57,367 行、删除 22,479 行。
- 审查重点包括运行时与任务生命周期、文件与项目配置持久化、破坏性操作、安全边界、跨平台实现及 CI 门禁。

本分支已有较完整的功能和测试门禁，但**行为可靠性、数据安全和安全边界仍有明确阻断项**。这不是缺少测试数量的问题，而是已经复现了测试全绿仍未覆盖的消费者可见缺陷。

上一轮“验收通过”可以理解为那些门禁通过了，不能等同于“分支已经 merge-ready”。目前不应直接合并主干。

## 2. 合并前应修复的已确认问题

以下九项均通过真实 Godot、实际 CLI 调用和隔离项目复现，不只是源码推测。网络验证仅使用本地服务和假凭据；未向外部服务发送真实认证信息。

### R01：跨源重定向泄露认证信息

- **复现方式**：向本地服务 A 发起 `network/http_request`，携带假 `Authorization` 与 `Cookie`；A 返回 302，重定向到不同端口的本地服务 B。
- **观察结果**：请求成功，B 收到了原请求的 `Authorization: Bearer MERGE_REVIEW_SENTINEL` 和 `Cookie: session=MERGE_REVIEW_SENTINEL`。
- **问题**：不同端口属于不同 origin，但重定向复用了原始请求头，没有隔离认证信息。
- **影响**：重定向目标可以收到原本只应发送给初始目标的凭据。
- **代码位置**：[network_service.gd:96–116](../../gdapi/addon/runtime/services/network_service.gd#L96)。

### R02：受限 eval 在拒绝输入前已经执行代码

- **复现方式**：调用 `editor/eval`，表达式为 `1`，输入值使用 Resource 编码，指向此前未加载的 `user://` 脚本。脚本的 `_static_init()` 写入一个标记文件。
- **观察结果**：接口以 `invalid_param` 拒绝该输入，但标记文件已经生成，内容证明静态初始化已执行。
- **问题**：先由 `VariantCodec.decode()` 加载资源，再检查结果是否含 Object；拒绝检查发生在副作用之后。
- **影响**：受限求值接口并未在执行副作用之前守住其安全边界。
- **代码位置**：[eval_service.gd:30–35](../../gdapi/addon/runtime/services/eval_service.gd#L30)、[variant_codec.gd:224–233](../../gdapi/addon/runtime/variant_codec.gd#L224)。

### R03：生产默认超时后，任务仍产生副作用并审计成功

- **复现方式**：不设置 `GDAPI_HANDLER_TIMEOUT_MS`，调用 `process/run`，业务超时设为 60 秒；被执行脚本等待 35 秒后写文件。
- **观察结果**：CLI 约 30.019 秒收到 HTTP 504，错误为 `handler timeout`；当时文件未生成。约 37 秒观察时，文件已经生成，审计最终记录 `process/run` 为 `ok:true`。
- **问题**：HTTP 默认处理期限为 30 秒，与业务任务接受的期限不一致；HTTP 超时没有同步取消业务任务并协调最终状态。
- **影响**：调用者看到失败，后台却继续执行副作用并报告成功，无法可靠判断操作结果。
- **代码位置**：[server.rs:27](../../gdapi/rust/src/server.rs#L27)、[server.rs:473–489](../../gdapi/rust/src/server.rs#L473)。

### R04：只读目标的场景另存为误报成功

- **复现方式**：修改当前场景，然后通过 `scene/current/save` 另存为到一个已有、只读的场景文件。
- **观察结果**：返回 `ok:true`、`saved:true`、`changed:true`，但目标文件字节完全未变；`scene/current` 同时报告新目标路径和 `edited:false`。
- **问题**：`EditorInterface.save_scene_as()` 调用后无条件将结果设为 `OK`，没有确认保存实际完成。
- **影响**：调用者可能误以为改动已落盘，存在关闭场景后丢失修改的风险；本次已确认的是误报和状态不一致，并未将风险表述为已发生的数据丢失。
- **代码位置**：[scene_editor.gd:103–120](../../gdapi/addon/runtime/services/scene_editor.gd#L103)。

### R05：场景删除漏查 GDScript 的 preload 引用

- **复现方式**：让一个 GDScript 通过 `preload("res://scenes/merge_review_target.tscn")` 引用目标场景，先 dry-run，再真实执行 `scene/delete`。
- **观察结果**：dry-run 返回 `can_delete:true`、空 references；真实删除成功。已有编辑器缓存一度使脚本验证仍成功，但使用新的 Godot 进程检查该脚本时，退出码为 1，并报 `Preload file ... does not exist`。
- **问题**：依赖扫描只检查 `tscn`、`scn`、`tres`、`res`，跳过 GDScript。
- **影响**：删除前的依赖检查误判安全，实际删除会破坏项目。
- **代码位置**：[scene_editor.gd:344–351](../../gdapi/addon/runtime/services/scene_editor.gd#L344)。

### R06：UID 修复绕过受保护目录的写入限制

- **复现方式**：在隔离项目的 addon 目录内准备一个缺少 UID 的有效资源。对该文件执行 `filesystem/write`，再以 `res://addons/gdapi` 为根调用 `uid/repair`，设置 `dry_run:false`。
- **观察结果**：`filesystem/write` 返回 403；`uid/repair` 却返回成功，并实际修改了受保护目录内的资源文件。
- **问题**：根路径使用读权限校验；保护判断只匹配带尾部斜杠的前缀，随后写入时没有逐文件执行写权限校验。
- **影响**：不同写入路由对同一受保护路径执行了不一致的权限策略。
- **代码位置**：[uid_repair.gd:14–20](../../gdapi/addon/runtime/services/uid_repair.gd#L14)、[uid_repair.gd:41–44](../../gdapi/addon/runtime/services/uid_repair.gd#L41)。

### R07：InputMap 失败回滚反而新增绑定

- **复现方式**：创建一个没有事件绑定的 InputMap action，将 `project.godot` 设为只读，然后尝试 unbind 一个不存在的按键事件。
- **观察结果**：保存失败并返回 `godot_error`；磁盘内容未变，但内存 InputMap 中反而出现了该按键绑定。
- **问题**：unbind 的回滚逻辑无条件添加被请求移除的事件，没有恢复操作前的真实状态。
- **影响**：失败操作并非原子操作，错误路径改变了项目的内存行为。
- **代码位置**：[project_config.gd:147–161](../../gdapi/addon/runtime/services/project_config.gd#L147)。

### R08：资源类型不匹配却报告赋值成功

- **复现方式**：通过 `resource/assign` 将 `StandardMaterial3D` 资源赋给 `Sprite2D.texture`。
- **观察结果**：返回 `ok:true`、`changed:true`、`undoable:true`，但 texture 仍为 null。
- **问题**：只检查目标是否为资源属性，没有检查该资源子类是否与目标属性兼容，也没有确认赋值实际生效。
- **影响**：自动化调用者收到成功结果，但目标状态没有达到请求要求。
- **代码位置**：[resource_editor.gd:559–595](../../gdapi/addon/runtime/services/resource_editor.gd#L559)。

### R09：被拒绝 URL 中的密码进入审计日志

- **复现方式**：调用 `network/http_request`，URL 为 `http://user:MERGE_REVIEW_AUDIT_SENTINEL@example.invalid/`，随后读取 `gdapi/audit/list`。
- **观察结果**：请求以 `invalid_param` 被拒绝，但审计 summary 中保留了完整原始 URL，包括假密码。
- **问题**：错误审计直接记录原始 URL；通用字段脱敏没有识别 URL 内的认证信息。
- **影响**：即使请求被拒绝，敏感信息仍会进入可读取的审计记录。
- **代码位置**：[http_request.gd:12](../../gdapi/addon/routes/network/http_request.gd#L12)、[audit_log.gd:171–196](../../gdapi/addon/runtime/audit_log.gd#L171)。

## 3. 已通过的验证及其证明边界

### 3.1 上一轮门禁证据

下表引用上一轮实际执行结果；本次评价没有为重复确认这些结果而重新执行全套门禁。

| 验证项 | 结果 |
|---|---|
| GDScript 格式化与 lint | 755 个 GDScript 文件通过 |
| Clippy | 通过，warnings denied |
| Rust 测试 | 202 passed |
| Python timing 测试 | 24 passed |
| file 套件 | 537 passed、4 deselected，345.84 秒 |
| engine 套件 | 1 passed，29.65 秒 |
| 真实 renderer 套件 | 2 passed，26.13 秒 |
| 预算测试 | 1 passed；parent wall 约 349.612 秒，阈值 360 秒 |

这些结果是有效的通过证据，但只能证明被运行场景及其断言通过，不能证明所有生产配置、错误路径和安全边界都正确。

### 3.2 本次真实运行验证

本次使用现有 CLI 与 gdapi 构建产物，在隔离项目中启动真实 Godot 并调用 CLI，没有用永久测试或模拟响应替代缺陷复现。

- 真实 GUI dock 查询正常。
- 2D/3D 截图能够生成有效的 480 × 320 PNG；实际 OpenGL 渲染使用 AMD Radeon RX 7900 XTX。
- 第 2 节九项负向行为均已复现。
- 场景删除的破坏性结果通过新的 Godot 进程确认，避免旧编辑器资源缓存造成误判。
- 网络行为使用两个本地 HTTP 服务及假凭据验证。
- 验证结束后停止编辑器与本地服务，清理临时项目；未修改仓库代码或执行合并。

### 3.3 测试环境与生产默认配置的偏差

E2E 启动编辑器时将 `GDAPI_HANDLER_TIMEOUT_MS` 设置为 **180000 毫秒**，而生产默认值是 **30000 毫秒**。

代码位置：[shared_fixture.py:244–247](../../tests/e2e/shared_fixture.py#L244)、[server.rs:27](../../gdapi/rust/src/server.rs#L27)。

这一偏差掩盖了 R03 所示的默认配置问题。后续需要覆盖生产默认配置，而不是仅在放宽后的期限下验证任务成功。

## 4. 尚需处理的风险与验证缺口

### 4.1 Unix 进程树清理未实现

非 Windows 的 `ProcessTreeGuard::terminate()` 是空实现，任务结束时又会无界等待 stdout/stderr 线程：

- [process_runner.rs:127–134](../../gdapi/rust/src/process_runner.rs#L127)。
- [process_runner.rs:328–336](../../gdapi/rust/src/process_runner.rs#L328)。

**[INFERENCE]** 子孙进程若继续持有输出管道，可能使超时清理或完成处理长期阻塞。该风险有明确源码依据，但本次未在 Linux/macOS 上运行复现，不计入第 2 节已确认故障。

README 声明支持这些桌面平台，因此这一实现缺口需要在合并前解决或完成有效验证，不能以 Windows 门禁通过代替。

### 4.2 尚无远端 CI 成功证据

审查时，[GitHub Actions API](https://api.github.com/repos/hongy3025/gdcli/actions/runs?branch=feat%2Ffull-capability&per_page=5) 返回该分支 `total_count: 0`。

因此，当前证据是本地门禁通过，并非评估提交已经通过远端 CI。该 API 链接返回的是动态状态；这里记录的是审查时观察到的结果。

已有 [verify workflow](../../.github/workflows/verify.yml) 以 Windows 为执行平台，尚不能作为 Linux/macOS 行为已验证的证据。

### 4.3 预算余量偏小，但不是主要阻断项

预算实测约 **349.61 秒 / 360 秒**，余量约 **10.39 秒，即 2.9%**。

预算确实通过，但在不同机器或 CI 波动下需要关注稳定性，不能靠提高预算或缩减测试范围掩盖问题。本项不是本次拒绝合并的主要依据。

### 4.4 不应误列为缺陷的已批准范围变更

本评价没有将以下事项作为新增阻断项：

- Android 已从当前目标范围移除。
- Godot 支持基线已收口到 4.7.x。
- 已验收的桌面导出范围为 PCK/Pack；缺少可执行文件导出模板不等同于已选范围未完成。

本次审查重点是高风险行为及质量门禁，不承诺全部 785 个变更文件不存在其他缺陷。

## 5. 合并准入条件

1. **修复 R01–R09 并逐项验证实际行为。**
   - 返回状态、最终副作用及审计结果一致。
   - 保存失败不能误报成功，也不能误导调用者认为修改已落盘。
   - 失败回滚恢复操作前的状态。
   - 安全检查发生在资源加载、执行或写入之前。
   - 重定向不得把认证信息泄露给不同 origin，审计不得保留 URL 中的密码。
   - 破坏性操作完整检查依赖，保护路径在所有写入入口执行一致策略。
2. **补充能覆盖消费者可见缺陷的回归测试。**
   - 覆盖生产默认配置、只读文件、无效资源子类、无绑定事件的失败回滚、GDScript preload 依赖、跨源重定向、URL 脱敏和拒绝输入前不得产生副作用。
   - 断言实际状态、文件内容及失败原子性，而不是仅断言返回值不报错。
3. **处理 Unix 进程树清理问题，并验证所声明的平台行为。**
4. **对修复后的同一提交完成本地门禁和远端 CI。**

## 6. 最终评价

**功能覆盖和工程门禁已有基础，但可靠性与安全边界仍有明确阻断项。`2fff8d1` 尚未达到合并主干标准，应保持 Request changes，完成上述准入条件后重新评价。**

本报告是评价结果的归档，不代表相关问题已经修复；本次文档落地也未修改实现、重新执行测试或执行合并。

> 整改后的实现与门禁证据见 [2026-10-04 合并审查整改与验证证据](2026-10-04-merge-readiness-remediation.md)。
