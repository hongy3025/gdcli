# E2E 每用例 wall time 占比统计

## 本轮测量与口径

- **父进程实测 wall time：401.415899 秒**，从 pytest 子进程启动前到退出后，用 monotonic 时钟测量。
- **639 个执行 case：637 passed、1 failed、1 skipped；4 deselected；编辑器启动 1 次**。参数化用例逐个展开。
- 这是新的完整采样，不是此前 353.07 秒的全绿会话。本轮存在一次网络连接失败；不能把本轮占比套到旧会话，或宣称本轮是健康性能基准。
- 保持 file transport、headless、测试选择、隔离、超时和重投次数不变；未并行运行 pytest。仅加用一次性被动 pytest report hook 与 Python 子进程审计事件计数。
- **每个 case 总耗时 = setup + call + teardown；占比 = case 总耗时 / 本轮父进程 wall time × 100%**。不是仅按测试函数 call 耗时排名。
- setup/teardown 包含函数、模块、会话级 fixture 的实际发生费用；共享编辑器启动计入首次触发它的 case，而不是均摊到所有 case。会话收尾同样计入实际触发的 teardown。此表用于成本归属，不表示某条断言本身的固有耗时。
- 缺少执行阶段的 skipped case 以该阶段 0 秒累计，但保留其实际发生的其他阶段与 skipped 状态；deselected case 无计时，不当作零耗时执行。
- GDScript 原生套件以各自的 pytest nodeid 计时，未拆分内部 GDScript 测试函数。
- 子进程启动次数仅计 Python harness 在 case 阶段直接启动的进程（审计事件），不是全部 Godot 进程树，也不代表全部为 gdcli；不据此推算纯启动成本。
- 使用 report.duration 的原始浮点精度汇总；表和 CSV 显示六位小数，舍入后各行百分比相加可能与原始汇总有细小差异。

原始数据及可筛选表：

- [完整 639 行 CSV](../../.pytest-artifacts/e2e-case-profile/cases.csv)
- [逐 case 原始分阶段 JSON](../../.pytest-artifacts/e2e-case-profile/case-phases.json)
- [汇总 JSON](../../.pytest-artifacts/e2e-case-profile/summary.json)
- [JUnit 独立计数校验](../../.pytest-artifacts/e2e-case-profile/cases.xml)
- [完整 pytest 输出与失败诊断](../../.pytest-artifacts/e2e-case-profile/pytest.log)
- [父进程会话记录](../../.pytest-artifacts/e2e-case-profile/session.json)

## 全部 wall time 的归属

| 阶段 | 秒 | 整轮占比 | case 阶段内直接启动的子进程数 |
|---|---:|---:|---:|
| 准备 / setup | 62.423190 | 15.5508% | 579 |
| 执行 / call | 268.920068 | 66.9929% | 2705 |
| 清理 / teardown | 66.881931 | 16.6615% | 1239 |
| 未归属到 case 的开销 | 3.190710 | 0.7949% | 不在上述计数口径内 |
| **合计** | **401.415899** | **100.0000%** | **4523** |

未归属开销不是按比例补给 case，而是单独保留：

| 细项 | 秒 | 说明 |
|---|---:|---|
| pytest 收集 | 0.337698 | 单独计时；不是测试函数执行 |
| pytest 会话内其他非 case 开销 | 1.871387 | hook、report、调度等合并残差；未逐项拆分 |
| pytest 会话开始前 / 结束后的子进程开销 | 0.981625 | 启动、导入及退出等合并差额；不包含已记入首个 case 的编辑器启动 |

## 为什么仍然需要数分钟

1. **隔离与 fixture 累计成本很大。** setup 与 teardown 合计 129.305 秒，占 32.21%。除首次共享编辑器初始化的 setup 25.744 秒外，其余 setup/teardown 仍合计 103.561 秒。它们包括文件基线恢复/校验、场景切换、审计和选择清理、模块生命周期等，不能全部归为文件 I/O 或纯进程启动。
2. **重复恢复在 M2/M4 尤其明显。** M2 teardown 42.318 秒，M4 teardown 10.672 秒，两者合计 52.990 秒。这两个阶段实际各记录 940 / 285 次直接子进程启动，共 1225 次。源码中的恢复流程每 case 通过 gdcli 执行关闭场景、打开基线场景、查询当前场景、清空选择、清空审计这五次往返；同时还有文件树及字节校验。
3. **不是只有最慢的几个 case。** 582 个总耗时 ≤ 1 秒的 case，累计 190.170 秒，占 47.37%。最慢 20 个仅占 38.92%。整轮 case 阶段观察到 4523 次直接子进程启动；本次没有拆分纯进程启动、HTTP 往返和编辑器处理各自的秒数。
4. **有必须等待真实时间的验收。** 生产默认期限用例等待真实 30 秒期限，并继续观察至 33.5 秒以验证无晚到副作用；6 秒输入序列用例必须覆盖超过 5 秒的真实执行。不能把这些时间简单压小后宣称保持原覆盖。
5. **有冷启动与重型真实操作。** 真实 PCK 导出会启动新的 Godot 导出子进程，并读取验证落盘文件。22 个 GDScript 套件分别用独立的 Godot --headless --script 进程运行，虽仍只有一个共享编辑器，却并不是只有一个 Godot 进程；route_doc 套件还扫描并实例化全部路由文档。
6. **重复的场景依赖扫描。** 名称以 test_scene_delete 开头的 12 个 case 共 25.465 秒，占 6.34%；这个统计包含它们的 fixture，不能全部当作扫描自身的耗时。删除服务每次从 res:// 遍历资源/脚本并做静态引用扫描，说明这组重复工作值得单独测量。
7. **本轮还有异常等待。** runtime/node/info 到 http://127.0.0.1:7890 的连接失败（Windows os error 10060）使共享运行时状态恢复用例失败；它的 call 为 22.675 秒、case 总计 22.778 秒，占 5.67%。这里只确认连接失败，没有证据把它归因于代理、编辑器卡顿或端口耗尽。不能直接扣掉整条 case 的耗时冒充新的健康 wall time。

这些项目相互包含，例如重型扫描已在 case call 内，恢复已在 setup/teardown 内；**原因清单不能与阶段表再次相加**。成功等待采样也嵌套在 case 内，不能重复计入总时间。

源码依据：

- [共享状态恢复](../../tests/e2e/shared_fixture.py#L488)、[文件基线恢复](../../tests/e2e/shared_fixture.py#L419)
- [M2 每 case 隔离](../../tests/e2e/m2/conftest.py#L38)、[M4 每 case 隔离](../../tests/e2e/m4/conftest.py#L57)、[M5 准备与恢复](../../tests/e2e/m5/conftest.py#L67)
- [真实生产默认期限验收](../../tests/e2e/m6/test_process_run.py#L114)、[6 秒输入序列](../../tests/e2e/m3/test_runtime_input.py#L164)
- [真实导出验收](../../tests/e2e/m5/test_export.py#L33)、[导出服务启动子进程](../../gdapi/addon/runtime/services/export_service.gd#L54)
- [原生 GDScript 套件](../../tests/e2e/test_gdscript_units.py#L8)、[独立进程 runner](../../tests/e2e/conftest.py#L198)、[全路由文档扫描](../../tests/fixtures/e2e_project/tests/test_route_doc.gd#L181)
- [场景删除依赖扫描](../../gdapi/addon/runtime/services/scene_editor.gd#L437)

## 按测试组汇总

该表与逐 case 表使用同一分母，没有把共享启动均摊到各模块。

| 组 | case 数 | setup 秒 | call 秒 | teardown 秒 | 合计秒 | 整轮占比 | 直接子进程启动数 |
|---|---:|---:|---:|---:|---:|---:|---:|
| M2 | 188 | 4.166697 | 66.530043 | 42.317767 | 113.014506 | 28.1540% | 1871 |
| M3 | 146 | 13.486849 | 68.660169 | 0.036881 | 82.183898 | 20.4735% | 974 |
| M6 | 82 | 3.346747 | 47.729587 | 6.265211 | 57.341545 | 14.2848% | 190 |
| M5 | 57 | 14.380252 | 32.116819 | 7.559327 | 54.056398 | 13.4664% | 556 |
| M4 | 57 | 1.212559 | 26.262323 | 10.672034 | 38.146916 | 9.5031% | 852 |
| 顶层合同与 harness（含首次共享编辑器初始化） | 87 | 25.820693 | 3.324727 | 0.024826 | 29.170246 | 7.2668% | 58 |
| GDScript 原生套件 | 22 | 0.009394 | 24.296400 | 0.005885 | 24.311679 | 6.0565% | 22 |

## 优化优先级（分析结论，未在本次统计中修改代码）

1. 先定位已记录的 runtime/node/info 连接失败，避免异常连接等待混入健康基准；不通过扩大超时隐藏问题。
2. 优先独立剖析重复隔离中的文件扫描与五次 CLI 往返，评估合并恢复流程的机会，同时保留文件、场景、选择和审计校验。
3. 单独剖析重复依赖扫描、导出冷启动与 GDScript 套件启动；任何缓存或合并都必须证明不漏掉新文件/外部修改及状态隔离。
4. 30 秒生产期限、6 秒输入序列属于现有验收语义，不作为直接缩短 sleep/期限的优化项。

## 全部 639 个已执行 case（按总耗时降序）

所有耗时单位为秒；占比和累计占比均以 401.415899 秒整轮 wall time 为分母。failed、skipped 也保留，不使用成功样本过滤。

| 排名 | pytest nodeid | 状态 | setup | call | teardown | 总计 | 整轮占比 | 累计占比 | 直接子进程启动数 | 备注 |
|---:|---|---|---:|---:|---:|---:|---:|---:|---:|---|
| 1 | `tests/e2e/m6/test_process_run.py::test_process_run_default_handler_deadline_prevents_late_side_effect_and_success_audit` | passed | 0.023295 | 33.549385 | 0.058796 | 33.631475 | 8.378212% | 8.378212% | 4 |  |
| 2 | `tests/e2e/test_shared_editor_contract.py::test_m2_alias_shares_e2e_editor` | passed | 25.744046 | 0.001023 | 0.000118 | 25.745187 | 6.413594% | 14.791806% | 8 | 首次共享编辑器初始化；一次性成本 |
| 3 | `tests/e2e/m5/test_export.py::test_export_run_overwrites_previous_artifact` | passed | 0.264136 | 22.970784 | 0.148874 | 23.383794 | 5.825328% | 20.617135% | 6 |  |
| 4 | `tests/e2e/m3/test_runtime_nodes.py::test_fixture_reset_restores_shared_runtime_state` | failed | 0.102185 | 22.675252 | 0.000422 | 22.777859 | 5.674379% | 26.291514% | 30 | 连接失败；非健康基准 |
| 5 | `tests/e2e/test_gdscript_units.py::test_gdscript_unit_suite[res://tests/test_route_doc.gd]` | passed | 0.000307 | 6.983740 | 0.000213 | 6.984261 | 1.739906% | 28.031420% | 1 |  |
| 6 | `tests/e2e/m3/test_runtime_input.py::test_input_sequence_over_five_seconds_honors_explicit_timeout` | passed | 0.075552 | 6.188729 | 0.000224 | 6.264505 | 1.560602% | 29.592022% | 5 |  |
| 7 | `tests/e2e/m4/test_audio_animation_extended.py::test_audio_bus_properties_effects_persist_and_undo` | passed | 0.021230 | 2.886671 | 0.275609 | 3.183509 | 0.793070% | 30.385092% | 26 |  |
| 8 | `tests/e2e/m6/test_process_run.py::test_process_timeout_is_enforced_during_editor_main_thread_stall` | passed | 0.020161 | 2.882941 | 0.058916 | 2.962018 | 0.737893% | 31.122985% | 10 |  |
| 9 | `tests/e2e/m3/test_runtime_status.py::test_runtime_status_initial_state_is_stopped` | passed | 2.961529 | 0.000203 | 0.000117 | 2.961850 | 0.737851% | 31.860835% | 36 |  |
| 10 | `tests/e2e/m2/test_editor_controls.py::test_scene_delete_rejects_script_preload_without_executing_script[res]` | passed | 0.019747 | 2.450201 | 0.483041 | 2.952988 | 0.735643% | 32.596478% | 13 |  |
| 11 | `tests/e2e/m2/test_editor_controls.py::test_scene_instance_link_ownership_undo_and_saved_reopen` | passed | 0.022417 | 2.485134 | 0.421246 | 2.928797 | 0.729616% | 33.326095% | 22 |  |
| 12 | `tests/e2e/m2/test_editor_controls.py::test_scene_delete_rejects_script_preload_without_executing_script[raw]` | passed | 0.024730 | 2.474120 | 0.429438 | 2.928288 | 0.729490% | 34.055585% | 13 |  |
| 13 | `tests/e2e/m2/test_editor_controls.py::test_scene_delete_rejects_script_preload_without_executing_script[load_relative]` | passed | 0.015757 | 2.251155 | 0.464977 | 2.731889 | 0.680563% | 34.736148% | 13 |  |
| 14 | `tests/e2e/m2/test_editor_controls.py::test_scene_delete_rejects_script_preload_without_executing_script[relative]` | passed | 0.024259 | 2.197801 | 0.340016 | 2.562076 | 0.638260% | 35.374408% | 13 |  |
| 15 | `tests/e2e/m2/test_editor_controls.py::test_scene_delete_dry_run_and_real_delete_both_reject_unsaved_scene` | passed | 0.016262 | 2.118061 | 0.377091 | 2.511413 | 0.625639% | 36.000047% | 15 |  |
| 16 | `tests/e2e/m2/test_editor_controls.py::test_scene_delete_rejects_script_preload_without_executing_script[uid]` | passed | 0.016143 | 1.984944 | 0.507334 | 2.508421 | 0.624893% | 36.624940% | 13 |  |
| 17 | `tests/e2e/m3/test_runtime_extensions.py::test_tween_intermediate_completion_and_cancellation` | passed | 0.078122 | 2.392192 | 0.000236 | 2.470550 | 0.615459% | 37.240399% | 25 |  |
| 18 | `tests/e2e/m2/test_editor_controls.py::test_scene_delete_rejects_script_preload_without_executing_script[escaped]` | passed | 0.018990 | 2.090796 | 0.336613 | 2.446399 | 0.609442% | 37.849841% | 13 |  |
| 19 | `tests/e2e/m3/test_audit_concurrency.py::test_concurrent_runtime_mutations_keep_one_final_audit_each` | passed | 1.649111 | 0.545040 | 0.000213 | 2.194364 | 0.546656% | 38.396497% | 28 |  |
| 20 | `tests/e2e/m6/test_process_run.py::test_process_run_client_disconnect_cancels_and_audits_failure` | passed | 0.023337 | 1.995386 | 0.072374 | 2.091097 | 0.520930% | 38.917427% | 2 |  |
| 21 | `tests/e2e/m2/test_scene_batch.py::test_two_unopened_scenes_apply_reload_recover` | passed | 0.013962 | 1.728327 | 0.158496 | 1.900785 | 0.473520% | 39.390948% | 33 |  |
| 22 | `tests/e2e/m2/test_editor_controls.py::test_scene_delete_dry_run_protection_and_open_conflict` | passed | 0.023847 | 1.496251 | 0.380137 | 1.900235 | 0.473383% | 39.864331% | 12 |  |
| 23 | `tests/e2e/m3/test_runtime_assert_signal.py::test_transport_disconnect_completes_await_once_and_cleans_late_runtime_work` | passed | 0.067875 | 1.763139 | 0.000232 | 1.831246 | 0.456197% | 40.320527% | 32 |  |
| 24 | `tests/e2e/m4/test_audio_animation_extended.py::test_audio_send_cycles_and_invalid_effects_are_atomic` | passed | 0.017217 | 1.505876 | 0.291000 | 1.814093 | 0.451923% | 40.772451% | 36 |  |
| 25 | `tests/e2e/m3/test_runtime_capture.py::test_real_high_entropy_single_frame_fits_then_cumulative_reply_is_rejected` | passed | 0.064506 | 1.728876 | 0.000277 | 1.793658 | 0.446833% | 41.219284% | 9 |  |
| 26 | `tests/e2e/m4/test_navigation.py::test_navigation_runtime_round_trip_is_2d_and_cleans_up` | passed | 0.025022 | 1.588654 | 0.171909 | 1.785584 | 0.444821% | 41.664105% | 24 |  |
| 27 | `tests/e2e/m4/test_m4_game_bridge.py::test_physics_raycast_round_trip_requires_running_domain` | passed | 0.018087 | 1.544251 | 0.179165 | 1.741503 | 0.433840% | 42.097945% | 20 |  |
| 28 | `tests/e2e/m4/test_m4_game_bridge.py::test_navigation_path_and_agent_target_round_trip` | passed | 0.021101 | 1.501529 | 0.215374 | 1.738004 | 0.432968% | 42.530914% | 20 |  |
| 29 | `tests/e2e/m2/test_scene_batch.py::test_binary_scene_scans_mutates_and_recovers` | passed | 0.021911 | 1.067108 | 0.588973 | 1.677993 | 0.418018% | 42.948932% | 13 |  |
| 30 | `tests/e2e/m2/test_scene_batch.py::test_single_scene_multi_property_and_instance_override` | passed | 0.033219 | 1.022271 | 0.619866 | 1.675356 | 0.417362% | 43.366294% | 18 |  |
| 31 | `tests/e2e/m3/test_runtime_extensions.py::test_tween_invalid_requests_conflicts_and_target_cleanup` | passed | 0.062385 | 1.609677 | 0.000249 | 1.672312 | 0.416603% | 43.782897% | 36 |  |
| 32 | `tests/e2e/m2/test_resource_routes.py::test_resource_assign_custom_script_inheritance_multiple_hints_and_setter_rejection` | passed | 0.017343 | 1.498137 | 0.154081 | 1.669560 | 0.415918% | 44.198815% | 35 |  |
| 33 | `tests/e2e/m3/test_runtime_nodes.py::test_runtime_infrastructure_nodes_reject_mutations` | passed | 0.094299 | 1.572792 | 0.000341 | 1.667432 | 0.415388% | 44.614203% | 41 |  |
| 34 | `tests/e2e/m2/test_editor_controls.py::test_scene_delete_save_as_dirty_current_scene_is_refused` | passed | 0.018828 | 1.347378 | 0.251427 | 1.617632 | 0.402982% | 45.017185% | 12 |  |
| 35 | `tests/e2e/m2/test_scene_batch.py::test_recovery_backup_corruption_does_not_restore_first_scene` | passed | 0.022704 | 0.922913 | 0.639265 | 1.584881 | 0.394823% | 45.412007% | 10 |  |
| 36 | `tests/e2e/m2/test_scene_batch.py::test_target_resource_hash_and_resource_replacement_recovery` | passed | 0.021252 | 0.980490 | 0.564697 | 1.566439 | 0.390229% | 45.802236% | 16 |  |
| 37 | `tests/e2e/m6/test_runtime_eval.py::test_runtime_eval_runs_only_in_game_process` | passed | 1.408284 | 0.070372 | 0.055188 | 1.533845 | 0.382109% | 46.184344% | 10 |  |
| 38 | `tests/e2e/m2/test_editor_controls.py::test_metadata_typed_undo_redo_remove_and_reopen` | passed | 0.019845 | 1.111036 | 0.256429 | 1.387311 | 0.345604% | 46.529949% | 23 |  |
| 39 | `tests/e2e/m2/test_scene_batch.py::test_recovery_conflict_and_mid_transaction_failure_leave_applied_state` | passed | 0.019604 | 0.798713 | 0.548163 | 1.366480 | 0.340415% | 46.870364% | 11 |  |
| 40 | `tests/e2e/m2/test_editor_controls.py::test_scene_delete_ignores_preload_text_in_comments_and_strings` | passed | 0.021992 | 0.874847 | 0.344397 | 1.241236 | 0.309214% | 47.179578% | 8 |  |
| 41 | `tests/e2e/m5/test_m5_smoke.py::test_m5_route_families_are_registered` | passed | 0.252029 | 0.788560 | 0.145727 | 1.186316 | 0.295533% | 47.475111% | 31 |  |
| 42 | `tests/e2e/m2/test_signal_group_routes.py::test_signal_disconnect_and_group_remove_persist` | passed | 0.019235 | 0.919676 | 0.229530 | 1.168441 | 0.291080% | 47.766191% | 22 |  |
| 43 | `tests/e2e/m2/test_script_routes.py::test_script_detach_survives_reopen` | passed | 0.022024 | 0.917154 | 0.226367 | 1.165545 | 0.290358% | 48.056550% | 20 |  |
| 44 | `tests/e2e/m3/test_runtime_extensions.py::test_record_real_input_reset_then_replay` | passed | 0.103691 | 1.051205 | 0.000245 | 1.155141 | 0.287767% | 48.344316% | 16 |  |
| 45 | `tests/e2e/m4/test_resource_theme_reads.py::test_theme_get_all_writable_domains_font_items_and_inheritance` | passed | 0.017811 | 0.970853 | 0.164329 | 1.152993 | 0.287232% | 48.631548% | 35 |  |
| 46 | `tests/e2e/m6/test_network_request.py::test_network_request_unreachable_host` | passed | 0.030019 | 1.062078 | 0.056159 | 1.148256 | 0.286051% | 48.917599% | 2 |  |
| 47 | `tests/e2e/m6/test_audit_concurrency.py::test_concurrent_process_network_and_mutation_audit_once` | passed | 0.026020 | 0.866029 | 0.234590 | 1.126639 | 0.280666% | 49.198265% | 8 |  |
| 48 | `tests/e2e/m4/test_resource_theme_reads.py::test_resource_typed_property_disk_roundtrip_and_rejected_writes` | passed | 0.019918 | 0.946015 | 0.157718 | 1.123651 | 0.279922% | 49.478187% | 24 |  |
| 49 | `tests/e2e/test_gdscript_units.py::test_gdscript_unit_suite[res://tests/test_runtime_route.gd]` | passed | 0.000470 | 1.095377 | 0.000218 | 1.096065 | 0.273050% | 49.751237% | 1 |  |
| 50 | `tests/e2e/m2/test_spatial_particles.py::test_each_spatial_construct_configured_undo_redo_and_persistent[OmniLight3D-properties1]` | passed | 0.022949 | 0.820686 | 0.243884 | 1.087519 | 0.270921% | 50.022158% | 16 |  |
| 51 | `tests/e2e/test_gdscript_units.py::test_gdscript_unit_suite[res://tests/test_runtime_transport_file_probe.gd]` | passed | 0.000501 | 1.075469 | 0.000323 | 1.076294 | 0.268124% | 50.290282% | 1 |  |
| 52 | `tests/e2e/m2/test_editor_controls.py::test_scene_delete_retains_scene_and_resource_dependencies[tres]` | passed | 0.020256 | 0.851005 | 0.203658 | 1.074919 | 0.267782% | 50.558064% | 8 |  |
| 53 | `tests/e2e/m4/test_audio_animation_extended.py::test_blend_tree_authoring_serialization_and_undo` | passed | 0.022151 | 0.854920 | 0.176726 | 1.053797 | 0.262520% | 50.820584% | 28 |  |
| 54 | `tests/e2e/test_gdscript_units.py::test_gdscript_unit_suite[res://tests/test_runtime_broker.gd]` | passed | 0.000541 | 1.020130 | 0.000386 | 1.021057 | 0.254364% | 51.074948% | 1 |  |
| 55 | `tests/e2e/m4/test_audio_animation_extended.py::test_animation_state_removal_cleans_transitions_and_undo` | passed | 0.018283 | 0.830524 | 0.167303 | 1.016109 | 0.253131% | 51.328079% | 25 |  |
| 56 | `tests/e2e/m2/test_resource_routes.py::test_typed_properties_round_trip_and_survive_reopen` | passed | 0.023300 | 0.808203 | 0.182050 | 1.013553 | 0.252495% | 51.580574% | 19 |  |
| 57 | `tests/e2e/test_gdscript_units.py::test_gdscript_unit_suite[res://tests/test_runtime_transport_integration.gd]` | passed | 0.000630 | 1.001500 | 0.000280 | 1.002409 | 0.249718% | 51.830292% | 1 |  |
| 58 | `tests/e2e/m2/test_editor_controls.py::test_scene_delete_retains_scene_and_resource_dependencies[tscn]` | passed | 0.019196 | 0.806478 | 0.164175 | 0.989849 | 0.246589% | 52.076882% | 8 |  |
| 59 | `tests/e2e/m2/test_resource_routes.py::test_resource_assign_checks_subclass_and_preserves_undo_redo_on_rejection` | passed | 0.016632 | 0.814387 | 0.154561 | 0.985580 | 0.245526% | 52.322407% | 19 |  |
| 60 | `tests/e2e/test_gdscript_units.py::test_gdscript_unit_suite[res://tests/test_runtime_transport_file_editor.gd]` | passed | 0.000373 | 0.979042 | 0.000222 | 0.979637 | 0.244045% | 52.566453% | 1 |  |
| 61 | `tests/e2e/m2/test_spatial_particles.py::test_each_spatial_construct_configured_undo_redo_and_persistent[SpotLight3D-properties2]` | passed | 0.026781 | 0.742375 | 0.203400 | 0.972555 | 0.242281% | 52.808734% | 16 |  |
| 62 | `tests/e2e/m3/test_runtime_input.py::test_input_validation_rejects_without_mutation[runtime/input/touch-payload6]` | passed | 0.074955 | 0.890678 | 0.000316 | 0.965949 | 0.240636% | 53.049370% | 14 |  |
| 63 | `tests/e2e/m3/test_runtime_assert_signal.py::test_signal_routes_reject_empty_signal_duplicate_connect_and_bad_emit_args` | passed | 0.105982 | 0.856902 | 0.000180 | 0.963064 | 0.239917% | 53.289286% | 22 |  |
| 64 | `tests/e2e/test_gdscript_units.py::test_gdscript_unit_suite[res://tests/test_runtime_capture_ops.gd]` | passed | 0.000397 | 0.948586 | 0.000362 | 0.949345 | 0.236499% | 53.525786% | 1 |  |
| 65 | `tests/e2e/m2/test_scene_editor.py::test_scene_current_save_overwrites_existing_without_force[tscn]` | passed | 0.018801 | 0.723003 | 0.206853 | 0.948656 | 0.236327% | 53.762113% | 13 |  |
| 66 | `tests/e2e/test_gdscript_units.py::test_gdscript_unit_suite[res://tests/test_runtime_protocol.gd]` | passed | 0.000529 | 0.930469 | 0.000693 | 0.931691 | 0.232101% | 53.994214% | 1 |  |
| 67 | `tests/e2e/m2/test_scene_editor.py::test_scene_current_save_overwrites_existing_without_force[scn]` | passed | 0.021618 | 0.682523 | 0.221546 | 0.925686 | 0.230605% | 54.224820% | 13 |  |
| 68 | `tests/e2e/m2/test_spatial_particles.py::test_each_spatial_construct_configured_undo_redo_and_persistent[CSGMesh3D-properties9]` | passed | 0.022245 | 0.707068 | 0.188688 | 0.918001 | 0.228691% | 54.453510% | 16 |  |
| 69 | `tests/e2e/m5/test_uid_repair.py::test_uid_repair_broad_scan_skips_protected_files_and_deduplicates_roots` | passed | 0.223162 | 0.487043 | 0.205025 | 0.915230 | 0.228000% | 54.681511% | 9 |  |
| 70 | `tests/e2e/m5/test_project_config_routes.py::test_project_config_removals_succeed_without_force` | passed | 0.224838 | 0.572686 | 0.111849 | 0.909372 | 0.226541% | 54.908052% | 16 |  |
| 71 | `tests/e2e/test_collection_order.py::test_collection_modifyitems_runs_during_real_collect` | passed | 0.000069 | 0.903634 | 0.000203 | 0.903907 | 0.225180% | 55.133232% | 1 |  |
| 72 | `tests/e2e/m2/test_spatial_particles.py::test_each_spatial_construct_configured_undo_redo_and_persistent[DirectionalLight3D-properties0]` | passed | 0.023680 | 0.666687 | 0.212546 | 0.902913 | 0.224932% | 55.358164% | 16 |  |
| 73 | `tests/e2e/m4/test_animation.py::test_animation_track_and_key_persist_after_reopen` | passed | 0.022446 | 0.668416 | 0.209120 | 0.899982 | 0.224202% | 55.582366% | 22 |  |
| 74 | `tests/e2e/test_gdscript_units.py::test_gdscript_unit_suite[res://tests/test_audit_retention.gd]` | passed | 0.000566 | 0.892374 | 0.000236 | 0.893176 | 0.222506% | 55.804872% | 1 |  |
| 75 | `tests/e2e/m3/test_runtime_input.py::test_input_validation_rejects_without_mutation[runtime/input/gamepad-payload5]` | passed | 0.078268 | 0.813701 | 0.000308 | 0.892277 | 0.222283% | 56.027154% | 14 |  |
| 76 | `tests/e2e/m2/test_spatial_particles.py::test_each_spatial_construct_configured_undo_redo_and_persistent[CSGCombiner3D-properties10]` | passed | 0.025308 | 0.701579 | 0.159608 | 0.886495 | 0.220842% | 56.247996% | 16 |  |
| 77 | `tests/e2e/m3/test_runtime_input.py::test_transport_disconnect_completes_sequence_once_with_zero_pending` | passed | 0.072422 | 0.790803 | 0.000257 | 0.863482 | 0.215109% | 56.463105% | 9 |  |
| 78 | `tests/e2e/m4/test_audio_animation_extended.py::test_blend_tree_invalid_graph_and_parameters_are_atomic` | passed | 0.020978 | 0.694798 | 0.142722 | 0.858498 | 0.213868% | 56.676973% | 36 |  |
| 79 | `tests/e2e/m2/test_spatial_particles.py::test_each_spatial_construct_configured_undo_redo_and_persistent[CSGPolygon3D-properties8]` | passed | 0.017903 | 0.630970 | 0.204407 | 0.853281 | 0.212568% | 56.889541% | 16 |  |
| 80 | `tests/e2e/m2/test_spatial_particles.py::test_each_spatial_construct_configured_undo_redo_and_persistent[CSGTorus3D-properties7]` | passed | 0.022144 | 0.668773 | 0.159390 | 0.850307 | 0.211827% | 57.101368% | 16 |  |
| 81 | `tests/e2e/test_gdscript_units.py::test_gdscript_unit_suite[res://tests/test_audit_log_redaction.gd]` | passed | 0.000641 | 0.843692 | 0.000267 | 0.844600 | 0.210405% | 57.311773% | 1 |  |
| 82 | `tests/e2e/m2/test_resource_routes.py::test_resource_assign_persists_across_save_and_reopen` | passed | 0.022201 | 0.653269 | 0.168391 | 0.843861 | 0.210221% | 57.521994% | 13 |  |
| 83 | `tests/e2e/test_gdscript_units.py::test_gdscript_unit_suite[res://tests/test_runtime_ring_buffer.gd]` | passed | 0.000376 | 0.836845 | 0.000262 | 0.837484 | 0.208632% | 57.730626% | 1 |  |
| 84 | `tests/e2e/m4/test_audio.py::test_audio_bus_add_and_remove_require_safe_semantics` | passed | 0.018145 | 0.591543 | 0.226297 | 0.835986 | 0.208259% | 57.938886% | 11 |  |
| 85 | `tests/e2e/m2/test_spatial_particles.py::test_each_spatial_construct_configured_undo_redo_and_persistent[Camera3D-properties3]` | passed | 0.021824 | 0.632296 | 0.178509 | 0.832630 | 0.207423% | 58.146309% | 16 |  |
| 86 | `tests/e2e/m3/test_runtime_extensions.py::test_monitor_real_cross_frame_typed_changes_cursor_stop_and_reset` | passed | 0.075776 | 0.756072 | 0.000180 | 0.832028 | 0.207273% | 58.353582% | 15 |  |
| 87 | `tests/e2e/m5/test_code_analysis.py::test_project_statistics_use_source_bytes_and_loader_types` | passed | 0.236758 | 0.468696 | 0.124171 | 0.829625 | 0.206675% | 58.560257% | 9 |  |
| 88 | `tests/e2e/m3/test_runtime_input.py::test_input_validation_rejects_without_mutation[runtime/input/mouse-payload2]` | passed | 0.064860 | 0.760304 | 0.000426 | 0.825590 | 0.205669% | 58.765926% | 14 |  |
| 89 | `tests/e2e/m5/test_project_config_routes.py::test_input_map_save_failure_restores_exact_action_and_setting[project/input_map/action/remove-None-keys5]` | passed | 0.358213 | 0.281525 | 0.185510 | 0.825248 | 0.205584% | 58.971510% | 17 |  |
| 90 | `tests/e2e/m4/test_navigation.py::test_navigation_regions_bake_to_project_local_resource` | passed | 0.022458 | 0.560424 | 0.237973 | 0.820855 | 0.204490% | 59.176000% | 16 |  |
| 91 | `tests/e2e/m3/test_runtime_input.py::test_input_validation_rejects_without_mutation[runtime/input/gamepad-payload4]` | passed | 0.068004 | 0.751689 | 0.000259 | 0.819951 | 0.204265% | 59.380265% | 14 |  |
| 92 | `tests/e2e/test_gdscript_units.py::test_runtime_debugger_plugin_suite` | passed | 0.000301 | 0.819191 | 0.000183 | 0.819675 | 0.204196% | 59.584461% | 1 |  |
| 93 | `tests/e2e/m3/test_runtime_input.py::test_input_validation_rejects_without_mutation[runtime/input/mouse-payload3]` | passed | 0.104329 | 0.714284 | 0.000265 | 0.818878 | 0.203997% | 59.788459% | 14 |  |
| 94 | `tests/e2e/m3/test_runtime_nodes.py::test_nested_runtime_node_named_like_fixture_remains_mutable` | passed | 0.087706 | 0.729327 | 0.000481 | 0.817514 | 0.203658% | 59.992116% | 13 |  |
| 95 | `tests/e2e/m3/test_runtime_input.py::test_input_sequence_prevalidates_every_event_before_execution[invalid_entry1]` | passed | 0.069214 | 0.747508 | 0.000277 | 0.817000 | 0.203530% | 60.195646% | 14 |  |
| 96 | `tests/e2e/test_gdscript_units.py::test_gdscript_unit_suite[res://tests/test_eval_service.gd]` | passed | 0.000358 | 0.811093 | 0.000306 | 0.811757 | 0.202223% | 60.397869% | 1 |  |
| 97 | `tests/e2e/m2/test_spatial_particles.py::test_each_spatial_construct_configured_undo_redo_and_persistent[CSGCylinder3D-properties6]` | passed | 0.017933 | 0.594345 | 0.193299 | 0.805577 | 0.200684% | 60.598553% | 16 |  |
| 98 | `tests/e2e/m4/test_audio.py::test_audio_play_and_stop_expose_real_player_state` | passed | 0.018590 | 0.635297 | 0.143404 | 0.797290 | 0.198620% | 60.797173% | 14 |  |
| 99 | `tests/e2e/m2/test_spatial_particles.py::test_particles_configuration_material_draw_resources_undo_and_persistence[GPUParticles3D]` | passed | 0.021277 | 0.566022 | 0.206412 | 0.793711 | 0.197728% | 60.994900% | 14 |  |
| 100 | `tests/e2e/m3/test_runtime_input.py::test_input_validation_rejects_without_mutation[runtime/input/key-payload0]` | passed | 0.067243 | 0.724432 | 0.000251 | 0.791926 | 0.197283% | 61.192184% | 14 |  |
| 101 | `tests/e2e/m2/test_scene_editor.py::test_save_as_read_only_failure_preserves_disk_path_and_unsaved_changes` | passed | 0.021091 | 0.589978 | 0.175605 | 0.786673 | 0.195975% | 61.388158% | 15 |  |
| 102 | `tests/e2e/m3/test_runtime_input.py::test_input_sequence_prevalidates_every_event_before_execution[invalid_entry0]` | passed | 0.068120 | 0.718180 | 0.000267 | 0.786567 | 0.195948% | 61.584106% | 14 |  |
| 103 | `tests/e2e/m3/test_runtime_input.py::test_input_validation_rejects_without_mutation[runtime/input/action-payload1]` | passed | 0.065108 | 0.719722 | 0.000296 | 0.785126 | 0.195589% | 61.779695% | 14 |  |
| 104 | `tests/e2e/m2/test_spatial_particles.py::test_each_spatial_construct_configured_undo_redo_and_persistent[CSGSphere3D-properties5]` | passed | 0.024099 | 0.595203 | 0.157663 | 0.776966 | 0.193556% | 61.973252% | 16 |  |
| 105 | `tests/e2e/m3/test_runtime_input.py::test_input_action_counts_false_to_true_edges_once` | passed | 0.103617 | 0.666385 | 0.000277 | 0.770279 | 0.191890% | 62.165142% | 10 |  |
| 106 | `tests/e2e/m3/test_runtime_input.py::test_input_sequence_prevalidates_every_event_before_execution[invalid_entry2]` | passed | 0.068099 | 0.690951 | 0.000246 | 0.759296 | 0.189154% | 62.354297% | 14 |  |
| 107 | `tests/e2e/m2/test_scene_batch.py::test_unsaved_open_scene_is_rejected_without_losing_editor_changes` | passed | 0.022539 | 0.524651 | 0.208071 | 0.755261 | 0.188149% | 62.542446% | 13 |  |
| 108 | `tests/e2e/m2/test_fixture_isolation.py::test_digests_are_stable_across_runs` | passed | 0.027379 | 0.458437 | 0.269147 | 0.754962 | 0.188075% | 62.730521% | 5 |  |
| 109 | `tests/e2e/m4/test_resource_theme_reads.py::test_texture_preview_resizes_real_pixels_and_common_resource_preview` | passed | 0.017918 | 0.582422 | 0.153296 | 0.753636 | 0.187745% | 62.918265% | 19 |  |
| 110 | `tests/e2e/m5/test_project_config_routes.py::test_project_config_round_trip_restores_snapshot` | passed | 0.221675 | 0.424306 | 0.106727 | 0.752709 | 0.187513% | 63.105778% | 11 |  |
| 111 | `tests/e2e/m4/test_rendering.py::test_canvas_material_is_edited_with_undo_and_persists_assignment` | passed | 0.015933 | 0.533475 | 0.201442 | 0.750850 | 0.187050% | 63.292829% | 16 |  |
| 112 | `tests/e2e/m2/test_scene_editor.py::test_scene_save_verification_reads_external_resource_from_disk` | passed | 0.022517 | 0.548284 | 0.176568 | 0.747369 | 0.186183% | 63.479012% | 10 |  |
| 113 | `tests/e2e/m4/test_rendering.py::test_material_files_are_saved_and_assigned_with_stable_paths` | passed | 0.020457 | 0.552249 | 0.172144 | 0.744850 | 0.185556% | 63.664568% | 15 |  |
| 114 | `tests/e2e/m2/test_spatial_particles.py::test_each_spatial_construct_configured_undo_redo_and_persistent[CSGBox3D-properties4]` | passed | 0.018688 | 0.559489 | 0.163698 | 0.741874 | 0.184814% | 63.849382% | 16 |  |
| 115 | `tests/e2e/test_gdscript_units.py::test_gdscript_unit_suite[res://tests/test_runtime_reparent.gd]` | passed | 0.000342 | 0.733968 | 0.000223 | 0.734534 | 0.182986% | 64.032368% | 1 |  |
| 116 | `tests/e2e/m6/test_network_request.py::test_client_disconnect_cancels_network_request` | passed | 0.026772 | 0.631177 | 0.071175 | 0.729125 | 0.181638% | 64.214006% | 3 |  |
| 117 | `tests/e2e/m5/test_project_config_routes.py::test_input_map_save_failure_restores_exact_action_and_setting[project/input_map/bind-90-keys4]` | passed | 0.277271 | 0.279860 | 0.170517 | 0.727648 | 0.181270% | 64.395276% | 17 |  |
| 118 | `tests/e2e/m2/test_spatial_particles.py::test_environment_sky_material_configuration_persists_and_is_undoable` | passed | 0.019721 | 0.544759 | 0.155383 | 0.719863 | 0.179331% | 64.574607% | 14 |  |
| 119 | `tests/e2e/m2/test_scene_editor.py::test_scene_save_probe_preserves_existing_temp_name` | passed | 0.026704 | 0.446410 | 0.240570 | 0.713684 | 0.177792% | 64.752399% | 10 |  |
| 120 | `tests/e2e/m5/test_project_config_routes.py::test_input_map_and_autoload_are_persisted_to_project_file` | passed | 0.229459 | 0.359363 | 0.120608 | 0.709430 | 0.176732% | 64.929131% | 7 |  |
| 121 | `tests/e2e/m2/test_mutation_audit.py::test_audit_retains_protected_entries_during_normal_traffic` | passed | 0.021228 | 0.459333 | 0.224990 | 0.705551 | 0.175765% | 65.104896% | 17 |  |
| 122 | `tests/e2e/m5/test_project_config_routes.py::test_unwritable_project_file_fails_and_rolls_back` | passed | 0.237987 | 0.356378 | 0.109162 | 0.703527 | 0.175261% | 65.280158% | 14 |  |
| 123 | `tests/e2e/m2/test_spatial_particles.py::test_particles_configuration_material_draw_resources_undo_and_persistence[GPUParticles2D]` | passed | 0.019524 | 0.506632 | 0.175666 | 0.701821 | 0.174836% | 65.454994% | 14 |  |
| 124 | `tests/e2e/test_gdscript_units.py::test_gdscript_unit_suite[res://tests/test_deferred_task_registry.gd]` | passed | 0.000362 | 0.696731 | 0.000248 | 0.697341 | 0.173720% | 65.628714% | 1 |  |
| 125 | `tests/e2e/m2/test_resource_routes.py::test_resource_overwrite_refreshes_cache_for_assign_and_read` | passed | 0.023016 | 0.513811 | 0.156804 | 0.693631 | 0.172796% | 65.801510% | 12 |  |
| 126 | `tests/e2e/test_gdscript_units.py::test_gdscript_unit_suite[res://tests/test_scene_editor_tab_mapping.gd]` | passed | 0.000400 | 0.692044 | 0.000226 | 0.692669 | 0.172556% | 65.974067% | 1 |  |
| 127 | `tests/e2e/test_gdscript_units.py::test_gdscript_unit_suite[res://tests/test_variant_codec.gd]` | passed | 0.000455 | 0.689345 | 0.000243 | 0.690044 | 0.171902% | 66.145969% | 1 |  |
| 128 | `tests/e2e/test_gdscript_units.py::test_gdscript_unit_suite[res://tests/test_request.gd]` | passed | 0.000311 | 0.688063 | 0.000174 | 0.688549 | 0.171530% | 66.317499% | 1 |  |
| 129 | `tests/e2e/test_gdscript_units.py::test_gdscript_unit_suite[res://tests/test_network_target_guard.gd]` | passed | 0.000403 | 0.684866 | 0.000215 | 0.685485 | 0.170767% | 66.488266% | 1 |  |
| 130 | `tests/e2e/test_gdscript_units.py::test_gdscript_unit_suite[res://tests/test_router.gd]` | passed | 0.000388 | 0.684007 | 0.000204 | 0.684600 | 0.170546% | 66.658812% | 1 |  |
| 131 | `tests/e2e/m6/test_network_request.py::test_failed_request_is_audited_as_failure` | passed | 0.023935 | 0.586580 | 0.071980 | 0.682496 | 0.170022% | 66.828834% | 3 |  |
| 132 | `tests/e2e/m5/test_project_config_routes.py::test_input_map_save_failure_restores_exact_action_and_setting[project/input_map/unbind-66-keys2]` | passed | 0.252331 | 0.276348 | 0.153752 | 0.682432 | 0.170006% | 66.998841% | 17 |  |
| 133 | `tests/e2e/m4/test_ui.py::test_button_text_and_anchor_use_undo_redo` | passed | 0.021959 | 0.474941 | 0.177106 | 0.674006 | 0.167907% | 67.166748% | 13 |  |
| 134 | `tests/e2e/m5/test_project_config_routes.py::test_input_map_save_failure_restores_exact_action_and_setting[project/input_map/bind-66-keys3]` | passed | 0.238953 | 0.291338 | 0.142974 | 0.673265 | 0.167723% | 67.334470% | 17 |  |
| 135 | `tests/e2e/m2/test_editor_controls.py::test_plugin_lifecycle_reloads_a_real_editor_plugin` | passed | 0.026797 | 0.383053 | 0.262443 | 0.672292 | 0.167480% | 67.501951% | 14 |  |
| 136 | `tests/e2e/m2/test_scene_editor.py::test_save_as_persists_editor_pre_save_notifications` | passed | 0.019926 | 0.476228 | 0.176035 | 0.672189 | 0.167455% | 67.669405% | 14 |  |
| 137 | `tests/e2e/m4/test_animation.py::test_history_result_recovers_after_reader_releases_file` | passed | 0.023343 | 0.487498 | 0.160007 | 0.670848 | 0.167120% | 67.836526% | 18 |  |
| 138 | `tests/e2e/m5/test_uid_repair.py::test_uid_repair_restores_all_target_bytes_when_late_resource_is_invalid` | passed | 0.343328 | 0.193439 | 0.127365 | 0.664133 | 0.165448% | 68.001973% | 8 |  |
| 139 | `tests/e2e/m6/test_network_request.py::test_timeout_returns_timeout_code` | passed | 0.020979 | 0.580768 | 0.061149 | 0.662896 | 0.165139% | 68.167113% | 2 |  |
| 140 | `tests/e2e/m4/test_animation.py::test_animation_key_removal_undo_redo_and_invalid_value` | passed | 0.022354 | 0.378001 | 0.259413 | 0.659768 | 0.164360% | 68.331473% | 15 |  |
| 141 | `tests/e2e/m5/test_snapshot_restore.py::test_project_snapshot_restores_after_mutation` | passed | 0.284200 | 0.247995 | 0.119159 | 0.651354 | 0.162264% | 68.493737% | 5 |  |
| 142 | `tests/e2e/m2/test_node_editor.py::test_node_mutations_are_stepwise_undoable` | passed | 0.022801 | 0.392020 | 0.236202 | 0.651023 | 0.162182% | 68.655919% | 12 |  |
| 143 | `tests/e2e/m4/test_tilemap.py::test_tilemap_cell_set_is_undoable_and_persists` | passed | 0.018254 | 0.439331 | 0.189325 | 0.646910 | 0.161157% | 68.817075% | 15 |  |
| 144 | `tests/e2e/m5/test_project_config_routes.py::test_input_map_save_failure_restores_exact_action_and_setting[project/input_map/unbind-90-keys1]` | passed | 0.252191 | 0.262636 | 0.128705 | 0.643533 | 0.160316% | 68.977391% | 17 |  |
| 145 | `tests/e2e/m2/test_script_routes.py::test_script_attach_survives_reopen` | passed | 0.018015 | 0.463131 | 0.156069 | 0.637214 | 0.158742% | 69.136133% | 15 |  |
| 146 | `tests/e2e/m3/test_runtime_input.py::test_input_sequence_rejects_negative_after_ms` | passed | 0.066034 | 0.568066 | 0.000233 | 0.634333 | 0.158024% | 69.294157% | 14 |  |
| 147 | `tests/e2e/m3/test_runtime_capture.py::test_capture_deadline_stops_before_readback_and_transport_recovers` | passed | 0.101597 | 0.522402 | 0.000342 | 0.624342 | 0.155535% | 69.449692% | 8 |  |
| 148 | `tests/e2e/m5/test_project_config_routes.py::test_input_map_save_failure_restores_exact_action_and_setting[project/input_map/unbind-90-keys0]` | passed | 0.221441 | 0.180124 | 0.221206 | 0.622771 | 0.155144% | 69.604835% | 14 |  |
| 149 | `tests/e2e/m2/test_signal_group_routes.py::test_signal_and_group_persist` | passed | 0.017962 | 0.428839 | 0.174846 | 0.621647 | 0.154864% | 69.759699% | 15 |  |
| 150 | `tests/e2e/m3/test_runtime_input.py::test_input_sequence_rejects_cumulative_duration_over_ten_seconds` | passed | 0.063824 | 0.548249 | 0.000223 | 0.612296 | 0.152534% | 69.912233% | 14 |  |
| 151 | `tests/e2e/m5/test_classdb_routes.py::test_classdb_member_routes_preserve_not_found` | passed | 0.281282 | 0.189144 | 0.133818 | 0.604243 | 0.150528% | 70.062761% | 13 |  |
| 152 | `tests/e2e/test_gdscript_units.py::test_gdscript_unit_suite[res://tests/test_response_send.gd]` | passed | 0.000361 | 0.597046 | 0.000199 | 0.597607 | 0.148875% | 70.211635% | 1 |  |
| 153 | `tests/e2e/m2/test_script_routes.py::test_script_rejections_do_not_change_files[script/write-data1-permission_denied]` | passed | 0.028658 | 0.388205 | 0.180437 | 0.597301 | 0.148798% | 70.360434% | 6 |  |
| 154 | `tests/e2e/test_gdscript_units.py::test_gdscript_unit_suite[res://tests/test_path_guard.gd]` | passed | 0.000380 | 0.592822 | 0.000199 | 0.593401 | 0.147827% | 70.508261% | 1 |  |
| 155 | `tests/e2e/m2/test_script_routes.py::test_script_rejections_do_not_change_files[script/attach-data2-not_found]` | passed | 0.023179 | 0.391966 | 0.177270 | 0.592415 | 0.147581% | 70.655842% | 6 |  |
| 156 | `tests/e2e/m5/test_m5_smoke.py::test_m5_queries_uid_apply_and_safety_contracts` | passed | 0.242491 | 0.183547 | 0.165414 | 0.591452 | 0.147342% | 70.803184% | 10 |  |
| 157 | `tests/e2e/m2/test_script_routes.py::test_script_rejections_do_not_change_files[script/patch-data0-invalid_param]` | passed | 0.018910 | 0.391415 | 0.178475 | 0.588800 | 0.146681% | 70.949864% | 6 |  |
| 158 | `tests/e2e/m5/test_code_analysis.py::test_analysis_propagates_path_and_input_errors[scene_complexity]` | passed | 0.245919 | 0.207753 | 0.131049 | 0.584721 | 0.145665% | 71.095529% | 13 |  |
| 159 | `tests/e2e/m6/test_network_request.py::test_rejected_url_credentials_are_not_readable_in_audit[//audit-user:{secret}@host/path]` | passed | 0.026845 | 0.098294 | 0.459446 | 0.584584 | 0.145631% | 71.241160% | 3 |  |
| 160 | `tests/e2e/m2/test_editor_ui.py::test_selection_atomically_rejects_missing` | passed | 0.028862 | 0.161419 | 0.390586 | 0.580868 | 0.144705% | 71.385864% | 8 |  |
| 161 | `tests/e2e/m2/test_node_editor.py::test_node_delete_two_step_undo_redo_keeps_scene_tree_consistent` | passed | 0.021339 | 0.401134 | 0.156924 | 0.579398 | 0.144338% | 71.530203% | 18 |  |
| 162 | `tests/e2e/m5/test_code_analysis.py::test_analysis_recomputes_after_removing_reference_and_adding_node` | passed | 0.223520 | 0.227887 | 0.125753 | 0.577161 | 0.143781% | 71.673984% | 9 |  |
| 163 | `tests/e2e/m5/test_classdb_routes.py::test_classdb_queries_are_sorted_filtered_and_paginated` | passed | 0.270877 | 0.138021 | 0.165772 | 0.574670 | 0.143161% | 71.817145% | 8 |  |
| 164 | `tests/e2e/m4/test_animation.py::test_animation_routes_are_discoverable_and_documented` | passed | 0.019714 | 0.358917 | 0.195712 | 0.574343 | 0.143079% | 71.960224% | 17 |  |
| 165 | `tests/e2e/m5/test_uid_repair.py::test_uid_repair_read_only_missing_uid_does_not_partially_create_uids` | passed | 0.313328 | 0.059101 | 0.198112 | 0.570540 | 0.142132% | 72.102356% | 7 |  |
| 166 | `tests/e2e/m5/test_uid_repair.py::test_uid_repair_dry_run_writes_nothing` | passed | 0.231435 | 0.203747 | 0.131554 | 0.566736 | 0.141184% | 72.243540% | 6 |  |
| 167 | `tests/e2e/m5/test_project_config_routes.py::test_input_map_bind_failure_restores_absent_project_setting` | passed | 0.222337 | 0.166898 | 0.176776 | 0.566011 | 0.141004% | 72.384544% | 14 |  |
| 168 | `tests/e2e/m4/test_animation.py::test_animation_tree_blend_position_is_undoable` | passed | 0.020693 | 0.281774 | 0.254694 | 0.557161 | 0.138799% | 72.523343% | 12 |  |
| 169 | `tests/e2e/m5/test_uid_repair.py::test_uid_repair_preflights_all_targets_before_writing` | passed | 0.230166 | 0.179718 | 0.134229 | 0.544113 | 0.135549% | 72.658891% | 10 |  |
| 170 | `tests/e2e/m4/test_rendering.py::test_rendering_routes_are_discoverable_and_documented` | passed | 0.018961 | 0.305133 | 0.215019 | 0.539113 | 0.134303% | 72.793194% | 17 |  |
| 171 | `tests/e2e/m5/test_code_analysis.py::test_analysis_propagates_path_and_input_errors[signal_flow]` | passed | 0.244929 | 0.160837 | 0.125312 | 0.531078 | 0.132301% | 72.925496% | 13 |  |
| 172 | `tests/e2e/m4/test_navigation.py::test_navigation_bake_failures_leave_no_output` | passed | 0.030367 | 0.340032 | 0.160193 | 0.530592 | 0.132180% | 73.057676% | 15 |  |
| 173 | `tests/e2e/m5/test_code_analysis.py::test_analysis_propagates_path_and_input_errors[project_statistics]` | passed | 0.245675 | 0.162666 | 0.120765 | 0.529105 | 0.131810% | 73.189485% | 13 |  |
| 174 | `tests/e2e/m6/test_runtime_eval.py::test_runtime_eval_disconnect_completes_once` | passed | 0.022735 | 0.089429 | 0.415135 | 0.527299 | 0.131360% | 73.320845% | 10 |  |
| 175 | `tests/e2e/m3/test_runtime_extensions.py::test_qa_json_scene_script_real_assertions_cleanup_and_report` | passed | 0.060387 | 0.466126 | 0.000189 | 0.526702 | 0.131211% | 73.452056% | 8 |  |
| 176 | `tests/e2e/m4/test_navigation.py::test_navigation_bake_reflects_current_source_geometry` | passed | 0.023927 | 0.249569 | 0.249533 | 0.523029 | 0.130296% | 73.582352% | 12 |  |
| 177 | `tests/e2e/m2/test_editor_controls.py::test_node_call_executes_safe_native_and_validates_arguments` | passed | 0.022275 | 0.300441 | 0.192438 | 0.515154 | 0.128334% | 73.710686% | 14 |  |
| 178 | `tests/e2e/m3/test_runtime_assert_signal.py::test_signal_await_absolute_deadline_wins_after_main_thread_block` | passed | 0.076093 | 0.434706 | 0.000196 | 0.510995 | 0.127298% | 73.837984% | 9 |  |
| 179 | `tests/e2e/m5/test_code_analysis.py::test_scene_metrics_include_real_depth_instances_and_inheritance` | passed | 0.251125 | 0.092894 | 0.164738 | 0.508757 | 0.126741% | 73.964725% | 7 |  |
| 180 | `tests/e2e/m5/test_diagnostics_routes.py::test_diagnostics_match_m5_fixture_findings` | passed | 0.264257 | 0.115405 | 0.125314 | 0.504976 | 0.125799% | 74.090524% | 8 |  |
| 181 | `tests/e2e/m5/test_uid_repair.py::test_uid_repair_rejects_protected_roots_atomically[False-res://./addons/gdapi]` | passed | 0.297251 | 0.061306 | 0.143188 | 0.501745 | 0.124994% | 74.215518% | 7 |  |
| 182 | `tests/e2e/m5/test_code_analysis.py::test_analysis_propagates_path_and_input_errors[script_references]` | passed | 0.230630 | 0.155933 | 0.113318 | 0.499881 | 0.124529% | 74.340047% | 13 |  |
| 183 | `tests/e2e/m5/test_export.py::test_export_run_rejects_path_outside_project` | passed | 0.314009 | 0.054823 | 0.129219 | 0.498050 | 0.124073% | 74.464121% | 7 |  |
| 184 | `tests/e2e/m5/test_uid_repair.py::test_uid_repair_dry_run_apply_is_idempotent` | passed | 0.235144 | 0.119253 | 0.140033 | 0.494430 | 0.123171% | 74.587292% | 8 |  |
| 185 | `tests/e2e/m2/test_editor_ui.py::test_selection_round_trip` | passed | 0.023116 | 0.086433 | 0.384329 | 0.493878 | 0.123034% | 74.710326% | 7 |  |
| 186 | `tests/e2e/m2/test_scene_editor.py::test_cancelled_scene_open_does_not_switch_editor_scene` | passed | 0.022592 | 0.289154 | 0.177194 | 0.488940 | 0.121804% | 74.832130% | 7 |  |
| 187 | `tests/e2e/m2/test_scene_batch.py::test_plan_hash_binds_parameters_external_edits_and_dependencies` | passed | 0.022432 | 0.227538 | 0.236670 | 0.486640 | 0.121231% | 74.953361% | 10 |  |
| 188 | `tests/e2e/m5/test_uid_repair.py::test_uid_repair_rejects_protected_roots_atomically[True-res://./addons/gdapi]` | passed | 0.294769 | 0.050048 | 0.139354 | 0.484172 | 0.120616% | 75.073977% | 7 |  |
| 189 | `tests/e2e/m2/test_resource_routes.py::test_resource_files_untouched_on_rejection` | passed | 0.016464 | 0.308142 | 0.159136 | 0.483743 | 0.120509% | 75.194486% | 6 |  |
| 190 | `tests/e2e/m5/test_code_analysis.py::test_complexity_rejects_invalid_thresholds` | passed | 0.235413 | 0.144089 | 0.100588 | 0.480090 | 0.119599% | 75.314085% | 13 |  |
| 191 | `tests/e2e/m4/test_animation.py::test_animation_create_delete_are_undoable` | passed | 0.024798 | 0.283256 | 0.170483 | 0.478537 | 0.119212% | 75.433298% | 12 |  |
| 192 | `tests/e2e/m4/test_ui.py::test_ui_and_theme_routes_are_discoverable_and_documented` | passed | 0.023748 | 0.239438 | 0.210268 | 0.473453 | 0.117946% | 75.551243% | 14 |  |
| 193 | `tests/e2e/m2/test_editor_controls.py::test_notification_validation_and_distraction_mode` | passed | 0.021443 | 0.201662 | 0.246640 | 0.469745 | 0.117022% | 75.668265% | 11 |  |
| 194 | `tests/e2e/m2/test_editor_controls.py::test_inspector_observes_real_node_and_resource` | passed | 0.021901 | 0.208283 | 0.237705 | 0.467889 | 0.116560% | 75.784825% | 12 |  |
| 195 | `tests/e2e/m4/test_theme.py::test_theme_create_and_item_writes_round_trip_through_reload` | passed | 0.021478 | 0.284448 | 0.161797 | 0.467723 | 0.116518% | 75.901343% | 14 |  |
| 196 | `tests/e2e/m3/test_runtime_extensions.py::test_particle_runtime_observes_both_gpu_types_in_game_process` | passed | 0.071082 | 0.395135 | 0.000193 | 0.466409 | 0.116191% | 76.017534% | 10 |  |
| 197 | `tests/e2e/m3/test_runtime_nodes.py::test_runtime_node_mutations_reject_unsafe_targets_without_mutation` | passed | 0.076888 | 0.385927 | 0.000285 | 0.463100 | 0.115367% | 76.132901% | 10 |  |
| 198 | `tests/e2e/m2/test_editor_controls.py::test_camera_transform_round_trip_and_release` | passed | 0.026789 | 0.190216 | 0.246001 | 0.463006 | 0.115343% | 76.248244% | 11 |  |
| 199 | `tests/e2e/m5/test_project_config_routes.py::test_input_map_add_imports_preexisting_project_action` | passed | 0.226655 | 0.104998 | 0.128894 | 0.460547 | 0.114731% | 76.362975% | 10 |  |
| 200 | `tests/e2e/m5/test_code_analysis.py::test_signal_flow_has_real_endpoints_and_explicit_dynamic_unknowns` | passed | 0.313764 | 0.032853 | 0.112288 | 0.458906 | 0.114322% | 76.477297% | 6 |  |
| 201 | `tests/e2e/m4/test_rendering.py::test_shader_file_uniform_and_parameter_contracts` | passed | 0.015780 | 0.263973 | 0.178100 | 0.457853 | 0.114059% | 76.591356% | 13 |  |
| 202 | `tests/e2e/m2/test_editor_controls.py::test_editor_settings_persist_readback_and_restore` | passed | 0.021506 | 0.255779 | 0.179631 | 0.456915 | 0.113826% | 76.705182% | 12 |  |
| 203 | `tests/e2e/m2/test_scene_batch.py::test_project_scan_reports_real_nodepath_connection_instance_dependencies` | passed | 0.021094 | 0.187197 | 0.246702 | 0.454992 | 0.113347% | 76.818529% | 10 |  |
| 204 | `tests/e2e/m3/test_runtime_assert_signal.py::test_signal_connect_disconnect_emit_are_mutations` | passed | 0.077342 | 0.376921 | 0.000279 | 0.454542 | 0.113235% | 76.931764% | 8 |  |
| 205 | `tests/e2e/m4/test_resource_theme_reads.py::test_resource_readonly_file_does_not_report_saved_or_mutate_cache` | passed | 0.017433 | 0.277015 | 0.156777 | 0.451225 | 0.112408% | 77.044172% | 10 |  |
| 206 | `tests/e2e/m2/test_editor_controls.py::test_explicit_tool_method_is_a_real_consumer` | passed | 0.022836 | 0.250759 | 0.174729 | 0.448324 | 0.111686% | 77.155858% | 13 |  |
| 207 | `tests/e2e/m5/test_project_config_routes.py::test_input_map_add_rejects_unsupported_stored_event_without_mutation` | passed | 0.222469 | 0.114719 | 0.108447 | 0.445634 | 0.111016% | 77.266873% | 10 |  |
| 208 | `tests/e2e/m3/test_runtime_nodes.py::test_runtime_reparent_rejects_descendant_cycle_after_game_dispatch` | passed | 0.063940 | 0.380269 | 0.000291 | 0.444499 | 0.110733% | 77.377606% | 9 |  |
| 209 | `tests/e2e/m4/test_animation.py::test_animation_play_and_stop_expose_player_state` | passed | 0.019276 | 0.243034 | 0.177736 | 0.440046 | 0.109624% | 77.487230% | 13 |  |
| 210 | `tests/e2e/m4/test_theme.py::test_theme_rejects_non_integer_values_without_rewriting_file` | passed | 0.019124 | 0.258473 | 0.156398 | 0.433995 | 0.108116% | 77.595346% | 16 |  |
| 211 | `tests/e2e/m3/test_runtime_extensions.py::test_replay_timeout_and_cancellation_complete_real_requests` | passed | 0.067357 | 0.360578 | 0.000238 | 0.428172 | 0.106666% | 77.702011% | 7 |  |
| 212 | `tests/e2e/m4/test_audio.py::test_audio_routes_are_discoverable_and_documented` | passed | 0.026902 | 0.212839 | 0.185151 | 0.424892 | 0.105848% | 77.807860% | 12 |  |
| 213 | `tests/e2e/m5/test_uid_repair.py::test_uid_repair_rejects_protected_roots_atomically[False-res://addons/gdapi/]` | passed | 0.254780 | 0.048563 | 0.116939 | 0.420282 | 0.104700% | 77.912560% | 7 |  |
| 214 | `tests/e2e/m4/test_physics.py::test_physics_joint_create_reads_back_and_undo_removes_node` | passed | 0.022229 | 0.222339 | 0.174548 | 0.419116 | 0.104409% | 78.016969% | 12 |  |
| 215 | `tests/e2e/m2/test_mutation_audit.py::test_failed_mutation_without_changed_is_audited[body0-missing_param]` | passed | 0.029896 | 0.109379 | 0.277692 | 0.416968 | 0.103874% | 78.120843% | 8 |  |
| 216 | `tests/e2e/m3/test_runtime_input.py::test_input_sequence_executes_valid_events_in_game_process` | passed | 0.074834 | 0.341306 | 0.000215 | 0.416355 | 0.103722% | 78.224565% | 7 |  |
| 217 | `tests/e2e/test_shared_editor_lifecycle.py::test_build_environment_yields_one_process` | passed | 0.000364 | 0.415629 | 0.000260 | 0.416253 | 0.103696% | 78.328261% | 0 |  |
| 218 | `tests/e2e/m5/test_uid_repair.py::test_uid_repair_rejects_protected_roots_atomically[False-res://addons/gdapi/runtime/protected.tres]` | passed | 0.228397 | 0.041143 | 0.145745 | 0.415285 | 0.103455% | 78.431716% | 7 |  |
| 219 | `tests/e2e/m5/test_export.py::test_export_run_rejects_unknown_preset` | passed | 0.250609 | 0.037606 | 0.126210 | 0.414425 | 0.103241% | 78.534957% | 7 |  |
| 220 | `tests/e2e/m2/test_scene_editor.py::test_scene_current_save_persists_file_changes` | passed | 0.018806 | 0.069998 | 0.323278 | 0.412082 | 0.102657% | 78.637614% | 6 |  |
| 221 | `tests/e2e/m5/test_export.py::test_export_presets_lists_desktop_preset` | passed | 0.263004 | 0.014693 | 0.134002 | 0.411700 | 0.102562% | 78.740176% | 6 |  |
| 222 | `tests/e2e/m5/test_uid_repair.py::test_uid_repair_rejects_protected_roots_atomically[False-res://addons/gdapi/runtime]` | passed | 0.246042 | 0.042778 | 0.122304 | 0.411125 | 0.102419% | 78.842595% | 7 |  |
| 223 | `tests/e2e/m5/test_uid_repair.py::test_uid_repair_rejects_protected_roots_atomically[False-res://.godot/]` | passed | 0.256624 | 0.041406 | 0.110864 | 0.408894 | 0.101863% | 78.944457% | 7 |  |
| 224 | `tests/e2e/m3/test_runtime_extensions.py::test_qa_failed_and_timeout_results_are_saved` | passed | 0.075050 | 0.333479 | 0.000359 | 0.408888 | 0.101862% | 79.046319% | 6 |  |
| 225 | `tests/e2e/m5/test_uid_repair.py::test_uid_repair_rejects_protected_roots_atomically[True-res://addons/gdapi]` | passed | 0.258272 | 0.038961 | 0.110691 | 0.407923 | 0.101621% | 79.147940% | 7 |  |
| 226 | `tests/e2e/m4/test_navigation.py::test_navigation_routes_are_discoverable_and_documented` | passed | 0.024460 | 0.156021 | 0.227265 | 0.407747 | 0.101577% | 79.249517% | 10 |  |
| 227 | `tests/e2e/m4/test_physics.py::test_physics_layer_set_reads_back_and_undo_restores` | passed | 0.023431 | 0.219637 | 0.163324 | 0.406393 | 0.101240% | 79.350757% | 12 |  |
| 228 | `tests/e2e/m2/test_script_routes.py::test_script_writes_read_only_targets_fail_cleanly[script/patch-data2]` | passed | 0.023522 | 0.122977 | 0.259679 | 0.406178 | 0.101186% | 79.451943% | 9 |  |
| 229 | `tests/e2e/m5/test_uid_repair.py::test_uid_repair_rejects_protected_roots_atomically[False-res://.godot]` | passed | 0.248539 | 0.046289 | 0.109866 | 0.404695 | 0.100817% | 79.552760% | 7 |  |
| 230 | `tests/e2e/m4/test_tilemap.py::test_tilemap_routes_are_discoverable_and_documented` | passed | 0.020083 | 0.210794 | 0.172772 | 0.403650 | 0.100557% | 79.653317% | 12 |  |
| 231 | `tests/e2e/m4/test_tilemap.py::test_tilemap_clear_without_force_succeeds` | passed | 0.024036 | 0.202644 | 0.176711 | 0.403391 | 0.100492% | 79.753809% | 11 |  |
| 232 | `tests/e2e/m5/test_uid_repair.py::test_uid_repair_rejects_protected_roots_atomically[False-res://./.godot]` | passed | 0.250651 | 0.042147 | 0.109990 | 0.402787 | 0.100342% | 79.854151% | 7 |  |
| 233 | `tests/e2e/m5/test_uid_repair.py::test_uid_repair_rejects_protected_roots_atomically[True-res://.godot/]` | passed | 0.247242 | 0.042564 | 0.112673 | 0.402478 | 0.100265% | 79.954415% | 7 |  |
| 234 | `tests/e2e/m5/test_uid_repair.py::test_uid_repair_rejects_protected_roots_atomically[False-res://addons/gdapi]` | passed | 0.247008 | 0.037853 | 0.116840 | 0.401701 | 0.100071% | 80.054486% | 7 |  |
| 235 | `tests/e2e/m2/test_node_editor.py::test_node_create_then_rename_set_round_trip` | passed | 0.030314 | 0.135284 | 0.235979 | 0.401577 | 0.100040% | 80.154526% | 9 |  |
| 236 | `tests/e2e/m3/test_runtime_nodes.py::test_runtime_reparent_rejects_self_after_game_dispatch_without_mutation` | passed | 0.065861 | 0.333770 | 0.000243 | 0.399874 | 0.099616% | 80.254142% | 8 |  |
| 237 | `tests/e2e/m5/test_uid_repair.py::test_uid_repair_rejects_protected_roots_atomically[True-res://./.godot]` | passed | 0.243026 | 0.038410 | 0.116695 | 0.398131 | 0.099182% | 80.353324% | 7 |  |
| 238 | `tests/e2e/m2/test_spatial_particles.py::test_invalid_construction_leaves_no_half_node[particles/create-GPUParticles2D-properties0-invalid_param]` | passed | 0.027652 | 0.129671 | 0.238814 | 0.396137 | 0.098685% | 80.452009% | 9 |  |
| 239 | `tests/e2e/m5/test_diagnostics_routes.py::test_diagnostics_health_propagates_invalid_root` | passed | 0.230388 | 0.053104 | 0.112290 | 0.395782 | 0.098596% | 80.550605% | 7 |  |
| 240 | `tests/e2e/m4/test_theme.py::test_theme_rejects_non_finite_numbers_from_raw_request` | passed | 0.016329 | 0.184486 | 0.193922 | 0.394737 | 0.098336% | 80.648941% | 7 |  |
| 241 | `tests/e2e/m3/test_runtime_nodes.py::test_runtime_created_node_can_reparent_and_remove` | passed | 0.064258 | 0.330208 | 0.000253 | 0.394719 | 0.098332% | 80.747273% | 8 |  |
| 242 | `tests/e2e/m2/test_spatial_particles.py::test_spatial_structured_boundary_rejections_leave_tree_unchanged[payload1]` | passed | 0.020333 | 0.133325 | 0.240313 | 0.393970 | 0.098145% | 80.845418% | 9 |  |
| 243 | `tests/e2e/m2/test_editor_controls.py::test_node_call_rejects_native_escape_hatches_and_audits_failure[queue_free]` | passed | 0.025772 | 0.113981 | 0.253773 | 0.393526 | 0.098035% | 80.943453% | 9 |  |
| 244 | `tests/e2e/m5/test_uid_repair.py::test_uid_repair_rejects_protected_roots_atomically[True-res://addons/gdapi/]` | passed | 0.231863 | 0.051038 | 0.110454 | 0.393356 | 0.097992% | 81.041445% | 7 |  |
| 245 | `tests/e2e/m2/test_script_routes.py::test_script_writes_read_only_targets_fail_cleanly[script/create-data0]` | passed | 0.022961 | 0.127466 | 0.239759 | 0.390186 | 0.097202% | 81.138647% | 9 |  |
| 246 | `tests/e2e/m2/test_resource_routes.py::test_resource_create_assign_delete_round_trip` | passed | 0.017008 | 0.209817 | 0.162854 | 0.389680 | 0.097076% | 81.235723% | 7 |  |
| 247 | `tests/e2e/m5/test_snapshot_restore.py::test_source_fixture_is_immutable` | passed | 0.256130 | 0.002296 | 0.128964 | 0.387389 | 0.096506% | 81.332229% | 5 |  |
| 248 | `tests/e2e/m3/test_runtime_input.py::test_oversized_mutation_request_is_structured_fast_and_secret_safe` | passed | 0.081226 | 0.304598 | 0.000294 | 0.386118 | 0.096189% | 81.428418% | 6 |  |
| 249 | `tests/e2e/m4/test_audio_animation_extended.py::test_common_blend_nodes_have_real_typed_parameters[AnimationNodeAdd2-parameters4]` | passed | 0.023722 | 0.141140 | 0.221198 | 0.386060 | 0.096175% | 81.524593% | 9 |  |
| 250 | `tests/e2e/m2/test_mutation_audit.py::test_read_only_failure_is_not_a_mutation` | passed | 0.026367 | 0.089810 | 0.269657 | 0.385834 | 0.096118% | 81.620711% | 8 |  |
| 251 | `tests/e2e/m5/test_uid_repair.py::test_uid_repair_rejects_protected_roots_atomically[True-res://addons/gdapi/runtime]` | passed | 0.229829 | 0.048587 | 0.107256 | 0.385671 | 0.096078% | 81.716789% | 7 |  |
| 252 | `tests/e2e/m5/test_uid_repair.py::test_uid_repair_rejects_protected_roots_atomically[True-res://addons/gdapi/runtime/protected.tres]` | passed | 0.219168 | 0.047967 | 0.116694 | 0.383830 | 0.095619% | 81.812408% | 7 |  |
| 253 | `tests/e2e/m2/test_script_routes.py::test_script_writes_read_only_targets_fail_cleanly[script/write-data1]` | passed | 0.029693 | 0.142154 | 0.211909 | 0.383756 | 0.095600% | 81.908008% | 9 |  |
| 254 | `tests/e2e/m2/test_mutation_audit.py::test_malformed_json_is_audited_before_handler[filesystem/write-file]` | passed | 0.019117 | 0.107272 | 0.257332 | 0.383722 | 0.095592% | 82.003600% | 7 |  |
| 255 | `tests/e2e/m2/test_editor_controls.py::test_node_call_rejects_native_escape_hatches_and_audits_failure[free]` | passed | 0.020682 | 0.127753 | 0.233404 | 0.381839 | 0.095123% | 82.098723% | 9 |  |
| 256 | `tests/e2e/m3/test_runtime_extensions.py::test_png_comparison_identical_changed_threshold_and_dimensions` | passed | 0.064025 | 0.316084 | 0.000351 | 0.380460 | 0.094779% | 82.193503% | 7 |  |
| 257 | `tests/e2e/m3/test_runtime_nodes.py::test_runtime_node_rename_changes_only_dedicated_node` | passed | 0.074778 | 0.305345 | 0.000266 | 0.380388 | 0.094762% | 82.288265% | 7 |  |
| 258 | `tests/e2e/m5/test_code_analysis.py::test_script_references_preserve_locations_and_ignore_comment_string_code` | passed | 0.236488 | 0.029421 | 0.114199 | 0.380109 | 0.094692% | 82.382956% | 6 |  |
| 259 | `tests/e2e/m3/test_runtime_extensions.py::test_stress_actually_executes_concurrent_iterations` | passed | 0.073594 | 0.305666 | 0.000320 | 0.379580 | 0.094560% | 82.477517% | 5 |  |
| 260 | `tests/e2e/m2/test_scene_editor.py::test_scene_close_only_operates_on_current_scene` | passed | 0.022194 | 0.192709 | 0.162520 | 0.377424 | 0.094023% | 82.571540% | 14 |  |
| 261 | `tests/e2e/m4/test_physics.py::test_physics_routes_are_discoverable_and_documented` | passed | 0.021417 | 0.183758 | 0.171143 | 0.376317 | 0.093748% | 82.665287% | 11 |  |
| 262 | `tests/e2e/m4/test_theme.py::test_theme_integer_items_accept_float_encoded_integers` | passed | 0.017138 | 0.196532 | 0.161915 | 0.375585 | 0.093565% | 82.758852% | 10 |  |
| 263 | `tests/e2e/m2/test_editor_controls.py::test_api_provider_plugin_is_protected[reload]` | passed | 0.023458 | 0.095669 | 0.255833 | 0.374960 | 0.093409% | 82.852262% | 8 |  |
| 264 | `tests/e2e/m6/test_bulk_files.py::test_replace_rejects_windows_junction_outside_project` | passed | 0.026810 | 0.277229 | 0.070769 | 0.374808 | 0.093372% | 82.945633% | 6 |  |
| 265 | `tests/e2e/m3/test_runtime_extensions.py::test_screen_text_reads_controls_and_reports_real_timeout` | passed | 0.105779 | 0.267788 | 0.000281 | 0.373848 | 0.093132% | 83.038766% | 5 |  |
| 266 | `tests/e2e/m5/test_uid_repair.py::test_uid_repair_rejects_protected_roots_atomically[True-res://.godot]` | passed | 0.226774 | 0.045270 | 0.101385 | 0.373429 | 0.093028% | 83.131793% | 7 |  |
| 267 | `tests/e2e/m3/test_runtime_assert_signal.py::test_signal_await_timeout_is_one_408_completion` | passed | 0.061377 | 0.311319 | 0.000232 | 0.372927 | 0.092903% | 83.224696% | 7 |  |
| 268 | `tests/e2e/m2/test_scene_editor.py::test_save_as_invalid_extension_preserves_unsaved_scene_and_target` | passed | 0.021410 | 0.146688 | 0.204087 | 0.372185 | 0.092718% | 83.317415% | 10 |  |
| 269 | `tests/e2e/m2/test_editor_controls.py::test_api_provider_plugin_is_protected[disable]` | passed | 0.027003 | 0.090783 | 0.254028 | 0.371814 | 0.092626% | 83.410040% | 8 |  |
| 270 | `tests/e2e/m2/test_node_editor.py::test_node_delete_redo_removes_node_again` | passed | 0.018950 | 0.163302 | 0.189326 | 0.371578 | 0.092567% | 83.502607% | 10 |  |
| 271 | `tests/e2e/m3/test_runtime_input.py::test_stale_generation_file_request_is_removed_without_dispatch` | passed | 0.079698 | 0.291425 | 0.000405 | 0.371529 | 0.092555% | 83.595162% | 5 |  |
| 272 | `tests/e2e/m4/test_audio_animation_extended.py::test_common_blend_nodes_have_real_typed_parameters[AnimationNodeTimeSeek-parameters3]` | passed | 0.024106 | 0.122615 | 0.222553 | 0.369274 | 0.091993% | 83.687155% | 9 |  |
| 273 | `tests/e2e/m4/test_physics.py::test_physics_body_and_shape_are_undoable_and_3d_is_rejected` | passed | 0.020229 | 0.183997 | 0.164903 | 0.369129 | 0.091957% | 83.779111% | 11 |  |
| 274 | `tests/e2e/m3/test_runtime_nodes.py::test_runtime_reparent_rejects_scene_root_after_game_dispatch_without_mutation` | passed | 0.063534 | 0.303790 | 0.000213 | 0.367537 | 0.091560% | 83.870672% | 8 |  |
| 275 | `tests/e2e/m2/test_mutation_audit.py::test_malformed_json_is_audited_before_handler[editor/plugins/enable-file]` | passed | 0.023531 | 0.107552 | 0.232960 | 0.364044 | 0.090690% | 83.961362% | 7 |  |
| 276 | `tests/e2e/m6/test_process_run.py::test_process_run_timeout_has_one_failed_terminal_audit` | passed | 0.022989 | 0.281892 | 0.058824 | 0.363705 | 0.090606% | 84.051967% | 3 |  |
| 277 | `tests/e2e/m3/test_runtime_extensions.py::test_monitor_missing_target_terminates_subscription` | passed | 0.050033 | 0.309263 | 0.000251 | 0.359546 | 0.089569% | 84.141537% | 7 |  |
| 278 | `tests/e2e/m2/test_scene_batch.py::test_apply_mid_transaction_failure_rolls_back_all_writes` | passed | 0.019891 | 0.163298 | 0.174113 | 0.357302 | 0.089010% | 84.230547% | 7 |  |
| 279 | `tests/e2e/m3/test_runtime_extensions.py::test_reset_cancels_pending_qa_and_releases_signal_wait` | passed | 0.098558 | 0.254995 | 0.000351 | 0.353903 | 0.088164% | 84.318711% | 7 |  |
| 280 | `tests/e2e/m2/test_editor_controls.py::test_node_call_rejects_native_escape_hatches_and_audits_failure[call]` | passed | 0.022821 | 0.122932 | 0.208051 | 0.353805 | 0.088139% | 84.406850% | 9 |  |
| 281 | `tests/e2e/m2/test_editor_controls.py::test_metadata_cannot_grant_call_authority[gdapi_runtime_dedicated]` | passed | 0.023598 | 0.069698 | 0.259307 | 0.352603 | 0.087840% | 84.494690% | 7 |  |
| 282 | `tests/e2e/m6/test_bulk_files.py::test_replace_rejects_protected_paths` | passed | 0.024249 | 0.263467 | 0.061061 | 0.348777 | 0.086887% | 84.581576% | 6 |  |
| 283 | `tests/e2e/m2/test_spatial_particles.py::test_invalid_construction_leaves_no_half_node[particles/create-GPUParticles2D-properties2-invalid_param]` | passed | 0.025266 | 0.116701 | 0.205655 | 0.347622 | 0.086599% | 84.668175% | 9 |  |
| 284 | `tests/e2e/m2/test_editor_controls.py::test_metadata_cannot_grant_call_authority[gdapi_callable_methods]` | passed | 0.029064 | 0.071537 | 0.244175 | 0.344776 | 0.085890% | 84.754065% | 7 |  |
| 285 | `tests/e2e/m4/test_audio_animation_extended.py::test_common_blend_nodes_have_real_typed_parameters[AnimationNodeOneShot-parameters1]` | passed | 0.022762 | 0.109762 | 0.211695 | 0.344219 | 0.085751% | 84.839817% | 9 |  |
| 286 | `tests/e2e/m2/test_resource_routes.py::test_resource_overwrite_without_force` | passed | 0.015104 | 0.051073 | 0.277866 | 0.344042 | 0.085707% | 84.925524% | 6 |  |
| 287 | `tests/e2e/m3/test_runtime_input.py::test_zero_delay_action_sequence_observes_release_press_edge` | passed | 0.064391 | 0.279278 | 0.000232 | 0.343901 | 0.085672% | 85.011196% | 7 |  |
| 288 | `tests/e2e/m2/test_filesystem_routes.py::test_filesystem_write_read_only_target_fails_cleanly` | passed | 0.020805 | 0.125817 | 0.196510 | 0.343132 | 0.085480% | 85.096676% | 9 |  |
| 289 | `tests/e2e/m2/test_spatial_particles.py::test_spatial_structured_boundary_rejections_leave_tree_unchanged[payload0]` | passed | 0.021739 | 0.115760 | 0.203920 | 0.341419 | 0.085054% | 85.181730% | 9 |  |
| 290 | `tests/e2e/m2/test_spatial_particles.py::test_spatial_structured_boundary_rejections_leave_tree_unchanged[payload3]` | passed | 0.023899 | 0.110635 | 0.206714 | 0.341248 | 0.085011% | 85.266741% | 9 |  |
| 291 | `tests/e2e/m2/test_spatial_particles.py::test_particle_set_rejects_entire_batch_without_material_or_amount_leak` | passed | 0.017049 | 0.156228 | 0.167933 | 0.341209 | 0.085001% | 85.351742% | 10 |  |
| 292 | `tests/e2e/m2/test_node_editor.py::test_node_delete_undo_restores_parent_and_index` | passed | 0.018817 | 0.159252 | 0.162288 | 0.340357 | 0.084789% | 85.436531% | 13 |  |
| 293 | `tests/e2e/m4/test_ui.py::test_ui_rejects_non_text_control_and_bad_layout` | passed | 0.023062 | 0.143885 | 0.172285 | 0.339232 | 0.084509% | 85.521040% | 11 |  |
| 294 | `tests/e2e/m3/test_runtime_assert_signal.py::test_node_exists_and_property_equals_run_in_game` | passed | 0.080872 | 0.257406 | 0.000157 | 0.338435 | 0.084310% | 85.605350% | 7 |  |
| 295 | `tests/e2e/m2/test_mutation_audit.py::test_malformed_json_is_audited_before_handler[editor/eval-dangerous]` | passed | 0.031840 | 0.098876 | 0.207443 | 0.338160 | 0.084242% | 85.689592% | 7 |  |
| 296 | `tests/e2e/m3/test_runtime_assert_signal.py::test_signal_await_suspends_until_second_cli_emits_once` | passed | 0.049329 | 0.286980 | 0.000202 | 0.336511 | 0.083831% | 85.773423% | 9 |  |
| 297 | `tests/e2e/m3/test_runtime_capture.py::test_invalid_capture_fixture_mode_has_no_side_effect` | passed | 0.097308 | 0.238338 | 0.000377 | 0.336023 | 0.083709% | 85.857133% | 5 |  |
| 298 | `tests/e2e/m4/test_rendering.py::test_rendering_rejects_invalid_material_values_and_unsafe_paths` | passed | 0.019663 | 0.174562 | 0.140626 | 0.334851 | 0.083417% | 85.940550% | 14 |  |
| 299 | `tests/e2e/m2/test_spatial_particles.py::test_spatial_structured_boundary_rejections_leave_tree_unchanged[payload2]` | passed | 0.022670 | 0.120130 | 0.192008 | 0.334808 | 0.083407% | 86.023957% | 9 |  |
| 300 | `tests/e2e/m2/test_signal_group_routes.py::test_duplicate_signal_is_conflict` | passed | 0.027578 | 0.053712 | 0.252789 | 0.334080 | 0.083225% | 86.107182% | 7 |  |
| 301 | `tests/e2e/m3/test_runtime_capture.py::test_oversized_camera_source_is_rejected_before_readback` | passed | 0.075156 | 0.257789 | 0.000316 | 0.333261 | 0.083021% | 86.190204% | 7 |  |
| 302 | `tests/e2e/m2/test_filesystem_routes.py::test_filesystem_write_overwrites_without_force` | passed | 0.022312 | 0.098136 | 0.211933 | 0.332381 | 0.082802% | 86.273006% | 8 |  |
| 303 | `tests/e2e/m2/test_spatial_particles.py::test_invalid_construction_leaves_no_half_node[scene3d/create-Camera3D-properties6-invalid_param]` | passed | 0.016420 | 0.090251 | 0.225251 | 0.331923 | 0.082688% | 86.355694% | 9 |  |
| 304 | `tests/e2e/m4/test_audio_animation_extended.py::test_common_blend_nodes_have_real_typed_parameters[AnimationNodeBlend3-parameters0]` | passed | 0.023381 | 0.112510 | 0.194673 | 0.330564 | 0.082350% | 86.438043% | 9 |  |
| 305 | `tests/e2e/m4/test_animation.py::test_animation_tree_state_and_transition_are_undoable` | passed | 0.019480 | 0.149612 | 0.159882 | 0.328973 | 0.081953% | 86.519997% | 11 |  |
| 306 | `tests/e2e/m2/test_node_editor.py::test_node_rejections_are_atomic[node/get-data0-not_found]` | passed | 0.020522 | 0.083059 | 0.224361 | 0.327943 | 0.081697% | 86.601693% | 8 |  |
| 307 | `tests/e2e/m4/test_audio_animation_extended.py::test_common_blend_nodes_have_real_typed_parameters[AnimationNodeTimeScale-parameters2]` | passed | 0.022576 | 0.109873 | 0.195355 | 0.327804 | 0.081662% | 86.683355% | 9 |  |
| 308 | `tests/e2e/m3/test_runtime_assert_signal.py::test_condition_timeout_is_one_409_completion` | passed | 0.070317 | 0.255510 | 0.000219 | 0.326047 | 0.081224% | 86.764579% | 7 |  |
| 309 | `tests/e2e/m2/test_node_editor.py::test_node_property_round_trip_uses_codec` | passed | 0.022000 | 0.098814 | 0.205063 | 0.325876 | 0.081182% | 86.845761% | 8 |  |
| 310 | `tests/e2e/m2/test_scene_editor.py::test_scene_list_open_returns_every_open_scene_in_stable_order` | passed | 0.025197 | 0.123391 | 0.176710 | 0.325298 | 0.081038% | 86.926798% | 10 |  |
| 311 | `tests/e2e/m2/test_spatial_particles.py::test_invalid_construction_leaves_no_half_node[scene3d/create-CSGBox3D-properties7-permission_denied]` | passed | 0.018176 | 0.115505 | 0.191559 | 0.325240 | 0.081023% | 87.007822% | 9 |  |
| 312 | `tests/e2e/m2/test_m2_contract.py::test_routes_match_expected_inventory` | passed | 0.025301 | 0.036778 | 0.260517 | 0.322596 | 0.080365% | 87.088186% | 6 |  |
| 313 | `tests/e2e/m3/test_runtime_input.py::test_input_key_mouse_gamepad_touch_increments_counter[input_touch]` | passed | 0.102940 | 0.219093 | 0.000389 | 0.322421 | 0.080321% | 87.168507% | 5 |  |
| 314 | `tests/e2e/m2/test_editor_controls.py::test_api_provider_plugin_is_protected[enable]` | passed | 0.020205 | 0.082830 | 0.219341 | 0.322377 | 0.080310% | 87.248817% | 8 |  |
| 315 | `tests/e2e/m2/test_mutation_audit.py::test_malformed_json_is_audited_before_handler[scene/delete-dangerous]` | passed | 0.022545 | 0.093925 | 0.205858 | 0.322328 | 0.080298% | 87.329115% | 7 |  |
| 316 | `tests/e2e/m2/test_spatial_particles.py::test_particle_lower_valid_amount_and_fractional_lifetime[GPUParticles2D]` | passed | 0.029005 | 0.134151 | 0.158614 | 0.321770 | 0.080159% | 87.409274% | 10 |  |
| 317 | `tests/e2e/m2/test_spatial_particles.py::test_invalid_construction_leaves_no_half_node[particles/create-GPUParticles3D-properties3-invalid_param]` | passed | 0.021229 | 0.114100 | 0.185915 | 0.321244 | 0.080028% | 87.489301% | 9 |  |
| 318 | `tests/e2e/m4/test_audio_animation_extended.py::test_common_blend_nodes_have_real_typed_parameters[AnimationNodeSub2-parameters6]` | passed | 0.024517 | 0.124820 | 0.170656 | 0.319992 | 0.079716% | 87.569017% | 9 |  |
| 319 | `tests/e2e/m2/test_editor_controls.py::test_headless_screenshot_has_an_honest_error` | passed | 0.027460 | 0.036127 | 0.255973 | 0.319560 | 0.079608% | 87.648625% | 6 |  |
| 320 | `tests/e2e/m2/test_script_routes.py::test_script_create_patch_validate_attach` | passed | 0.020088 | 0.123611 | 0.175518 | 0.319217 | 0.079523% | 87.728148% | 9 |  |
| 321 | `tests/e2e/m2/test_spatial_particles.py::test_invalid_construction_leaves_no_half_node[particles/create-GPUParticles3D-properties1-invalid_param]` | passed | 0.022865 | 0.126755 | 0.169561 | 0.319182 | 0.079514% | 87.807662% | 9 |  |
| 322 | `tests/e2e/m2/test_node_editor.py::test_node_non_object_consumers_reject_nested_object_tags` | passed | 0.025208 | 0.117851 | 0.172754 | 0.315813 | 0.078675% | 87.886337% | 9 |  |
| 323 | `tests/e2e/m2/test_mutation_audit.py::test_dangerous_failure_is_not_duplicated` | passed | 0.026366 | 0.092902 | 0.194363 | 0.313631 | 0.078131% | 87.964468% | 8 |  |
| 324 | `tests/e2e/m2/test_editor_ui.py::test_node_select_routes_through_selection_service` | passed | 0.019057 | 0.019432 | 0.275140 | 0.313629 | 0.078131% | 88.042599% | 6 |  |
| 325 | `tests/e2e/m2/test_mutation_audit.py::test_malformed_json_is_audited_before_handler[editor/settings/set-file]` | passed | 0.022725 | 0.061980 | 0.228263 | 0.312968 | 0.077966% | 88.120565% | 7 |  |
| 326 | `tests/e2e/m2/test_editor_ui.py::test_main_screen_allowlist` | passed | 0.021989 | 0.068667 | 0.220906 | 0.311561 | 0.077616% | 88.198180% | 7 |  |
| 327 | `tests/e2e/m2/test_editor_controls.py::test_node_call_rejects_native_escape_hatches_and_audits_failure[set_script]` | passed | 0.024476 | 0.109032 | 0.177864 | 0.311372 | 0.077568% | 88.275749% | 9 |  |
| 328 | `tests/e2e/m2/test_signal_group_routes.py::test_signal_group_rejections[node/signal/connect-data0-not_found]` | passed | 0.024240 | 0.027200 | 0.259520 | 0.310960 | 0.077466% | 88.353214% | 6 |  |
| 329 | `tests/e2e/m2/test_spatial_particles.py::test_particle_lower_valid_amount_and_fractional_lifetime[GPUParticles3D]` | passed | 0.020628 | 0.130936 | 0.159364 | 0.310928 | 0.077458% | 88.430672% | 10 |  |
| 330 | `tests/e2e/m2/test_mutation_audit.py::test_malformed_json_is_audited_before_handler[scene/batch/apply-file]` | passed | 0.020607 | 0.115964 | 0.173080 | 0.309652 | 0.077140% | 88.507812% | 7 |  |
| 331 | `tests/e2e/m4/test_audio_animation_extended.py::test_common_blend_nodes_have_real_typed_parameters[AnimationNodeAdd3-parameters5]` | passed | 0.024263 | 0.106730 | 0.178135 | 0.309129 | 0.077010% | 88.584822% | 9 |  |
| 332 | `tests/e2e/m3/test_runtime_assert_signal.py::test_condition_suspends_until_second_cli_mutates_game` | passed | 0.048974 | 0.259314 | 0.000245 | 0.308533 | 0.076861% | 88.661683% | 9 |  |
| 333 | `tests/e2e/m2/test_mutation_audit.py::test_malformed_json_is_audited_before_handler[editor/screenshot/viewport-file]` | passed | 0.024001 | 0.071736 | 0.212604 | 0.308342 | 0.076813% | 88.738496% | 7 |  |
| 334 | `tests/e2e/m2/test_editor_controls.py::test_metadata_cannot_grant_call_authority[_edit_lock_]` | passed | 0.022388 | 0.058753 | 0.226753 | 0.307894 | 0.076702% | 88.815198% | 7 |  |
| 335 | `tests/e2e/m6/test_process_run.py::test_process_run_no_shell_preserves_argv` | passed | 0.023679 | 0.211855 | 0.072096 | 0.307630 | 0.076636% | 88.891835% | 1 |  |
| 336 | `tests/e2e/m3/test_runtime_assert_signal.py::test_assert_signal_received_suspends_until_second_cli_emits` | passed | 0.076148 | 0.230980 | 0.000328 | 0.307456 | 0.076593% | 88.968428% | 8 |  |
| 337 | `tests/e2e/m2/test_signal_group_routes.py::test_signal_group_rejections[node/group/add-data2-missing_param]` | passed | 0.026390 | 0.036997 | 0.243610 | 0.306997 | 0.076479% | 89.044906% | 6 |  |
| 338 | `tests/e2e/m4/test_tilemap.py::test_tilemap_rejects_invalid_cell` | passed | 0.020183 | 0.118685 | 0.166986 | 0.305854 | 0.076194% | 89.121100% | 9 |  |
| 339 | `tests/e2e/m3/test_runtime_extensions.py::test_stress_retains_actual_failure_samples` | passed | 0.114497 | 0.190665 | 0.000189 | 0.305351 | 0.076068% | 89.197168% | 4 |  |
| 340 | `tests/e2e/m2/test_mutation_audit.py::test_audit_safety_filter_rejects_unknown_values` | passed | 0.029283 | 0.035893 | 0.239536 | 0.304712 | 0.075909% | 89.273078% | 6 |  |
| 341 | `tests/e2e/m2/test_editor_controls.py::test_node_call_rejects_native_escape_hatches_and_audits_failure[callv]` | passed | 0.023949 | 0.096045 | 0.182176 | 0.302170 | 0.075276% | 89.348354% | 9 |  |
| 342 | `tests/e2e/m2/test_mutation_audit.py::test_failed_mutation_without_changed_is_audited[body1-not_found]` | passed | 0.025344 | 0.088505 | 0.188057 | 0.301906 | 0.075210% | 89.423564% | 8 |  |
| 343 | `tests/e2e/m2/test_editor_controls.py::test_node_call_rejects_native_escape_hatches_and_audits_failure[add_child]` | passed | 0.020791 | 0.100283 | 0.178428 | 0.299502 | 0.074611% | 89.498175% | 9 |  |
| 344 | `tests/e2e/m2/test_mutation_audit.py::test_malformed_json_is_audited_before_handler[audio/bus/set-file]` | passed | 0.020911 | 0.098962 | 0.179208 | 0.299081 | 0.074507% | 89.572682% | 7 |  |
| 345 | `tests/e2e/m4/test_tilemap.py::test_tilemap_fill_and_used_cells_are_sorted` | passed | 0.023853 | 0.097436 | 0.177413 | 0.298702 | 0.074412% | 89.647094% | 9 |  |
| 346 | `tests/e2e/m2/test_mutation_audit.py::test_failed_mutation_without_changed_is_audited[body2-not_found]` | passed | 0.017220 | 0.085652 | 0.195597 | 0.298469 | 0.074354% | 89.721448% | 8 |  |
| 347 | `tests/e2e/m2/test_spatial_particles.py::test_invalid_construction_leaves_no_half_node[scene3d/create-OmniLight3D-properties8-permission_denied]` | passed | 0.017394 | 0.106309 | 0.174329 | 0.298033 | 0.074245% | 89.795693% | 9 |  |
| 348 | `tests/e2e/m2/test_node_editor.py::test_node_rejections_are_atomic[node/delete-data2-permission_denied]` | passed | 0.025628 | 0.077239 | 0.195063 | 0.297930 | 0.074220% | 89.869913% | 8 |  |
| 349 | `tests/e2e/m3/test_runtime_input.py::test_input_key_mouse_gamepad_touch_increments_counter[input_mouse]` | passed | 0.095958 | 0.200358 | 0.000380 | 0.296696 | 0.073912% | 89.943825% | 5 |  |
| 350 | `tests/e2e/m2/test_editor_controls.py::test_node_call_rejects_native_escape_hatches_and_audits_failure[get_tree]` | passed | 0.020197 | 0.100743 | 0.175331 | 0.296270 | 0.073806% | 90.017632% | 9 |  |
| 351 | `tests/e2e/m2/test_editor_controls.py::test_node_call_rejects_native_escape_hatches_and_audits_failure[set_meta]` | passed | 0.020895 | 0.098142 | 0.176718 | 0.295754 | 0.073678% | 90.091310% | 9 |  |
| 352 | `tests/e2e/m2/test_scene_batch.py::test_invalid_property_plan_never_changes_disk[script/source_code-extends Node-permission_denied]` | passed | 0.025786 | 0.036916 | 0.232663 | 0.295364 | 0.073581% | 90.164890% | 6 |  |
| 353 | `tests/e2e/m2/test_spatial_particles.py::test_invalid_construction_leaves_no_half_node[particles/create-GPUParticles2D-properties5-invalid_param]` | passed | 0.019801 | 0.102263 | 0.172584 | 0.294648 | 0.073402% | 90.238292% | 9 |  |
| 354 | `tests/e2e/m3/test_runtime_input.py::test_input_mutation_audit_is_redacted_and_bounded` | passed | 0.099640 | 0.194363 | 0.000350 | 0.294352 | 0.073329% | 90.311621% | 7 |  |
| 355 | `tests/e2e/m3/test_runtime_assert_signal.py::test_property_equals_rejects_missing_property_or_value_immediately` | passed | 0.046738 | 0.246124 | 0.000198 | 0.293061 | 0.073007% | 90.384628% | 9 |  |
| 356 | `tests/e2e/m2/test_scene_batch.py::test_invalid_property_plan_never_changes_disk[owner-None-permission_denied]` | passed | 0.023516 | 0.035481 | 0.233135 | 0.292132 | 0.072776% | 90.457403% | 6 |  |
| 357 | `tests/e2e/m2/test_scene_batch.py::test_invalid_property_plan_never_changes_disk[not_a_property-1-not_found]` | passed | 0.028043 | 0.045056 | 0.217517 | 0.290615 | 0.072398% | 90.529801% | 6 |  |
| 358 | `tests/e2e/m2/test_filesystem_routes.py::test_filesystem_write_atomic` | passed | 0.025918 | 0.090229 | 0.173490 | 0.289637 | 0.072154% | 90.601955% | 8 |  |
| 359 | `tests/e2e/m2/test_spatial_particles.py::test_multimesh_instance_data_requires_active_renderer` | passed | 0.019019 | 0.105153 | 0.162213 | 0.286385 | 0.071344% | 90.673298% | 9 |  |
| 360 | `tests/e2e/m2/test_m2_contract.py::test_commands_list_contains_m2_baseline_routes` | passed | 0.024342 | 0.051070 | 0.210590 | 0.286002 | 0.071248% | 90.744547% | 6 |  |
| 361 | `tests/e2e/m3/test_runtime_input.py::test_input_key_mouse_gamepad_touch_increments_counter[input_gamepad]` | passed | 0.073680 | 0.209050 | 0.000404 | 0.283135 | 0.070534% | 90.815081% | 5 |  |
| 362 | `tests/e2e/m2/test_node_editor.py::test_node_set_rejects_invalid_property_before_mutation` | passed | 0.019915 | 0.083840 | 0.179133 | 0.282888 | 0.070472% | 90.885553% | 9 |  |
| 363 | `tests/e2e/m4/test_audio.py::test_audio_player_creation_is_undoable` | passed | 0.021765 | 0.115438 | 0.145181 | 0.282384 | 0.070347% | 90.955900% | 8 |  |
| 364 | `tests/e2e/m2/test_mutation_audit.py::test_malformed_json_is_audited_before_handler[node/property/set-mutation]` | passed | 0.019059 | 0.088447 | 0.174600 | 0.282106 | 0.070278% | 91.026178% | 7 |  |
| 365 | `tests/e2e/m2/test_mutation_audit.py::test_unselfaudited_mutation_gets_one_mutation_entry` | passed | 0.019169 | 0.084080 | 0.178077 | 0.281326 | 0.070084% | 91.096261% | 8 |  |
| 366 | `tests/e2e/m2/test_spatial_particles.py::test_invalid_construction_leaves_no_half_node[particles/create-GPUParticles2D-properties4-invalid_param]` | passed | 0.019822 | 0.103823 | 0.156618 | 0.280264 | 0.069819% | 91.166080% | 9 |  |
| 367 | `tests/e2e/m2/test_scene_batch.py::test_invalid_property_plan_never_changes_disk[script-value2-permission_denied]` | passed | 0.022502 | 0.036971 | 0.220343 | 0.279817 | 0.069707% | 91.235788% | 6 |  |
| 368 | `tests/e2e/m2/test_resource_routes.py::test_resource_search_finds_player` | passed | 0.021225 | 0.061778 | 0.196511 | 0.279514 | 0.069632% | 91.305420% | 6 |  |
| 369 | `tests/e2e/m2/test_filesystem_routes.py::test_filesystem_search_and_read_round_trip` | passed | 0.023510 | 0.063407 | 0.191307 | 0.278224 | 0.069311% | 91.374730% | 7 |  |
| 370 | `tests/e2e/m2/test_filesystem_routes.py::test_filesystem_rejections[filesystem/write-data2-permission_denied]` | passed | 0.024931 | 0.030587 | 0.222567 | 0.278085 | 0.069276% | 91.444006% | 6 |  |
| 371 | `tests/e2e/m2/test_node_editor.py::test_node_rejections_are_atomic[node/reparent-data3-conflict]` | passed | 0.018278 | 0.065675 | 0.194128 | 0.278081 | 0.069275% | 91.513281% | 8 |  |
| 372 | `tests/e2e/m2/test_signal_group_routes.py::test_signal_group_rejections[node/signal/connect-data1-not_found]` | passed | 0.022494 | 0.027114 | 0.227391 | 0.276999 | 0.069006% | 91.582287% | 6 |  |
| 373 | `tests/e2e/m2/test_mutation_audit.py::test_selfaudited_mutation_is_not_duplicated` | passed | 0.020999 | 0.036952 | 0.218759 | 0.276710 | 0.068933% | 91.651220% | 7 |  |
| 374 | `tests/e2e/m2/test_filesystem_routes.py::test_filesystem_query_contract` | passed | 0.022355 | 0.066772 | 0.187059 | 0.276186 | 0.068803% | 91.720023% | 7 |  |
| 375 | `tests/e2e/m2/test_filesystem_routes.py::test_filesystem_rejections[filesystem/read-data0-invalid_path]` | passed | 0.022505 | 0.028109 | 0.225047 | 0.275661 | 0.068672% | 91.788695% | 6 |  |
| 376 | `tests/e2e/m2/test_editor_controls.py::test_node_call_rejects_native_escape_hatches_and_audits_failure[rpc]` | passed | 0.019728 | 0.082807 | 0.172520 | 0.275055 | 0.068521% | 91.857217% | 9 |  |
| 377 | `tests/e2e/m3/test_runtime_observability.py::test_runtime_log_incremental_no_duplicate` | passed | 0.071831 | 0.202565 | 0.000217 | 0.274613 | 0.068411% | 91.925628% | 6 |  |
| 378 | `tests/e2e/m3/test_runtime_observability.py::test_runtime_log_clear_reports_mutation_and_empties_buffer` | passed | 0.102669 | 0.171502 | 0.000290 | 0.274461 | 0.068373% | 91.994001% | 5 |  |
| 379 | `tests/e2e/m3/test_runtime_nodes.py::test_runtime_node_duplicate_copies_typed_allowlisted_property` | passed | 0.066371 | 0.203403 | 0.000313 | 0.270087 | 0.067284% | 92.061285% | 5 |  |
| 380 | `tests/e2e/m2/test_node_editor.py::test_node_rejections_are_atomic[node/property/set-data4-permission_denied]` | passed | 0.022177 | 0.078524 | 0.168801 | 0.269502 | 0.067138% | 92.128422% | 8 |  |
| 381 | `tests/e2e/m2/test_node_editor.py::test_node_rejections_are_atomic[node/property/set-data5-invalid_param]` | passed | 0.016473 | 0.074672 | 0.177577 | 0.268722 | 0.066944% | 92.195366% | 8 |  |
| 382 | `tests/e2e/m2/test_filesystem_routes.py::test_filesystem_write_preserves_existing_temp_name` | passed | 0.022559 | 0.046514 | 0.196880 | 0.265953 | 0.066254% | 92.261620% | 6 |  |
| 383 | `tests/e2e/m2/test_scene_batch.py::test_invalid_property_plan_never_changes_disk[position-value1-invalid_param]` | passed | 0.020627 | 0.038504 | 0.205642 | 0.264772 | 0.065959% | 92.327579% | 6 |  |
| 384 | `tests/e2e/m2/test_filesystem_routes.py::test_filesystem_rejections[filesystem/read-data1-invalid_path]` | passed | 0.024473 | 0.030190 | 0.210073 | 0.264736 | 0.065951% | 92.393530% | 6 |  |
| 385 | `tests/e2e/m6/test_bulk_files.py::test_recover_failure_leaves_no_partial_state` | passed | 0.023541 | 0.170671 | 0.070253 | 0.264466 | 0.065883% | 92.459413% | 5 |  |
| 386 | `tests/e2e/m2/test_scene_batch.py::test_windows_read_only_second_file_prevents_any_write` | passed | 0.021617 | 0.079763 | 0.162918 | 0.264298 | 0.065841% | 92.525254% | 7 |  |
| 387 | `tests/e2e/m3/test_runtime_extensions.py::test_png_comparison_current_viewport_and_dimension_allocation_bound` | passed | 0.097458 | 0.166438 | 0.000196 | 0.264093 | 0.065790% | 92.591045% | 5 |  |
| 388 | `tests/e2e/m2/test_node_editor.py::test_node_rejections_are_atomic[node/create-data1-invalid_param]` | passed | 0.021552 | 0.063338 | 0.178511 | 0.263401 | 0.065618% | 92.656663% | 8 |  |
| 389 | `tests/e2e/m2/test_mutation_audit.py::test_malformed_json_is_audited_before_handler[resource/set-file]` | passed | 0.019185 | 0.069153 | 0.174598 | 0.262936 | 0.065502% | 92.722165% | 7 |  |
| 390 | `tests/e2e/m2/test_fixture_isolation.py::test_editor_starts_with_main_scene` | passed | 0.026664 | 0.025155 | 0.209864 | 0.261682 | 0.065190% | 92.787355% | 6 |  |
| 391 | `tests/e2e/m2/test_node_editor.py::test_node_non_object_consumers_keep_valid_values` | passed | 0.021197 | 0.063664 | 0.175800 | 0.260661 | 0.064935% | 92.852290% | 7 |  |
| 392 | `tests/e2e/m2/test_mutation_audit.py::test_failed_mutation_without_changed_is_audited[body3-invalid_param]` | passed | 0.021212 | 0.064546 | 0.174746 | 0.260504 | 0.064896% | 92.917186% | 8 |  |
| 393 | `tests/e2e/m2/test_scene_batch.py::test_scan_excludes_generated_subdirectories` | passed | 0.024558 | 0.036261 | 0.199207 | 0.260026 | 0.064777% | 92.981963% | 6 |  |
| 394 | `tests/e2e/m2/test_resource_routes.py::test_resource_assign_rejects_non_resource_property` | passed | 0.015650 | 0.027786 | 0.214431 | 0.257866 | 0.064239% | 93.046203% | 6 |  |
| 395 | `tests/e2e/m2/test_node_editor.py::test_node_list_and_property_list` | passed | 0.017354 | 0.059942 | 0.180355 | 0.257651 | 0.064186% | 93.110388% | 7 |  |
| 396 | `tests/e2e/m2/test_script_routes.py::test_script_writes_preserve_existing_temp_name` | passed | 0.021061 | 0.061202 | 0.169084 | 0.251347 | 0.062615% | 93.173003% | 7 |  |
| 397 | `tests/e2e/m2/test_filesystem_routes.py::test_filesystem_rejections[filesystem/reimport-data3-permission_denied]` | passed | 0.022219 | 0.030659 | 0.198027 | 0.250905 | 0.062505% | 93.235508% | 6 |  |
| 398 | `tests/e2e/m2/test_fixture_isolation.py::test_fixture_is_a_private_copy` | passed | 0.027587 | 0.001104 | 0.221954 | 0.250645 | 0.062440% | 93.297949% | 5 |  |
| 399 | `tests/e2e/m2/test_scene_editor.py::test_scene_open_rejects_missing_scene_without_state_change` | passed | 0.024237 | 0.051651 | 0.174423 | 0.250311 | 0.062357% | 93.360306% | 8 |  |
| 400 | `tests/e2e/m2/test_scene_editor.py::test_scene_close_then_current_is_not_found` | passed | 0.021773 | 0.048261 | 0.177589 | 0.247622 | 0.061687% | 93.421993% | 7 |  |
| 401 | `tests/e2e/m3/test_runtime_assert_signal.py::test_reset_disconnects_pending_await_exactly_once` | passed | 0.050914 | 0.196050 | 0.000247 | 0.247210 | 0.061585% | 93.483577% | 8 |  |
| 402 | `tests/e2e/m3/test_runtime_assert_signal.py::test_transport_disconnect_completes_long_call_once_with_zero_pending` | passed | 0.081041 | 0.164294 | 0.000244 | 0.245579 | 0.061178% | 93.544756% | 9 |  |
| 403 | `tests/e2e/m2/test_resource_routes.py::test_resource_info_returns_class` | passed | 0.018146 | 0.026376 | 0.199051 | 0.243573 | 0.060678% | 93.605434% | 6 |  |
| 404 | `tests/e2e/m3/test_runtime_capture.py::test_camera_capture_returns_valid_png_and_path` | passed | 0.074310 | 0.167835 | 0.000197 | 0.242343 | 0.060372% | 93.665806% | 4 |  |
| 405 | `tests/e2e/m3/test_runtime_input.py::test_input_key_mouse_gamepad_touch_increments_counter[input_keys]` | passed | 0.060231 | 0.180338 | 0.000303 | 0.240873 | 0.060006% | 93.725812% | 5 |  |
| 406 | `tests/e2e/m3/test_runtime_observability.py::test_runtime_log_read_returns_known_game_logs` | passed | 0.110259 | 0.129064 | 0.000258 | 0.239581 | 0.059684% | 93.785496% | 4 |  |
| 407 | `tests/e2e/m4/test_rendering.py::test_shader_write_overwrites_without_force` | passed | 0.024016 | 0.049461 | 0.165649 | 0.239126 | 0.059571% | 93.845067% | 6 |  |
| 408 | `tests/e2e/m2/test_scene_batch.py::test_invalid_property_plan_never_changes_disk[position-wrong-type-invalid_param]` | passed | 0.025376 | 0.037417 | 0.172503 | 0.235295 | 0.058616% | 93.903683% | 6 |  |
| 409 | `tests/e2e/m3/test_runtime_assert_signal.py::test_legacy_immediate_emit_does_not_satisfy_future_await` | passed | 0.055546 | 0.178117 | 0.000207 | 0.233870 | 0.058261% | 93.961944% | 5 |  |
| 410 | `tests/e2e/m6/test_bulk_files.py::test_delete_recover_restores_uid_and_is_not_repeatable` | passed | 0.022296 | 0.150965 | 0.060313 | 0.233574 | 0.058187% | 94.020132% | 5 |  |
| 411 | `tests/e2e/m6/test_process_run.py::test_process_run_json_preserves_non_nul_c0_controls` | passed | 0.024624 | 0.148154 | 0.057869 | 0.230647 | 0.057458% | 94.077590% | 1 |  |
| 412 | `tests/e2e/m2/test_node_editor.py::test_node_metadata_rejects_resource_before_first_load` | passed | 0.029006 | 0.026905 | 0.174298 | 0.230209 | 0.057349% | 94.134939% | 6 |  |
| 413 | `tests/e2e/m3/test_runtime_nodes.py::test_runtime_node_call_then_get_continuous_request` | passed | 0.104091 | 0.125638 | 0.000272 | 0.230001 | 0.057297% | 94.192237% | 4 |  |
| 414 | `tests/e2e/m6/test_bulk_files.py::test_replace_dry_run_then_apply` | passed | 0.022212 | 0.144673 | 0.056316 | 0.223202 | 0.055604% | 94.247840% | 4 |  |
| 415 | `tests/e2e/m2/test_script_routes.py::test_invalid_script_returns_valid_false` | passed | 0.023561 | 0.026919 | 0.169954 | 0.220433 | 0.054914% | 94.302754% | 6 |  |
| 416 | `tests/e2e/m2/test_scene_editor.py::test_scene_list_open_contains_main` | passed | 0.018304 | 0.021301 | 0.180529 | 0.220134 | 0.054839% | 94.357594% | 6 |  |
| 417 | `tests/e2e/m6/test_network_request.py::test_redirect_uri_reference_reaches_resolved_path[?next=2-/dir/start?next=2]` | passed | 0.026306 | 0.095537 | 0.097767 | 0.219610 | 0.054709% | 94.412303% | 1 |  |
| 418 | `tests/e2e/m2/test_node_editor.py::test_node_call_rejects_resource_before_first_load` | passed | 0.019913 | 0.027737 | 0.171785 | 0.219436 | 0.054665% | 94.466968% | 6 |  |
| 419 | `tests/e2e/m6/test_network_request.py::test_rejected_url_credentials_are_not_readable_in_audit[http://audit-user:{secret}/path@host/]` | passed | 0.032072 | 0.103791 | 0.079718 | 0.215581 | 0.053705% | 94.520673% | 3 |  |
| 420 | `tests/e2e/m2/test_m2_contract.py::test_error_codes_are_m1_standard` | passed | 0.021034 | 0.001162 | 0.192603 | 0.214799 | 0.053510% | 94.574184% | 5 |  |
| 421 | `tests/e2e/m2/test_scene_editor.py::test_scene_tree_matches_fixture` | passed | 0.021574 | 0.017590 | 0.172026 | 0.211190 | 0.052611% | 94.626795% | 6 |  |
| 422 | `tests/e2e/m6/test_network_request.py::test_redirect_credentials_follow_origin_boundary[return-to-origin]` | passed | 0.026556 | 0.089633 | 0.092021 | 0.208210 | 0.051869% | 94.678664% | 1 |  |
| 423 | `tests/e2e/m3/test_runtime_capture.py::test_frame_capture_returns_dict` | passed | 0.076486 | 0.130579 | 0.000218 | 0.207283 | 0.051638% | 94.730301% | 3 |  |
| 424 | `tests/e2e/m2/test_scene_editor.py::test_scene_current_returns_main_scene` | passed | 0.019354 | 0.023137 | 0.163890 | 0.206381 | 0.051413% | 94.781715% | 6 |  |
| 425 | `tests/e2e/test_m1_smoke.py::TestRouteNamespace::test_removed_aliases_are_not_exposed` | passed | 0.000475 | 0.204635 | 0.000391 | 0.205501 | 0.051194% | 94.832909% | 6 |  |
| 426 | `tests/e2e/m3/test_runtime_extensions.py::test_png_comparison_rejects_invalid_boundaries[payload3]` | passed | 0.114333 | 0.090882 | 0.000259 | 0.205474 | 0.051187% | 94.884096% | 4 |  |
| 427 | `tests/e2e/m6/test_process_run.py::test_process_spawn_failure_is_audited_as_failure` | passed | 0.024087 | 0.114000 | 0.067158 | 0.205245 | 0.051130% | 94.935227% | 3 |  |
| 428 | `tests/e2e/m6/test_runtime_eval.py::test_runtime_eval_requires_running_probe` | passed | 0.033746 | 0.095720 | 0.074304 | 0.203771 | 0.050763% | 94.985990% | 3 |  |
| 429 | `tests/e2e/m6/test_network_request.py::test_rejected_url_credentials_are_not_readable_in_audit[http://audit-user?{secret}@host/path]` | passed | 0.028007 | 0.102345 | 0.073009 | 0.203361 | 0.050661% | 95.036651% | 3 |  |
| 430 | `tests/e2e/m6/test_network_request.py::test_redirect_uri_reference_reaches_resolved_path[/next?return=http://example.invalid/-/next?return=http://example.invalid/]` | passed | 0.030216 | 0.080620 | 0.091545 | 0.202382 | 0.050417% | 95.087068% | 1 |  |
| 431 | `tests/e2e/m6/test_network_request.py::test_redirect_uri_reference_reaches_resolved_path[/a//b-/a//b]` | passed | 0.028379 | 0.080918 | 0.091332 | 0.200629 | 0.049980% | 95.137048% | 1 |  |
| 432 | `tests/e2e/m6/test_network_request.py::test_rejected_url_credentials_are_not_readable_in_audit[http:username:{secret}@host/path]` | passed | 0.028965 | 0.099578 | 0.070419 | 0.198962 | 0.049565% | 95.186613% | 3 |  |
| 433 | `tests/e2e/m6/test_network_request.py::test_redirect_uri_reference_reaches_resolved_path[next-/dir/next]` | passed | 0.023052 | 0.080909 | 0.094576 | 0.198537 | 0.049459% | 95.236072% | 1 |  |
| 434 | `tests/e2e/m3/test_runtime_nodes.py::test_runtime_node_call_allowlist` | passed | 0.104008 | 0.093055 | 0.000341 | 0.197404 | 0.049177% | 95.285249% | 4 |  |
| 435 | `tests/e2e/m3/test_runtime_nodes.py::test_runtime_fixed_fixture_identity_rejects_destructive_mutations[runtime/node/reparent-payload2]` | passed | 0.061762 | 0.134140 | 0.000236 | 0.196138 | 0.048861% | 95.334111% | 5 |  |
| 436 | `tests/e2e/m3/test_runtime_nodes.py::test_runtime_fixed_fixture_identity_rejects_destructive_mutations[runtime/node/rename-payload1]` | passed | 0.070187 | 0.124970 | 0.000229 | 0.195386 | 0.048674% | 95.382785% | 5 |  |
| 437 | `tests/e2e/m3/test_runtime_nodes.py::test_runtime_fixed_fixture_identity_rejects_destructive_mutations[runtime/node/duplicate-payload0]` | passed | 0.063926 | 0.129812 | 0.000271 | 0.194009 | 0.048331% | 95.431116% | 5 |  |
| 438 | `tests/e2e/m6/test_bulk_files.py::test_replace_rolls_back_when_second_apply_fails` | passed | 0.019287 | 0.110294 | 0.062223 | 0.191804 | 0.047782% | 95.478898% | 3 |  |
| 439 | `tests/e2e/m3/test_runtime_observability.py::test_debug_breakpoints_returns_not_supported` | passed | 0.100617 | 0.089614 | 0.000232 | 0.190464 | 0.047448% | 95.526346% | 4 |  |
| 440 | `tests/e2e/m3/test_runtime_input.py::test_input_sequence_rejects_too_many_events` | passed | 0.097790 | 0.092242 | 0.000211 | 0.190244 | 0.047393% | 95.573739% | 4 |  |
| 441 | `tests/e2e/m6/test_network_request.py::test_rejected_url_credentials_are_not_readable_in_audit[http://audit-user#{secret}@host/path]` | passed | 0.025296 | 0.101844 | 0.062430 | 0.189570 | 0.047225% | 95.620964% | 3 |  |
| 442 | `tests/e2e/m6/test_network_request.py::test_redirect_credentials_follow_origin_boundary[cross-port]` | passed | 0.022287 | 0.079477 | 0.086489 | 0.188253 | 0.046897% | 95.667862% | 1 |  |
| 443 | `tests/e2e/m6/test_network_request.py::test_redirect_credentials_follow_origin_boundary[same-origin-query]` | passed | 0.022787 | 0.076034 | 0.085785 | 0.184606 | 0.045989% | 95.713850% | 1 |  |
| 444 | `tests/e2e/m3/test_runtime_nodes.py::test_runtime_node_get_unknown_property` | passed | 0.097458 | 0.085281 | 0.000254 | 0.182992 | 0.045587% | 95.759437% | 4 |  |
| 445 | `tests/e2e/m3/test_runtime_capture.py::test_viewport_capture_is_valid_png` | passed | 0.081600 | 0.100585 | 0.000206 | 0.182392 | 0.045437% | 95.804874% | 3 |  |
| 446 | `tests/e2e/m3/test_runtime_extensions.py::test_png_comparison_rejects_invalid_boundaries[payload0]` | passed | 0.097958 | 0.084016 | 0.000262 | 0.182236 | 0.045398% | 95.850272% | 4 |  |
| 447 | `tests/e2e/m6/test_network_request.py::test_ipv4_embedded_ipv6_literals_compare_canonically` | passed | 0.026303 | 0.068546 | 0.086224 | 0.181072 | 0.045108% | 95.895381% | 1 |  |
| 448 | `tests/e2e/m3/test_runtime_nodes.py::test_runtime_tree_root_name` | passed | 0.107607 | 0.072558 | 0.000304 | 0.180470 | 0.044958% | 95.940339% | 3 |  |
| 449 | `tests/e2e/m6/test_bulk_files.py::test_replace_plan_hash_binds_find_and_replace` | passed | 0.021352 | 0.093409 | 0.064555 | 0.179316 | 0.044671% | 95.985010% | 3 |  |
| 450 | `tests/e2e/m3/test_runtime_observability.py::test_runtime_log_read_returns_initial_empty` | passed | 0.109380 | 0.069467 | 0.000302 | 0.179149 | 0.044629% | 96.029639% | 3 |  |
| 451 | `tests/e2e/m6/test_eval.py::test_eval_rejects_object_encodings[True-Object]` | passed | 0.025254 | 0.079105 | 0.074179 | 0.178538 | 0.044477% | 96.074116% | 2 |  |
| 452 | `tests/e2e/m3/test_runtime_nodes.py::test_runtime_node_create_returns_dedicated_game_node` | passed | 0.072709 | 0.103106 | 0.000246 | 0.176062 | 0.043860% | 96.117977% | 4 |  |
| 453 | `tests/e2e/m3/test_runtime_extensions.py::test_png_comparison_rejects_invalid_boundaries[payload2]` | passed | 0.079144 | 0.095090 | 0.000368 | 0.174602 | 0.043497% | 96.161473% | 4 |  |
| 454 | `tests/e2e/test_m1_scene_safety.py::test_scene_load_sprite_reports_missing_texture` | passed | 0.001345 | 0.169976 | 0.001723 | 0.173044 | 0.043108% | 96.204582% | 3 |  |
| 455 | `tests/e2e/m3/test_runtime_extensions.py::test_png_comparison_rejects_invalid_boundaries[payload1]` | passed | 0.084614 | 0.087861 | 0.000313 | 0.172788 | 0.043045% | 96.247626% | 4 |  |
| 456 | `tests/e2e/m3/test_runtime_nodes.py::test_runtime_node_find_by_name` | passed | 0.106934 | 0.065349 | 0.000299 | 0.172582 | 0.042993% | 96.290620% | 3 |  |
| 457 | `tests/e2e/m3/test_runtime_nodes.py::test_runtime_node_get_set_call` | passed | 0.102540 | 0.069532 | 0.000417 | 0.172489 | 0.042970% | 96.333590% | 3 |  |
| 458 | `tests/e2e/m6/test_network_request.py::test_audit_redacts_body_and_headers` | passed | 0.025277 | 0.085857 | 0.060490 | 0.171625 | 0.042755% | 96.376345% | 2 |  |
| 459 | `tests/e2e/m3/test_runtime_extensions.py::test_recording_event_bounds[payload2]` | passed | 0.078917 | 0.090510 | 0.000254 | 0.169681 | 0.042271% | 96.418615% | 4 |  |
| 460 | `tests/e2e/m6/test_network_request.py::test_redirect_without_location_is_malformed` | passed | 0.029397 | 0.062238 | 0.077908 | 0.169543 | 0.042236% | 96.460851% | 2 |  |
| 461 | `tests/e2e/m6/test_network_request.py::test_redirect_credentials_follow_origin_boundary[same-origin]` | passed | 0.024263 | 0.057085 | 0.086890 | 0.168238 | 0.041911% | 96.502763% | 1 |  |
| 462 | `tests/e2e/m3/test_runtime_capture.py::test_camera_path_is_strictly_validated[payload2-invalid_param]` | passed | 0.075724 | 0.092031 | 0.000236 | 0.167992 | 0.041850% | 96.544613% | 4 |  |
| 463 | `tests/e2e/m3/test_runtime_capture.py::test_camera_path_is_strictly_validated[payload1-not_found]` | passed | 0.078635 | 0.088321 | 0.000229 | 0.167185 | 0.041649% | 96.586261% | 4 |  |
| 464 | `tests/e2e/m3/test_runtime_extensions.py::test_qa_does_not_bypass_capability_boundaries[payload2]` | passed | 0.075793 | 0.090919 | 0.000234 | 0.166946 | 0.041589% | 96.627851% | 4 |  |
| 465 | `tests/e2e/m3/test_runtime_nodes.py::test_runtime_fixed_fixture_identity_rejects_destructive_mutations[runtime/node/remove-payload3]` | passed | 0.061343 | 0.104854 | 0.000627 | 0.166824 | 0.041559% | 96.669410% | 5 |  |
| 466 | `tests/e2e/m6/test_eval.py::test_eval_rejects_object_encodings[True-RID]` | passed | 0.025761 | 0.074176 | 0.066452 | 0.166388 | 0.041450% | 96.710860% | 2 |  |
| 467 | `tests/e2e/m6/test_eval.py::test_eval_rejects_object_encodings[True-PackedScene]` | passed | 0.023869 | 0.070722 | 0.070502 | 0.165093 | 0.041128% | 96.751988% | 2 |  |
| 468 | `tests/e2e/m6/test_eval.py::test_eval_rejects_object_encodings[True-Resource]` | passed | 0.025144 | 0.066712 | 0.073016 | 0.164872 | 0.041073% | 96.793060% | 2 |  |
| 469 | `tests/e2e/m6/test_network_request.py::test_not_modified_is_successful_response` | passed | 0.025548 | 0.057153 | 0.081393 | 0.164094 | 0.040879% | 96.833939% | 1 |  |
| 470 | `tests/e2e/m3/test_runtime_observability.py::test_debug_errors_preserves_v1_empty_list` | passed | 0.100059 | 0.063671 | 0.000272 | 0.164002 | 0.040856% | 96.874795% | 3 |  |
| 471 | `tests/e2e/m3/test_runtime_nodes.py::test_runtime_node_info` | passed | 0.100204 | 0.063353 | 0.000272 | 0.163829 | 0.040813% | 96.915608% | 3 |  |
| 472 | `tests/e2e/m6/test_eval.py::test_eval_rejects_object_encodings[False-RID]` | passed | 0.025486 | 0.063509 | 0.074365 | 0.163360 | 0.040696% | 96.956303% | 2 |  |
| 473 | `tests/e2e/m6/test_eval.py::test_eval_rejects_object_encodings[True-GDScript]` | passed | 0.027763 | 0.056562 | 0.075583 | 0.159909 | 0.039836% | 96.996140% | 2 |  |
| 474 | `tests/e2e/m6/test_eval.py::test_eval_rejects_object_encodings[True-Signal]` | passed | 0.029223 | 0.059697 | 0.067805 | 0.156725 | 0.039043% | 97.035183% | 2 |  |
| 475 | `tests/e2e/m3/test_runtime_capture.py::test_camera_capture_invalid_node_returns_invalid_param` | passed | 0.067785 | 0.088608 | 0.000226 | 0.156620 | 0.039017% | 97.074200% | 4 |  |
| 476 | `tests/e2e/m6/test_eval.py::test_eval_rejects_object_encodings[False-PackedScene]` | passed | 0.027817 | 0.063968 | 0.064635 | 0.156420 | 0.038967% | 97.113167% | 2 |  |
| 477 | `tests/e2e/m3/test_runtime_extensions.py::test_qa_does_not_bypass_capability_boundaries[payload1]` | passed | 0.068024 | 0.087058 | 0.000376 | 0.155459 | 0.038728% | 97.151894% | 4 |  |
| 478 | `tests/e2e/m6/test_network_request.py::test_ipv6_equivalent_literal_keeps_same_origin_credentials` | skipped | 0.025371 | 0.067874 | 0.062021 | 0.155266 | 0.038679% | 97.190574% | 1 | 条件跳过；保留实测阶段耗时 |
| 479 | `tests/e2e/m3/test_runtime_extensions.py::test_recording_event_bounds[payload1]` | passed | 0.077296 | 0.077426 | 0.000241 | 0.154963 | 0.038604% | 97.229178% | 4 |  |
| 480 | `tests/e2e/m6/test_bulk_files.py::test_stale_plan_returns_conflict` | passed | 0.021947 | 0.064272 | 0.068463 | 0.154682 | 0.038534% | 97.267712% | 2 |  |
| 481 | `tests/e2e/m6/test_eval.py::test_eval_rejects_object_encodings[False-Callable]` | passed | 0.027179 | 0.064417 | 0.062666 | 0.154262 | 0.038429% | 97.306141% | 2 |  |
| 482 | `tests/e2e/m3/test_runtime_capture.py::test_frame_parameters_reject_before_capture[payload0]` | passed | 0.076188 | 0.077798 | 0.000230 | 0.154216 | 0.038418% | 97.344559% | 4 |  |
| 483 | `tests/e2e/m3/test_runtime_capture.py::test_camera_path_is_strictly_validated[payload0-invalid_param]` | passed | 0.075774 | 0.077688 | 0.000267 | 0.153729 | 0.038297% | 97.382856% | 4 |  |
| 484 | `tests/e2e/m3/test_runtime_capture.py::test_camera_path_is_strictly_validated[payload3-invalid_param]` | passed | 0.066930 | 0.084532 | 0.000276 | 0.151739 | 0.037801% | 97.420657% | 4 |  |
| 485 | `tests/e2e/m6/test_eval.py::test_eval_rejects_object_encodings[True-Callable]` | passed | 0.027470 | 0.058342 | 0.065783 | 0.151596 | 0.037765% | 97.458422% | 2 |  |
| 486 | `tests/e2e/m6/test_eval.py::test_eval_rejects_object_encodings[False-GDScript]` | passed | 0.027006 | 0.056783 | 0.065201 | 0.148990 | 0.037116% | 97.495538% | 2 |  |
| 487 | `tests/e2e/m6/test_eval.py::test_eval_rejects_object_encodings[False-Object]` | passed | 0.022162 | 0.066278 | 0.059943 | 0.148383 | 0.036965% | 97.532503% | 2 |  |
| 488 | `tests/e2e/m6/test_eval.py::test_eval_rejects_object_encodings[False-Signal]` | passed | 0.021739 | 0.054598 | 0.071660 | 0.147997 | 0.036869% | 97.569372% | 2 |  |
| 489 | `tests/e2e/m3/test_runtime_extensions.py::test_recording_event_bounds[payload0]` | passed | 0.067729 | 0.077965 | 0.000277 | 0.145971 | 0.036364% | 97.605736% | 4 |  |
| 490 | `tests/e2e/test_edit_action.py::test_edit_action_commit_property_undo_redo` | passed | 0.000279 | 0.141928 | 0.000147 | 0.142354 | 0.035463% | 97.641199% | 5 |  |
| 491 | `tests/e2e/m6/test_network_request.py::test_network_request_redirect_is_followed` | passed | 0.022414 | 0.062163 | 0.056740 | 0.141317 | 0.035205% | 97.676403% | 1 |  |
| 492 | `tests/e2e/m3/test_runtime_capture.py::test_frame_parameters_reject_before_capture[payload5]` | passed | 0.048947 | 0.091998 | 0.000249 | 0.141194 | 0.035174% | 97.711577% | 4 |  |
| 493 | `tests/e2e/m6/test_eval.py::test_editor_eval_deny[instance_from_id(1)-inputs0]` | passed | 0.022935 | 0.056731 | 0.061196 | 0.140863 | 0.035092% | 97.746669% | 2 |  |
| 494 | `tests/e2e/m3/test_runtime_capture.py::test_frame_limits_over_sixty_returns_invalid_param` | passed | 0.048825 | 0.090710 | 0.000232 | 0.139767 | 0.034819% | 97.781488% | 4 |  |
| 495 | `tests/e2e/m6/test_eval.py::test_editor_eval_deny[a = b-inputs2]` | passed | 0.022668 | 0.053856 | 0.063158 | 0.139682 | 0.034797% | 97.816285% | 2 |  |
| 496 | `tests/e2e/m3/test_runtime_capture.py::test_frame_parameters_reject_before_capture[payload2]` | passed | 0.050899 | 0.088190 | 0.000223 | 0.139312 | 0.034705% | 97.850990% | 4 |  |
| 497 | `tests/e2e/m6/test_eval.py::test_eval_source_never_appears_in_audit` | passed | 0.026783 | 0.050398 | 0.061858 | 0.139039 | 0.034637% | 97.885627% | 2 |  |
| 498 | `tests/e2e/m3/test_runtime_observability.py::test_debug_performance_returns_values` | passed | 0.068662 | 0.070004 | 0.000323 | 0.138989 | 0.034625% | 97.920252% | 3 |  |
| 499 | `tests/e2e/m6/test_eval.py::test_editor_eval_deny[Engine-inputs1]` | passed | 0.021994 | 0.057148 | 0.059120 | 0.138262 | 0.034444% | 97.954695% | 2 |  |
| 500 | `tests/e2e/m3/test_runtime_observability.py::test_debug_monitors_returns_known_keys` | passed | 0.063791 | 0.072682 | 0.000327 | 0.136800 | 0.034079% | 97.988775% | 3 |  |
| 501 | `tests/e2e/m6/test_network_request.py::test_redirect_loop_is_rejected` | passed | 0.023026 | 0.055835 | 0.056788 | 0.135649 | 0.033793% | 98.022567% | 2 |  |
| 502 | `tests/e2e/m6/test_network_request.py::test_response_cap_truncates_or_errors` | passed | 0.022503 | 0.052011 | 0.058843 | 0.133357 | 0.033222% | 98.055789% | 1 |  |
| 503 | `tests/e2e/m3/test_runtime_extensions.py::test_qa_does_not_bypass_capability_boundaries[payload0]` | passed | 0.063630 | 0.069216 | 0.000188 | 0.133034 | 0.033141% | 98.088930% | 4 |  |
| 504 | `tests/e2e/m6/test_eval.py::test_eval_rejects_object_encodings[False-Resource]` | passed | 0.024384 | 0.041575 | 0.063854 | 0.129813 | 0.032339% | 98.121269% | 2 |  |
| 505 | `tests/e2e/m6/test_eval.py::test_editor_eval_allow[a <= b and a != 0-inputs1-True]` | passed | 0.025733 | 0.034145 | 0.065798 | 0.125676 | 0.031308% | 98.152577% | 1 |  |
| 506 | `tests/e2e/m6/test_eval.py::test_editor_eval_deny[a.b-inputs3]` | passed | 0.022613 | 0.040122 | 0.061042 | 0.123777 | 0.030835% | 98.183413% | 2 |  |
| 507 | `tests/e2e/m3/test_runtime_capture.py::test_frame_parameters_reject_before_capture[payload4]` | passed | 0.069087 | 0.052741 | 0.000225 | 0.122052 | 0.030405% | 98.213818% | 4 |  |
| 508 | `tests/e2e/test_m1_scene_safety.py::test_scene_save_overwrites_existing_destination` | passed | 0.002031 | 0.117792 | 0.001267 | 0.121090 | 0.030166% | 98.243984% | 2 |  |
| 509 | `tests/e2e/test_m1_scene_safety.py::test_scene_mutation_success_is_audited` | passed | 0.001265 | 0.118413 | 0.001356 | 0.121033 | 0.030152% | 98.274135% | 3 |  |
| 510 | `tests/e2e/m6/test_eval.py::test_editor_eval_allow[a-inputs4-expected4]` | passed | 0.027845 | 0.031105 | 0.060085 | 0.119034 | 0.029654% | 98.303789% | 1 |  |
| 511 | `tests/e2e/m6/test_eval.py::test_editor_eval_allow[Vector2(a, b) + Vector2(1, 1)-inputs2-expected2]` | passed | 0.024475 | 0.033146 | 0.058125 | 0.115745 | 0.028834% | 98.332623% | 1 |  |
| 512 | `tests/e2e/test_m1_scene_safety.py::test_scene_add_node_decodes_vector2` | passed | 0.001050 | 0.113125 | 0.001047 | 0.115221 | 0.028704% | 98.361327% | 2 |  |
| 513 | `tests/e2e/m6/test_eval.py::test_editor_eval_allow[a + b-inputs0-3]` | passed | 0.025209 | 0.025370 | 0.062133 | 0.112712 | 0.028079% | 98.389406% | 1 |  |
| 514 | `tests/e2e/m6/test_eval.py::test_editor_eval_allow[a-inputs3-expected3]` | passed | 0.022885 | 0.026416 | 0.061595 | 0.110895 | 0.027626% | 98.417032% | 1 |  |
| 515 | `tests/e2e/test_m1_scene_safety.py::test_scene_create_overwrites_existing_target` | passed | 0.001725 | 0.104563 | 0.001152 | 0.107440 | 0.026765% | 98.443797% | 2 |  |
| 516 | `tests/e2e/m3/test_runtime_capture.py::test_frame_parameters_reject_before_capture[payload3]` | passed | 0.044823 | 0.060413 | 0.000203 | 0.105439 | 0.026267% | 98.470064% | 4 |  |
| 517 | `tests/e2e/m3/test_harness.py::test_wait_for_editor_playing_waits_for_editor_flag` | passed | 0.001716 | 0.100744 | 0.000250 | 0.102709 | 0.025587% | 98.495650% | 0 |  |
| 518 | `tests/e2e/m3/test_harness.py::test_readiness_failure_preserves_last_runtime_status_payload` | passed | 0.001775 | 0.100729 | 0.000183 | 0.102686 | 0.025581% | 98.521231% | 0 |  |
| 519 | `tests/e2e/test_m1_scene_safety.py::test_scene_add_node_succeeds` | passed | 0.000980 | 0.099636 | 0.001553 | 0.102169 | 0.025452% | 98.546684% | 2 |  |
| 520 | `tests/e2e/m6/test_m6_contract.py::test_m6_route_docs_are_complete[runtime/eval]` | passed | 0.020229 | 0.024431 | 0.057163 | 0.101823 | 0.025366% | 98.572049% | 1 |  |
| 521 | `tests/e2e/m6/test_m6_contract.py::test_m6_route_no_longer_requires_policy[filesystem/batch/delete]` | passed | 0.019218 | 0.023943 | 0.053795 | 0.096956 | 0.024154% | 98.596203% | 1 |  |
| 522 | `tests/e2e/m6/test_m6_contract.py::test_m6_route_no_longer_requires_policy[editor/eval]` | passed | 0.022411 | 0.025513 | 0.048956 | 0.096881 | 0.024135% | 98.620338% | 1 |  |
| 523 | `tests/e2e/m6/test_m6_contract.py::test_m6_route_no_longer_requires_policy[process/run]` | passed | 0.021356 | 0.025117 | 0.049705 | 0.096179 | 0.023960% | 98.644298% | 1 |  |
| 524 | `tests/e2e/m6/test_m6_contract.py::test_m6_route_docs_are_complete[process/run]` | passed | 0.019363 | 0.029038 | 0.047750 | 0.096151 | 0.023953% | 98.668250% | 1 |  |
| 525 | `tests/e2e/m6/test_m6_contract.py::test_m6_route_docs_are_complete[filesystem/batch/recover]` | passed | 0.017755 | 0.027522 | 0.048853 | 0.094130 | 0.023450% | 98.691700% | 1 |  |
| 526 | `tests/e2e/m3/test_runtime_nodes.py::test_shared_data_plane_stays_within_process_and_recovery_budget` | passed | 0.092873 | 0.000324 | 0.000170 | 0.093367 | 0.023259% | 98.714959% | 2 |  |
| 527 | `tests/e2e/m3/test_runtime_capture.py::test_frame_parameters_reject_before_capture[payload1]` | passed | 0.045251 | 0.047193 | 0.000196 | 0.092640 | 0.023078% | 98.738038% | 4 |  |
| 528 | `tests/e2e/m6/test_m6_contract.py::test_m6_route_docs_are_complete[filesystem/batch/delete]` | passed | 0.018489 | 0.025593 | 0.048011 | 0.092093 | 0.022942% | 98.760980% | 1 |  |
| 529 | `tests/e2e/m6/test_m6_contract.py::test_m6_route_no_longer_requires_policy[filesystem/batch/recover]` | passed | 0.016023 | 0.024131 | 0.051170 | 0.091324 | 0.022750% | 98.783730% | 1 |  |
| 530 | `tests/e2e/m6/test_m6_contract.py::test_m6_route_docs_are_complete[network/http_request]` | passed | 0.018033 | 0.028237 | 0.044757 | 0.091027 | 0.022677% | 98.806407% | 1 |  |
| 531 | `tests/e2e/m6/test_m6_contract.py::test_m6_route_no_longer_requires_policy[filesystem/batch/replace]` | passed | 0.019097 | 0.021328 | 0.048996 | 0.089422 | 0.022277% | 98.828683% | 1 |  |
| 532 | `tests/e2e/m6/test_m6_contract.py::test_m6_route_docs_are_complete[filesystem/batch/replace]` | passed | 0.018273 | 0.025169 | 0.045842 | 0.089284 | 0.022242% | 98.850926% | 1 |  |
| 533 | `tests/e2e/m6/test_m6_contract.py::test_m6_route_no_longer_requires_policy[runtime/eval]` | passed | 0.016353 | 0.026844 | 0.045330 | 0.088527 | 0.022054% | 98.872979% | 1 |  |
| 534 | `tests/e2e/m6/test_m6_contract.py::test_m6_route_no_longer_requires_policy[network/http_request]` | passed | 0.019667 | 0.023228 | 0.044481 | 0.087376 | 0.021767% | 98.894746% | 1 |  |
| 535 | `tests/e2e/m6/test_m6_contract.py::test_m6_route_docs_are_complete[editor/eval]` | passed | 0.015858 | 0.016121 | 0.049143 | 0.081122 | 0.020209% | 98.914955% | 1 |  |
| 536 | `tests/e2e/m3/test_m3_contract.py::test_failed_cli_diagnostics_include_runtime_context` | passed | 0.000633 | 0.074186 | 0.000254 | 0.075074 | 0.018702% | 98.933658% | 2 |  |
| 537 | `tests/e2e/test_m1_contracts.py::test_all_command_docs_are_complete` | passed | 0.000327 | 0.071619 | 0.000169 | 0.072115 | 0.017965% | 98.951623% | 2 |  |
| 538 | `tests/e2e/test_m1_smoke.py::TestCommandsMetadata::test_commands_list_includes_m1_baseline` | passed | 0.000448 | 0.062734 | 0.000327 | 0.063509 | 0.015821% | 98.967444% | 1 |  |
| 539 | `tests/e2e/test_m1_smoke.py::TestAuditLog::test_audit_list_returns_entries` | passed | 0.000416 | 0.057840 | 0.000225 | 0.058482 | 0.014569% | 98.982013% | 2 |  |
| 540 | `tests/e2e/test_m1_contracts.py::test_audit_clear_records_public_route` | passed | 0.000487 | 0.057081 | 0.000249 | 0.057818 | 0.014403% | 98.996416% | 2 |  |
| 541 | `tests/e2e/test_m1_scene_safety.py::test_mesh_library_invalid_source_is_not_force_gated` | passed | 0.001535 | 0.049993 | 0.002220 | 0.053748 | 0.013390% | 99.009806% | 1 |  |
| 542 | `tests/e2e/test_m1_contracts.py::test_literal_route_error_codes_are_standard` | passed | 0.000317 | 0.050625 | 0.000154 | 0.051096 | 0.012729% | 99.022535% | 0 |  |
| 543 | `tests/e2e/test_m1_smoke.py::TestPathGuard::test_absolute_path_rejected` | passed | 0.000352 | 0.046055 | 0.000723 | 0.047130 | 0.011741% | 99.034276% | 1 |  |
| 544 | `tests/e2e/test_shared_editor_lifecycle.py::test_file_baseline_restores_mutations_without_touching_excluded_state` | passed | 0.001878 | 0.043258 | 0.000255 | 0.045391 | 0.011308% | 99.045584% | 0 |  |
| 545 | `tests/e2e/test_m1_smoke.py::TestPathGuard::test_res_path_accepted` | passed | 0.000493 | 0.044053 | 0.000327 | 0.044873 | 0.011179% | 99.056763% | 1 |  |
| 546 | `tests/e2e/test_m1_smoke.py::TestPathGuard::test_path_traversal_rejected` | passed | 0.000524 | 0.041668 | 0.000249 | 0.042441 | 0.010573% | 99.067335% | 1 |  |
| 547 | `tests/e2e/test_m1_smoke.py::test_uid_update_protects_metadata_directory` | passed | 0.000518 | 0.038635 | 0.000333 | 0.039486 | 0.009837% | 99.077172% | 1 |  |
| 548 | `tests/e2e/test_m1_smoke.py::TestPathGuard::test_relative_path_normalized` | passed | 0.000537 | 0.035601 | 0.000299 | 0.036437 | 0.009077% | 99.086249% | 1 |  |
| 549 | `tests/e2e/test_m1_smoke.py::test_uid_update_without_force` | passed | 0.000273 | 0.035219 | 0.000322 | 0.035814 | 0.008922% | 99.095171% | 1 |  |
| 550 | `tests/e2e/test_m1_smoke.py::TestConnectivity::test_ping_contains_editor_version` | passed | 0.000402 | 0.028535 | 0.000299 | 0.029236 | 0.007283% | 99.102454% | 1 |  |
| 551 | `tests/e2e/test_m1_smoke.py::test_pathcheck_rejects_unknown_mode` | passed | 0.000372 | 0.028481 | 0.000217 | 0.029071 | 0.007242% | 99.109696% | 1 |  |
| 552 | `tests/e2e/test_m1_smoke.py::TestConnectivity::test_ping_contains_gdapi_version` | passed | 0.000352 | 0.027580 | 0.000298 | 0.028229 | 0.007032% | 99.116729% | 1 |  |
| 553 | `tests/e2e/test_m1_smoke.py::TestConnectivity::test_ping` | passed | 0.000479 | 0.027196 | 0.000320 | 0.027995 | 0.006974% | 99.123703% | 1 |  |
| 554 | `tests/e2e/test_m1_smoke.py::TestRouteNamespace::test_routes_include_m1_baseline` | passed | 0.000381 | 0.026817 | 0.000220 | 0.027418 | 0.006830% | 99.130533% | 1 |  |
| 555 | `tests/e2e/test_m1_smoke.py::TestAuditLog::test_audit_clear_without_force` | passed | 0.000479 | 0.025857 | 0.000239 | 0.026575 | 0.006620% | 99.137153% | 1 |  |
| 556 | `tests/e2e/m3/test_runtime_status.py::test_runtime_status_doc_has_returns` | passed | 0.000418 | 0.024279 | 0.000194 | 0.024890 | 0.006201% | 99.143354% | 1 |  |
| 557 | `tests/e2e/test_e2e_ping.py::TestPing::test_exec_ping_ok` | passed | 0.000246 | 0.019081 | 0.000161 | 0.019488 | 0.004855% | 99.148209% | 1 |  |
| 558 | `tests/e2e/test_gate_timing.py::test_history_bridge_records_only_completed_success` | passed | 0.002032 | 0.014485 | 0.000162 | 0.016679 | 0.004155% | 99.152364% | 0 |  |
| 559 | `tests/e2e/test_shared_editor_lifecycle.py::test_reset_skips_stop_when_game_is_known_detached` | passed | 0.011601 | 0.002904 | 0.000200 | 0.014705 | 0.003663% | 99.156027% | 0 |  |
| 560 | `tests/e2e/test_e2e_ping.py::TestPing::test_exec_ping_returns_gdapi_version` | passed | 0.000290 | 0.014227 | 0.000148 | 0.014665 | 0.003653% | 99.159680% | 1 |  |
| 561 | `tests/e2e/test_fixture_harness.py::test_source_fixture_teardown_removes_only_runtime_transport_root` | passed | 0.010340 | 0.003169 | 0.000119 | 0.013628 | 0.003395% | 99.163075% | 0 |  |
| 562 | `tests/e2e/test_e2e_ping.py::TestPing::test_exec_ping_returns_editor_version` | passed | 0.000299 | 0.012727 | 0.000154 | 0.013180 | 0.003283% | 99.166358% | 1 |  |
| 563 | `tests/e2e/test_e2e_ping.py::TestPing::test_exec_ping_too_many_args_rejected` | passed | 0.000253 | 0.012600 | 0.000150 | 0.013002 | 0.003239% | 99.169597% | 1 |  |
| 564 | `tests/e2e/test_shared_editor_lifecycle.py::test_reset_shared_state_reports_failing_phase` | passed | 0.002134 | 0.008416 | 0.000293 | 0.010844 | 0.002701% | 99.172299% | 0 |  |
| 565 | `tests/e2e/test_gate_timing.py::test_budget_boundary_preserves_only_successful_measurements` | passed | 0.001925 | 0.008237 | 0.000175 | 0.010337 | 0.002575% | 99.174874% | 0 |  |
| 566 | `tests/e2e/test_gate_timing.py::test_percentiles_and_json_preserve_success_samples` | passed | 0.001458 | 0.007563 | 0.000227 | 0.009248 | 0.002304% | 99.177178% | 0 |  |
| 567 | `tests/e2e/test_gate_timing.py::test_budget_uses_parent_wall_clock_not_child_summary` | passed | 0.001884 | 0.006729 | 0.000160 | 0.008773 | 0.002185% | 99.179363% | 0 |  |
| 568 | `tests/e2e/test_shared_editor_lifecycle.py::test_start_editor_terminates_process_when_readiness_fails` | passed | 0.002566 | 0.002918 | 0.000351 | 0.005835 | 0.001454% | 99.180817% | 0 |  |
| 569 | `tests/e2e/m3/test_runtime_nodes.py::test_scene_node_routes_use_runtime_adapter_without_local_ops_load` | passed | 0.000399 | 0.003956 | 0.000153 | 0.004508 | 0.001123% | 99.181940% | 0 |  |
| 570 | `tests/e2e/test_shared_editor_lifecycle.py::test_build_editor_environment_isolates_godot_user_data` | passed | 0.002157 | 0.001886 | 0.000280 | 0.004324 | 0.001077% | 99.183017% | 0 |  |
| 571 | `tests/e2e/test_gate_timing.py::test_budget_rejects_child_failure_and_multiple_editors[0-2]` | passed | 0.001805 | 0.002102 | 0.000217 | 0.004124 | 0.001027% | 99.184044% | 0 |  |
| 572 | `tests/e2e/m3/test_harness.py::test_failed_game_commands_do_not_increment_lifecycle_counters` | passed | 0.003036 | 0.000522 | 0.000500 | 0.004058 | 0.001011% | 99.185055% | 0 |  |
| 573 | `tests/e2e/test_fixture_harness.py::test_source_fixture_teardown_kills_hung_editor_before_cleanup` | passed | 0.001484 | 0.002239 | 0.000158 | 0.003881 | 0.000967% | 99.186022% | 0 |  |
| 574 | `tests/e2e/m3/test_harness.py::test_reset_recovery_restores_environment_but_fails_affected_test` | passed | 0.002575 | 0.000354 | 0.000219 | 0.003148 | 0.000784% | 99.186806% | 0 |  |
| 575 | `tests/e2e/test_gate_timing.py::test_mocked_waits_are_not_mixed_into_real_session_measurements` | passed | 0.000283 | 0.002729 | 0.000126 | 0.003137 | 0.000782% | 99.187588% | 0 |  |
| 576 | `tests/e2e/m3/test_harness.py::test_file_transport_reset_uses_public_broker_node_call` | passed | 0.002646 | 0.000248 | 0.000205 | 0.003099 | 0.000772% | 99.188360% | 0 |  |
| 577 | `tests/e2e/test_gate_timing.py::test_runner_orders_file_before_engine_and_stops_on_failure` | passed | 0.001710 | 0.001089 | 0.000107 | 0.002906 | 0.000724% | 99.189084% | 0 |  |
| 578 | `tests/e2e/test_gate_timing.py::test_budget_rejects_child_failure_and_multiple_editors[5-1]` | passed | 0.001815 | 0.000894 | 0.000141 | 0.002850 | 0.000710% | 99.189794% | 0 |  |
| 579 | `tests/e2e/test_gate_timing.py::test_runner_missing_executable_and_bad_configuration_are_nonzero` | passed | 0.001315 | 0.001419 | 0.000110 | 0.002843 | 0.000708% | 99.190502% | 0 |  |
| 580 | `tests/e2e/m3/test_harness.py::test_reset_failure_preserves_last_runtime_status_payload` | passed | 0.002300 | 0.000381 | 0.000159 | 0.002840 | 0.000708% | 99.191210% | 0 |  |
| 581 | `tests/e2e/m3/test_harness.py::test_detach_game_preserves_attachment_when_stale_cleanup_fails` | passed | 0.002313 | 0.000246 | 0.000151 | 0.002709 | 0.000675% | 99.191885% | 0 |  |
| 582 | `tests/e2e/m3/test_harness.py::test_detach_game_preserves_attachment_and_diagnostics_when_wait_fails` | passed | 0.001919 | 0.000222 | 0.000144 | 0.002284 | 0.000569% | 99.192454% | 0 |  |
| 583 | `tests/e2e/m3/test_runtime_observability.py::test_observability_routes_are_adapter_backed[runtime/debug/errors-False]` | passed | 0.000754 | 0.001075 | 0.000183 | 0.002012 | 0.000501% | 99.192955% | 0 |  |
| 584 | `tests/e2e/m3/test_runtime_observability.py::test_observability_routes_are_adapter_backed[runtime/log/clear-True]` | passed | 0.000900 | 0.000883 | 0.000168 | 0.001950 | 0.000486% | 99.193441% | 0 |  |
| 585 | `tests/e2e/m3/test_runtime_observability.py::test_observability_routes_are_adapter_backed[runtime/log/read-False]` | passed | 0.000702 | 0.001052 | 0.000155 | 0.001909 | 0.000475% | 99.193916% | 0 |  |
| 586 | `tests/e2e/m3/test_runtime_observability.py::test_observability_routes_are_adapter_backed[runtime/debug/performance-False]` | passed | 0.000661 | 0.001011 | 0.000144 | 0.001815 | 0.000452% | 99.194368% | 0 |  |
| 587 | `tests/e2e/test_unified_fixture_contract.py::test_unified_fixture_lists_every_required_path` | passed | 0.000379 | 0.001194 | 0.000114 | 0.001686 | 0.000420% | 99.194789% | 0 |  |
| 588 | `tests/e2e/m3/test_runtime_input.py::test_input_routes_are_adapter_backed_mutations[sequence]` | passed | 0.000519 | 0.000941 | 0.000225 | 0.001685 | 0.000420% | 99.195208% | 0 |  |
| 589 | `tests/e2e/m3/test_runtime_observability.py::test_observability_routes_are_adapter_backed[runtime/debug/breakpoints-False]` | passed | 0.000559 | 0.000937 | 0.000161 | 0.001657 | 0.000413% | 99.195621% | 0 |  |
| 590 | `tests/e2e/m3/test_harness.py::test_session_budget_accepts_single_start_and_rejects_recovery` | passed | 0.000672 | 0.000568 | 0.000284 | 0.001524 | 0.000380% | 99.196001% | 0 |  |
| 591 | `tests/e2e/m3/test_runtime_input.py::test_input_routes_are_adapter_backed_mutations[touch]` | passed | 0.000569 | 0.000723 | 0.000157 | 0.001448 | 0.000361% | 99.196361% | 0 |  |
| 592 | `tests/e2e/m3/test_runtime_observability.py::test_observability_routes_are_adapter_backed[runtime/debug/monitors-False]` | passed | 0.000504 | 0.000731 | 0.000174 | 0.001409 | 0.000351% | 99.196712% | 0 |  |
| 593 | `tests/e2e/m3/test_harness.py::test_project_run_uses_persistent_editor_play_service` | passed | 0.000552 | 0.000640 | 0.000123 | 0.001316 | 0.000328% | 99.197040% | 0 |  |
| 594 | `tests/e2e/m3/test_runtime_input.py::test_input_routes_are_adapter_backed_mutations[key]` | passed | 0.000494 | 0.000625 | 0.000192 | 0.001311 | 0.000327% | 99.197367% | 0 |  |
| 595 | `tests/e2e/m3/test_runtime_input.py::test_input_routes_are_adapter_backed_mutations[action]` | passed | 0.000377 | 0.000693 | 0.000205 | 0.001275 | 0.000318% | 99.197684% | 0 |  |
| 596 | `tests/e2e/test_unified_fixture_contract.py::test_unified_fixture_enables_test_plugin` | passed | 0.000095 | 0.000928 | 0.000171 | 0.001194 | 0.000298% | 99.197982% | 0 |  |
| 597 | `tests/e2e/test_gate_timing.py::test_editor_mode_rejects_unknown_values[]` | passed | 0.000681 | 0.000329 | 0.000137 | 0.001147 | 0.000286% | 99.198268% | 0 |  |
| 598 | `tests/e2e/m3/test_runtime_input.py::test_input_routes_are_adapter_backed_mutations[mouse]` | passed | 0.000434 | 0.000525 | 0.000105 | 0.001064 | 0.000265% | 99.198533% | 0 |  |
| 599 | `tests/e2e/test_gate_timing.py::test_lifecycle_waits_measure_only_the_accepted_status[wait_for_connected-runtime_connect-GDAPI_E2E_CONNECT_TIMEOUT_SECONDS-first1-last1]` | passed | 0.000630 | 0.000191 | 0.000196 | 0.001017 | 0.000253% | 99.198786% | 0 |  |
| 600 | `tests/e2e/m3/test_runtime_input.py::test_fixture_reset_releases_action_edge_state` | passed | 0.000362 | 0.000498 | 0.000129 | 0.000990 | 0.000247% | 99.199033% | 0 |  |
| 601 | `tests/e2e/test_version_gate.py::test_require_godot_47_rejects_old_or_invalid[4.6.3.stable]` | passed | 0.000374 | 0.000437 | 0.000175 | 0.000986 | 0.000246% | 99.199278% | 0 |  |
| 602 | `tests/e2e/test_gate_timing.py::test_lifecycle_waits_measure_only_the_accepted_status[wait_for_editor_playing-runtime_playing-GDAPI_E2E_PLAY_TIMEOUT_SECONDS-first0-last0]` | passed | 0.000610 | 0.000189 | 0.000178 | 0.000977 | 0.000243% | 99.199522% | 0 |  |
| 603 | `tests/e2e/test_gate_timing.py::test_lifecycle_waits_measure_only_the_accepted_status[wait_stopped-runtime_stop-GDAPI_E2E_STOP_TIMEOUT_SECONDS-first2-last2]` | passed | 0.000607 | 0.000169 | 0.000179 | 0.000955 | 0.000238% | 99.199760% | 0 |  |
| 604 | `tests/e2e/test_version_gate.py::test_parse_godot_47_versions[4.7.stable.official.123-expected0]` | passed | 0.000594 | 0.000196 | 0.000158 | 0.000947 | 0.000236% | 99.199996% | 0 |  |
| 605 | `tests/e2e/m3/test_runtime_input.py::test_input_routes_are_adapter_backed_mutations[gamepad]` | passed | 0.000316 | 0.000454 | 0.000095 | 0.000865 | 0.000216% | 99.200211% | 0 |  |
| 606 | `tests/e2e/m3/test_runtime_status.py::test_runtime_lifecycle_scenario` | passed | 0.000499 | 0.000156 | 0.000194 | 0.000849 | 0.000212% | 99.200423% | 0 |  |
| 607 | `tests/e2e/test_version_gate.py::test_require_godot_47_rejects_old_or_invalid[3.6.2]` | passed | 0.000459 | 0.000229 | 0.000139 | 0.000828 | 0.000206% | 99.200629% | 0 |  |
| 608 | `tests/e2e/test_shared_editor_contract.py::test_m3_alias_shares_e2e_editor` | passed | 0.000236 | 0.000497 | 0.000076 | 0.000809 | 0.000202% | 99.200831% | 0 |  |
| 609 | `tests/e2e/test_shared_editor_contract.py::test_m4_alias_shares_e2e_editor` | passed | 0.000218 | 0.000474 | 0.000108 | 0.000800 | 0.000199% | 99.201030% | 0 |  |
| 610 | `tests/e2e/m3/test_runtime_status.py::test_m3_editor_session_reuses_one_process_and_setup` | passed | 0.000489 | 0.000159 | 0.000135 | 0.000783 | 0.000195% | 99.201225% | 0 |  |
| 611 | `tests/e2e/test_version_gate.py::test_parse_godot_47_versions[Godot Engine v4.7.2.stable-expected2]` | passed | 0.000471 | 0.000186 | 0.000124 | 0.000781 | 0.000194% | 99.201420% | 0 |  |
| 612 | `tests/e2e/test_gate_timing.py::test_predicate_wait_measures_success_and_honors_configured_deadline` | passed | 0.000284 | 0.000372 | 0.000118 | 0.000773 | 0.000193% | 99.201612% | 0 |  |
| 613 | `tests/e2e/test_version_gate.py::test_parse_godot_47_versions[4.7.1.stable.official.123-expected1]` | passed | 0.000411 | 0.000200 | 0.000146 | 0.000757 | 0.000188% | 99.201801% | 0 |  |
| 614 | `tests/e2e/test_gate_timing.py::test_thresholds_reject_nonpositive_nonfinite_and_bad_numbers[]` | passed | 0.000285 | 0.000333 | 0.000131 | 0.000748 | 0.000186% | 99.201987% | 0 |  |
| 615 | `tests/e2e/m3/test_runtime_status.py::test_reset_connected_game_cleans_stale_transport` | passed | 0.000453 | 0.000157 | 0.000129 | 0.000739 | 0.000184% | 99.202171% | 0 |  |
| 616 | `tests/e2e/test_version_gate.py::test_require_godot_47_rejects_old_or_invalid[not-a-version]` | passed | 0.000344 | 0.000200 | 0.000157 | 0.000701 | 0.000175% | 99.202346% | 0 |  |
| 617 | `tests/e2e/test_shared_editor_contract.py::test_editor_start_counter_records_one_start` | passed | 0.000323 | 0.000228 | 0.000147 | 0.000698 | 0.000174% | 99.202520% | 0 |  |
| 618 | `tests/e2e/test_shared_editor_lifecycle.py::test_project_settings_save_temporary_file_is_not_tracked` | passed | 0.000335 | 0.000188 | 0.000142 | 0.000665 | 0.000166% | 99.202685% | 0 |  |
| 619 | `tests/e2e/test_gate_timing.py::test_invalid_transport_has_actionable_configuration_error` | passed | 0.000175 | 0.000332 | 0.000121 | 0.000628 | 0.000157% | 99.202842% | 0 |  |
| 620 | `tests/e2e/test_gate_timing.py::test_thresholds_reject_nonpositive_nonfinite_and_bad_numbers[-1]` | passed | 0.000274 | 0.000179 | 0.000158 | 0.000611 | 0.000152% | 99.202994% | 0 |  |
| 621 | `tests/e2e/test_gate_timing.py::test_thresholds_reject_nonpositive_nonfinite_and_bad_numbers[abc]` | passed | 0.000272 | 0.000200 | 0.000138 | 0.000610 | 0.000152% | 99.203146% | 0 |  |
| 622 | `tests/e2e/test_collection_order.py::test_classify_puts_contract_tests_in_bucket_0` | passed | 0.000315 | 0.000160 | 0.000109 | 0.000585 | 0.000146% | 99.203292% | 0 |  |
| 623 | `tests/e2e/test_gate_timing.py::test_thresholds_reject_nonpositive_nonfinite_and_bad_numbers[nan]` | passed | 0.000258 | 0.000188 | 0.000135 | 0.000582 | 0.000145% | 99.203437% | 0 |  |
| 624 | `tests/e2e/m3/test_harness.py::test_session_finalizer_reports_cleanup_and_budget_failures` | passed | 0.000285 | 0.000176 | 0.000112 | 0.000573 | 0.000143% | 99.203579% | 0 |  |
| 625 | `tests/e2e/test_gate_timing.py::test_scene_switch_wait_does_not_record_a_timeout` | passed | 0.000219 | 0.000169 | 0.000135 | 0.000523 | 0.000130% | 99.203709% | 0 |  |
| 626 | `tests/e2e/test_gate_timing.py::test_editor_mode_rejects_unknown_values[software]` | passed | 0.000218 | 0.000175 | 0.000127 | 0.000519 | 0.000129% | 99.203839% | 0 |  |
| 627 | `tests/e2e/test_gate_timing.py::test_successful_wait_excludes_false_error_results_and_exceptions` | passed | 0.000161 | 0.000239 | 0.000111 | 0.000512 | 0.000127% | 99.203966% | 0 |  |
| 628 | `tests/e2e/test_gate_timing.py::test_thresholds_reject_nonpositive_nonfinite_and_bad_numbers[inf]` | passed | 0.000218 | 0.000158 | 0.000131 | 0.000507 | 0.000126% | 99.204093% | 0 |  |
| 629 | `tests/e2e/test_gate_timing.py::test_thresholds_reject_nonpositive_nonfinite_and_bad_numbers[0]` | passed | 0.000217 | 0.000160 | 0.000128 | 0.000505 | 0.000126% | 99.204218% | 0 |  |
| 630 | `tests/e2e/test_unified_fixture_contract.py::test_unified_fixture_has_no_path_duplicates` | passed | 0.000116 | 0.000276 | 0.000105 | 0.000498 | 0.000124% | 99.204342% | 0 |  |
| 631 | `tests/e2e/test_unified_fixture_contract.py::test_unified_fixture_root_exists` | passed | 0.000178 | 0.000183 | 0.000095 | 0.000456 | 0.000113% | 99.204456% | 0 |  |
| 632 | `tests/e2e/test_collection_order.py::test_bucketize_preserves_relative_order_within_buckets` | passed | 0.000138 | 0.000200 | 0.000079 | 0.000417 | 0.000104% | 99.204560% | 0 |  |
| 633 | `tests/e2e/test_collection_order.py::test_classify_defaults_to_bucket_2_for_m2_m4_m3_contract` | passed | 0.000180 | 0.000126 | 0.000082 | 0.000388 | 0.000097% | 99.204656% | 0 |  |
| 634 | `tests/e2e/test_gate_timing.py::test_threshold_override` | passed | 0.000132 | 0.000132 | 0.000115 | 0.000379 | 0.000094% | 99.204751% | 0 |  |
| 635 | `tests/e2e/test_unified_fixture_contract.py::test_unified_fixture_runtime_probe_section_present` | passed | 0.000090 | 0.000213 | 0.000071 | 0.000373 | 0.000093% | 99.204844% | 0 |  |
| 636 | `tests/e2e/test_shared_editor_contract.py::test_shared_fixture_has_a_single_module_identity` | passed | 0.000168 | 0.000125 | 0.000078 | 0.000370 | 0.000092% | 99.204936% | 0 |  |
| 637 | `tests/e2e/test_collection_order.py::test_classify_puts_slow_paths_in_bucket_4` | passed | 0.000087 | 0.000120 | 0.000075 | 0.000282 | 0.000070% | 99.205006% | 0 |  |
| 638 | `tests/e2e/test_collection_order.py::test_bucketize_is_idempotent` | passed | 0.000077 | 0.000135 | 0.000068 | 0.000280 | 0.000070% | 99.205076% | 0 |  |
| 639 | `tests/e2e/test_collection_order.py::test_classify_puts_m3_runtime_in_bucket_3` | passed | 0.000069 | 0.000104 | 0.000068 | 0.000241 | 0.000060% | 99.205136% | 0 |  |

## 本轮未执行的 4 个 case

以下由既有 marker 选择排除，不提供虚构耗时；独立 EngineDebugger、真实渲染器与预算门禁未启动。

| pytest nodeid | 状态 | 耗时 |
|---|---|---|
| `tests/e2e/m2/test_spatial_particles.py::test_gridmap_library_cells_atomic_replace_undo_and_persistence` | deselected | 未测量 |
| `tests/e2e/m2/test_spatial_particles.py::test_multimesh_instances_mesh_transform_color_custom_roundtrip` | deselected | 未测量 |
| `tests/e2e/test_full_suite_budget.py::test_full_suite_under_budget` | deselected | 未测量 |
| `tests/e2e/m3/test_engine_transport.py::test_engine_debugger_protocol_two_real_data_plane` | deselected | 未测量 |

## 核对结果

- 原始 report 中的 639 个不同 nodeid 与 selected_nodeids 一一对应，没有遗漏或重复。
- JUnit 独立记录也为 639 个 case，失败 1 个、跳过 1 个，与原始分阶段数据一致。
- 原始精度下全部 case 阶段之和 + 未归属开销 = 父进程实测 wall time；占比合计 100%。
- 本次仅做测量和统计，没有修改生产代码、测试行为或减少测试。临时采样代码不进入项目实现。
