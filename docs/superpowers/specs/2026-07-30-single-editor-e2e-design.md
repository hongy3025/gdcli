# 单 Godot 实例 E2E 测试整合设计

## 背景与目标

当前 `tests/e2e/` 按里程碑分别创建项目副本、安装 addon 并启动 Godot editor。该隔离策略是历史遗留，不是验收目标的一部分，启动成本成为全量测试的主要耗时来源。

本设计将 M2–M6 合并到一个公共 E2E fixture，在一次 pytest session 中只启动一个 Godot editor，同时保留现有测试断言和验收语义。项目副本与 editor 进程不再按模块或用例隔离；共享状态通过显式 reset contract 管理。

### 优化策略

在“单 editor 启动”的基础上，通过测试用例收集顺序的调度进一步压缩 wall time。核心观察：

- 启动后立即跑快的契约/路由/编辑器状态测试（m2/test_m2_contract、m4 轻量级单测、test_unified_fixture_contract 等）能尽早把失败抛出来，pytest 的 `-x` 与开发者的调试循环也最先命中它们。
- 依赖 runtime probe 的 m3 测试以及 m6 长时间进程/导出测试，安排在生命周期中段。
- 启动需要重启游戏、重连 runtime、跑导出等较重路径的测试（m5/m6 的 export_android、m3 的 lifecycle scenario）排在收尾，避免与启动期并发。

具体做法：在 `tests/e2e/conftest.py` 中通过 `pytest_collection_modifyitems` 调整收集顺序，规则：

1. `test_unified_fixture_contract.*`、`test_shared_editor_lifecycle.*`、`test_shared_editor_contract.*` 优先进入执行队列（这些不依赖 editor）。
2. M2 / M4 轻量路由 + 场景 / 节点 / 信号测试随后。
3. M3 依赖 `m3_running` 的测试（runtime_input / runtime_nodes / runtime_assert_signal）其次。
4. M5 / M6 涉及导出、批量、network、process 的长尾测试最后。

该顺序不修改任何测试断言，仅在收集阶段重排。完整模块顺序与所有测试函数保持原样。


## 方案选择

采用“单一超级 fixture”。新增 `tests/fixtures/e2e_project/`，合并 M2–M6 的场景、资源、脚本、工具和测试插件。pytest 使用一个 session-scoped `e2e_editor`。

不采用运行前动态拼装（可复现性和冲突处理更复杂），也不采用同一进程热切换多个 Godot 项目（Godot editor 项目上下文和插件生命周期不支持稳定切换）。

## Fixture 结构

统一 fixture 包含：

- M2 的编辑器 UI、场景/资源/脚本、节点与信号素材；
- M3 的 runtime 场景、probe 脚本及输入/捕获/调试素材；
- M4 的动画、音频、导航、物理、渲染、TileMap、UI 素材；
- M5 的 UID、诊断、导出、快照和项目配置素材；
- M6 的批量文件、网络、进程、eval、运行时素材与工具脚本；
- `gdapi_test` 插件测试脚本。

统一使用一份 `project.godot`，默认启用所有测试所需能力。名称冲突在迁移时显式解决，测试通过统一的 `res://` 路径访问素材。

## 生命周期与数据流

```text
session setup
  build workspace -> copy e2e_project to temp dir -> install addon
  -> start one Godot editor -> wait for metadata and gdapi ping
  -> expose shared env

each test
  pre-reset -> test commands -> post-reset/assert baseline

session teardown
  stop running game -> remove runtime transport -> stop editor
```

`e2e_editor` 是唯一创建 `Popen` 的 fixture。M2–M6 的 `conftest.py` 保留兼容 fixture 名称，但只返回同一个环境对象，不得创建进程、项目副本或重复 build/install。

## 状态复位 contract

每个测试开始前停止运行中的游戏，清理 runtime transport、审计日志、编辑器选择和临时策略覆盖。文件测试使用专用工作目录，结束时删除生成文件并恢复基线；场景测试重新加载基准场景并显式恢复修改；运行时测试调用统一 reset hook 清空节点、输入、捕获和状态缓存。

任何 reset 失败都立即使测试失败，并附带 Godot 日志尾部和 runtime 状态。测试正确性不得依赖 pytest 收集顺序。

## Capability policy

统一 fixture 默认使用全能力策略。拒绝路径测试使用 `temporary_policy(env, override)` 上下文管理器：原子写入覆盖、通知 gdapi 重载、执行断言、无论成功失败均恢复默认策略，并验证恢复后的 capability 状态。策略切换不得启动第二个 editor。

## 迁移与兼容性

尽量保留现有测试函数和断言，仅替换 fixture 注入与项目路径引用。保留 `m2_editor`、`m4_env`、`m6_editor_*` 等名称作为 session-scoped 兼容别名，全部返回同一环境。原有分模块 fixture 目录可作为迁移素材保留，但测试不再直接依赖它们。

新增契约断言：所有模块 fixture 观察到相同 editor PID、项目路径和 gdapi metadata。

## 错误处理

启动阶段在 metadata、ping 或 Godot 提前退出时失败，并保留日志；reset 阶段失败包含 reset 阶段名、命令、runtime 状态和日志尾部；策略恢复失败阻止后续测试继续执行，避免污染共享环境。

## 验收与测试

- 全量 `tests/e2e/` 期间 Godot editor 启动次数恰好为 1；
- M2–M6 观察到的 editor PID 相同；
- 全量测试断言保持不变，重复运行结果一致；
- 现有 6 分钟预算测试继续通过并记录新的耗时基线；
- 新增共享 fixture 生命周期、PID 一致性、reset 失败诊断和策略恢复测试。

### 收集顺序优化验收

- 不增加测试用例（仍是同一集合）；
- 启动后前 30 秒应至少出现一个稳定通过的契约/路由子集；
- 慢路径测试（export_android、m3 完整 lifecycle、m6 进程/网络）显式被推到收集顺序尾部；
- 全量 wall time 在新基线建立后记录并跟踪该指标（应低于 6 分钟预算基线）。

