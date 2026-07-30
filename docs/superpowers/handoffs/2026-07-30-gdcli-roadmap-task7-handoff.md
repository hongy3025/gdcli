# gdcli 路线图整改 Task 7 Handoff

日期：2026-07-30  
仓库：D:\AI\godot-ws\gdcli  
分支：feat/full-capability

## 新 session 必读

阅读本文件、docs/superpowers/plans/2026-07-30-gdcli-full-capability-roadmap-remediation.md，以及上一份 handoff 2026-07-30-gdcli-roadmap-remediation-handoff.md。不要覆盖当前未提交改动。最后一次提交：

```
b123234 test: add M6 capability contract harness
```

## 已完成并提交

- M6 独立 fixture/default-deny/doc 合约：16/16 通过。
- file transport hello 的 JSON float 版本规范化，真实 Godot 安装流程可加载当前 addon。
- runtime/eval 协议 v2、generation 校验、异步 route 解析和 bulk delete 缩进修复。
- GDScript unit suite：21/21；Rust workspace tests、fmt、clippy 曾全部通过。

## 本 session 未提交改动

### Bulk deploy

修改了 gdapi/addon/runtime/services/bulk_deploy_service.gd、新增 tests/fixture_project/tests/test_bulk_deploy_service.gd，并把测试加入 tests/e2e/test_gdscript_units.py。

目标：plan/apply 纳入排序设备快照和 APK SHA-256；apply 前重算并对 stale artifact/device 返回 conflict；每个设备返回 deployed/offline/missing/failed；支持 fake bridge 注入。

TDD 证据：修改前 focused unit 因缺少静态 plan/apply 失败；第一次实现后 pytest ... -k bulk_deploy 为 1 passed。但后续把 bridge 参数接入时引入了语法错误，见下文。

### M5 acceptance tests

新增：

- tests/e2e/m5/test_project_config_routes.py
- tests/e2e/m5/test_classdb_routes.py
- tests/e2e/m5/test_diagnostics_routes.py
- tests/e2e/m5/test_export_android.py
- tests/e2e/m5/test_uid_repair.py

第一次运行新增 M5 测试：7 passed、3 failed。ClassDB、diagnostics、UID、原有 smoke/snapshot 已通过；失败暴露了 export pipe、Android missing-template 连带错误和一个测试字段名错误（字段已改为 action）。

### 其他未提交生产修改

- export_service.gd：移除不存在的 FileAccess.get_available_bytes()，改为子进程结束后读取 pipe。
- android_bridge.gd：同类 pipe API 修复。
- network_target_guard.gd：移除不存在的 IP.is_valid_ip_address()，增加 _is_ip_literal()，并显式声明 allowed: bool。

## 当前阻塞

最新格式/lint 门禁失败，尚未进入新的测试：

```
gdapi/addon/runtime/services/bulk_deploy_service.gd:79
Unexpected token '}' ; expected COMMA or RPAR
```

_deploy 调用应修成：

```gdscript
var one := _deploy(
    {
        "serial": serial,
        "apk_path": String(body.get("apk_path", "")),
        "package": body.get("package", ""),
        "activity": body.get("activity", ""),
        "force": true
    },
    bridge
)
```

此外，最近 focused export/project 测试（在上述最新修复之后、但语法错误暴露时）为 1 failed、2 passed。此前日志还显示：bulk deploy parse error、network target guard compile error、export pipe get_length() 在 Windows pipe 上不可用。后两个已有未验证修复，必须重新跑。

工作区还可能有测试残留：tests/fixture_project/bulk-deploy-test.apk。确认路径后安全删除，不要误删其他文件。

## 下一步命令

先修语法，再执行 GDScript 门禁：

```powershell
python scripts/format-gd.py
python scripts/format-gd.py --check
$gdFiles = @(git diff --name-only --diff-filter=ACMR | Where-Object { $_ -like '*.gd' })
if ($gdFiles.Count -gt 0) { gdlint $gdFiles }
```

然后必须重建嵌入 addon 的 CLI，再测试：

```powershell
cargo build -p gdcli
$env:GODOT_BIN='D:\app\devel\Godot\v4.7.1\godot_console.exe'
uv run pytest tests/e2e/test_gdscript_units.py -q
uv run pytest tests/e2e/m5 -q
uv run pytest tests/e2e/m6/test_m6_contract.py -q
```

Task 7 仍需新增 tests/e2e/m6/test_bulk_deploy.py，覆盖 partial device failure、stale artifact/device plan 和无真实设备行为。完成后运行：

```powershell
uv run pytest tests/e2e/m5 tests/e2e/m6/test_bulk_deploy.py -v
```

最后再做 Rust 门禁、git diff --check 和提交。路线图不可标记完成，直到 fresh 单命令：

```powershell
uv run pytest tests/e2e/ -v
```

当前尚未运行完整 E2E；不要据此声称 Task 7 或路线图完成。
