# gdcli Policy/Force 移除与 Review 缺口整改 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 按 2026-08-01 需求方针变更，完全移除 policy 权限配置与 force:true 要求（gdcli 定位为开发期工具），并整改 2026-07-31 深度 review 发现的全部实现缺口。

**Architecture:** 删除 `capability_policy.gd` 门禁层与 `force` 检查链；高风险能力改为默认可用，仅受各 service 内置硬编码上限约束；审计日志保留（不再含 force 字段）。缺口整改分散到各子系统任务中：审计名修复、UndoRedo、doc() 补齐、HTTP 状态映射、下载上限等。

**Tech Stack:** GDScript (Godot 4.7, gdapi addon)、Python pytest (E2E)、Rust（本 plan 不改动 Rust 层）。

## Global Constraints

1. 需求变更（用户 2026-08-01 拍板）：**不再有任何 `.godot/gdapi-policy.json` 配置；不再要求任何 `force:true`**。原高风险能力（eval/process/network/bulk/export/deploy）默认可用。
2. 公开 route 路径一律不变。请求 body 中遗留的 `force` 字段被忽略（不报错、不检查）。
3. 审计保留：危险/文件 mutation 继续通过 `GdApiAuditLog.record` 记录 `route`/`summary`/`ok`/`code`；**所有 audit summary 删除 `force` 字段**；审计 route 名必须是公开 route 名。
4. 标准 10 错误码保留；`UNSAFE_OPERATION` 常量保留（允许无生产方）；`ErrorCodes.require_force()` 删除。
5. 内置硬上限（无配置）：eval source ≤ 16 KiB、inputs ≤ 64；process timeout_ms ∈ [1, 60000]（默认 5000）、max_output_bytes ∈ [1, 1048576]（默认 65536）；network 仅 http/https、禁止 URL 内嵌 credentials/fragment/控制字符、timeout_ms ∈ [1, 60000]（默认 30000）、max_response_bytes ∈ [1, 4194304]（默认 4194304）、max_redirects ∈ [0,5]；export timeout_ms ∈ [10000, 600000]（默认 120000）。
6. mutation 响应继续含 `ok`/`changed`/`undoable`；编辑器状态 mutation（信号、分组）按设计文档 mutation 模型返回 `undoable:true` 并接入 UndoRedo。
7. 每个 task 结束跑验证：GDScript 改动先过 `python scripts/format-gd.py` + `gdlint`（AGENTS.md 门禁，缺工具先 `uv tool install gdtoolkit`）；无 Godot 依赖验证 `cargo test --workspace`；涉及被改行为的 pytest 用 `uv run pytest tests/e2e/...`（需 Godot 4.7）。
8. 本 plan 的最终验收（Task 13）：`cargo fmt --check`、`cargo clippy --workspace`、`cargo test --workspace` 全绿；`uv run pytest tests/e2e/` 全绿；`gdapi/routes` 与 `tests/e2e/route_manifests.py` 清单一致；全仓不再存在 `require_force`、`capability_policy`、`gdapi-policy`、审计中的 `force` 字段引用（`git grep` 验证）。

---

## Task 1: M6 测试基础设施简化 + eval 栈整改

**Files:**
- Modify: `gdapi/addon/runtime/services/eval_service.gd:23-42`
- Modify: `gdapi/addon/routes/editor/eval.gd`
- Modify: `gdapi/addon/routes/runtime/eval.gd`
- Modify: `gdapi/addon/runtime/runtime_route.gd:188-239`
- Modify: `gdapi/addon/runtime/runtime_probe.gd:249-257`
- Modify: `tests/e2e/m6/conftest.py`（删 policy overlay fixtures）
- Modify: `tests/e2e/m6/test_m6_contract.py`（default-deny 测试改写）
- Modify: `tests/e2e/m6/test_eval.py`、`test_runtime_eval.py`
- Modify: `tests/fixture_project/tests/test_eval_service.gd` 与 `tests/fixtures/e2e_project/tests/test_eval_service.gd`（两处同内容）

**Interfaces:**
- Consumes: `EvalService.execute(source, inputs)`（两参新签名）
- Produces: `GdApiRuntimeRoute.dispatch()` 的审计统一使用公开 route 名（`public_route` 非空时）

- [ ] **Step 1: 改 `eval_service.gd` 签名与默认行为**

将 `execute` 改为两参；删除 `allowed_input_keys` 白名单；上限只查常量：

```gdscript
static func execute(source: String, inputs: Dictionary) -> Dictionary:
	if source.to_utf8_buffer().size() > MAX_SOURCE_BYTES:
		return _error(ErrorCodes.INVALID_PARAM, "source exceeds the 16 KiB limit")
	if inputs.size() > 64:
		return _error(ErrorCodes.INVALID_PARAM, "too many inputs")
	var names: Array[String] = []
	var values: Array = []
	for key in inputs:
		if typeof(key) != TYPE_STRING:
			return _error(ErrorCodes.INVALID_PARAM, "input names must be strings")
		var decoded := VariantCodec.decode(inputs[key])
		if not decoded.ok or _contains_object(decoded.value):
			return _error(ErrorCodes.INVALID_PARAM, "input value is not a permitted Variant")
		names.append(String(key))
		values.append(decoded.value)
	# 以下 _validate_source / Expression.parse / execute / _validate_result 保持不变
```

- [ ] **Step 2: 改 `editor/eval.gd`（移除 Policy，保留审计，去掉 force）**

整体替换 handle 与 doc：

```gdscript
@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const Service := preload("res://addons/gdapi/runtime/services/eval_service.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")
const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")

const ROUTE := "editor/eval"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var result := Service.execute(
		String(req.get_body("source", "")),
		req.get_body("inputs", {})
	)
	if not result.ok:
		AuditLog.record(ROUTE, "dangerous", {}, false, result.code)
		res.error(result.error, result.code, ErrorCodes.http_status(result.code))
		return
	AuditLog.record(ROUTE, "dangerous", {"type": result.type}, true, "")
	res.json(result)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("执行受限的无副作用编辑器表达式")
		. desc("仅允许固定输入和受支持的 Variant 类型；源码上限 16 KiB，禁止语句/成员访问/赋值。")
		. param("source", "String", true, "受限 Expression 源码")
		. param("inputs", "Dictionary", false, "输入值（任意 key，值需为受支持的 Variant 类型）")
		. example('{"source":"origin + delta","inputs":{"origin":{"type":"Vector2","value":[1.0,2.0]},"delta":{"type":"Vector2","value":[3.0,4.0]}}}')
		. returns(
			"表达式结果",
			{"value": "encoded Variant", "type": "String", "elapsed_ms": "int", "undoable": "false"}
		)
	)
```

- [ ] **Step 3: 改 `runtime/eval.gd`（移除 Policy 与 allowed_input_keys 注入）**

整体替换：

```gdscript
@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"

const ROUTE := "runtime/eval"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch_versioned(req, res, "eval", Protocol.VERSION_V2, true, ROUTE)


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("执行受限的运行时表达式")
		. desc("使用与 editor/eval 相同的受限语法（源码上限 16 KiB）；运行时未连接时返回 conflict；仅 v2 协议可用。")
		. param("source", "String", true, "受限 Expression 源码")
		. param("inputs", "Dictionary", false, "输入值")
		. returns(
			"表达式结果",
			{"value": "encoded Variant", "type": "String", "elapsed_ms": "int", "undoable": "false"}
		)
		. example('{"source":"1+1"}')
	)
```

- [ ] **Step 4: 改 `runtime_route.gd` — 审计一律使用公开 route 名（缺口：runtime/eval 审计记为 `eval`）**

将 `_complete`、`_reject`、`_audit` 改为携带 `public_route`：

```gdscript
	# dispatch() 中两处调用改为：
	_complete(res, op, public_route, payload, mutation, reply)
	# 与
	_reject(req, res, op, public_route, mutation, boundary)


func _complete(
	res: GdApiResponse, op: String, public_route: String, payload: Dictionary, mutation: bool,
	reply: Dictionary
) -> void:
	if res.is_sent():
		return
	if bool(reply.get("ok", false)):
		var result: Variant = reply.get("result", {})
		var body: Dictionary = {"ok": true}
		if typeof(result) == TYPE_DICTIONARY:
			for key in result:
				body[key] = result[key]
		else:
			body["result"] = result
		body["ok"] = true
		if mutation:
			body["changed"] = bool(body.get("changed", true))
			body["undoable"] = false
			body["operation"] = op
			_audit(public_route if not public_route.is_empty() else op, payload, reply, true, "")
		res.json(body)
		return
	var code := String(reply.get("code", ErrorCodes.GODOT_ERROR))
	if code.is_empty():
		code = ErrorCodes.GODOT_ERROR
	if mutation:
		_audit(public_route if not public_route.is_empty() else op, payload, reply, false, code)
	_send_error(res, reply)


func _reject(
	req: GdApiRequest, res: GdApiResponse, op: String, public_route: String, mutation: bool,
	failure: Dictionary
) -> void:
	if mutation:
		var payload: Variant = req.body if req != null else null
		_audit(
			public_route if not public_route.is_empty() else op,
			payload, failure, false, String(failure.get("code", ErrorCodes.INVALID_PARAM))
		)
	_send_error(res, failure)
```

`_audit` 签名不变（第一参语义变为"公开 route 名"）。

- [ ] **Step 5: 改 `runtime_probe.gd` eval 分支（去掉注入的 allowed_input_keys）**

```gdscript
		"eval":
			result = EvalService.execute(
				String(payload.get("source", "")),
				payload.get("inputs", {})
			)
```

- [ ] **Step 6: 简化 `tests/e2e/m6/conftest.py`**

- 删除 `M6_EVAL_POLICY` / `M6_BULK_POLICY` / `M6_NETWORK_POLICY` / `M6_PROCESS_POLICY` / `M6_DEFAULT_DENY_POLICY` 五个字典。
- 从 `from e2e.shared_fixture import (...)` 中移除 `temporary_policy`。
- 五个 overlay fixture（`m6_editor`/`m6_editor_eval`/`m6_editor_process`/`m6_editor_bulk`/`m6_editor_network`）改为纯别名：

```python
@pytest.fixture(scope="module")
def m6_editor(session_m6_editor: dict[str, Any]) -> dict[str, Any]:
    """Module-scoped alias of the shared editor (no capability overlay)."""
    return session_m6_editor
```

其余四个 fixture 同样处理（各自依赖对应的 session fixture）。

- [ ] **Step 7: 改写 `tests/e2e/m6/test_m6_contract.py` 的 default-deny 测试**

将 `test_m6_route_is_default_deny` 替换为"默认可用（不再 permission_denied）"：

```python
@pytest.mark.parametrize("route", sorted(M6_ROUTES))
def test_m6_route_no_longer_requires_policy(m6_editor, route):
    """Policy requirement removed: routes must not answer permission_denied."""
    body = {"force": True}  # force 字段被忽略，不应再触发拒绝
    if route == "runtime/eval":
        body["source"] = "1 + 1"
    result = _exec_raw(m6_editor, route, body)
    assert result.get("code") != "permission_denied"
```

（`M6_ROUTES` 从 `e2e.route_manifests` 导入；`_exec_raw` 已存在于 m6/conftest.py。）

- [ ] **Step 8: 更新 `tests/e2e/m6/test_eval.py` 与 `test_runtime_eval.py`**

- 所有 body 删除 `"force": True`（grep 定位：test_eval.py:32、41、48；test_runtime_eval.py:13、21、27、36）。
- test_eval.py 中若存在"未授权 input key → permission_denied"用例，删除（输入 key 不再受限）；sandbox 拒绝用例（`Engine.get_main_loop()`、`instance_from_id(1)` 等）保留。
- 其余断言（审计脱敏、值相等、conflict）不变。

- [ ] **Step 9: 更新两处 `test_eval_service.gd`**

```gdscript
func _init() -> void:
	var result := EvalService.execute(
		"origin + delta",
		{
			"origin": {"type": "Vector2", "value": [1.0, 2.0]},
			"delta": {"type": "Vector2", "value": [3.0, 4.0]},
		}
	)
	assert_eq(
		result.get("value", {}), {"type": "Vector2", "value": [4.0, 6.0]}, "typed vector expression"
	)
	var denied := EvalService.execute("Engine.get_main_loop()", {})
	assert_eq(denied.get("code", ""), "permission_denied", "object access is denied")
	var unknown := EvalService.execute("instance_from_id(1)", {})
	assert_eq(unknown.get("code", ""), "permission_denied", "unknown call is denied")
	# 输入 key 不再受限：任意 key 可用
	var free_keys := EvalService.execute("a + b", {"a": 1, "b": 2})
	assert_true(free_keys.get("ok", false), "arbitrary input keys are allowed")
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed > 0 else 0)
```

- [ ] **Step 10: 验证并提交**

```bash
python scripts/format-gd.py
python scripts/format-gd.py --check
gdlint gdapi/addon/runtime/services/eval_service.gd gdapi/addon/routes/editor/eval.gd gdapi/addon/routes/runtime/eval.gd gdapi/addon/runtime/runtime_route.gd gdapi/addon/runtime/runtime_probe.gd tests/fixture_project/tests/test_eval_service.gd tests/fixtures/e2e_project/tests/test_eval_service.gd
cargo test --workspace
uv run pytest tests/e2e/test_gdscript_units.py -v
uv run pytest tests/e2e/m6/test_eval.py tests/e2e/m6/test_runtime_eval.py tests/e2e/m6/test_m6_contract.py -v
```

Expected: gdscript_units 全绿（capability_policy 单测仍过——Task 10 才删）；m6 三个文件全绿。Commit: `refactor(eval): drop policy/force gates, audit under public route`.

---

## Task 2: process/run 栈整改

**Files:**
- Modify: `gdapi/addon/runtime/services/process_service.gd:9-55`
- Modify: `gdapi/addon/routes/process/run.gd`
- Modify: `tests/e2e/m6/test_process_run.py`

**Interfaces:**
- Produces: `GdApiProcessService.validate(body) -> Dictionary`（单参；硬上限常量 `DEFAULT_TIMEOUT_MS=5000`、`MAX_TIMEOUT_MS=60000`、`DEFAULT_MAX_OUTPUT_BYTES=65536`、`MAX_OUTPUT_BYTES=1048576`）

- [ ] **Step 1: 改 `process_service.gd` — 移除 policy 参数与 allowlist**

在类头加常量，整体替换 `validate`：

```gdscript
const DEFAULT_TIMEOUT_MS := 5000
const MAX_TIMEOUT_MS := 60_000
const DEFAULT_MAX_OUTPUT_BYTES := 65536
const MAX_OUTPUT_BYTES := 1_048_576


static func validate(body: Dictionary) -> Dictionary:
	var executable := String(body.get("executable", ""))
	var args: Array = body.get("args", [])
	if executable.is_empty() or typeof(args) != TYPE_ARRAY:
		return {
			"ok": false,
			"code": ErrorCodes.INVALID_PARAM,
			"error": "executable and args are required"
		}
	for arg in args:
		if typeof(arg) != TYPE_STRING:
			return {"ok": false, "code": ErrorCodes.INVALID_PARAM, "error": "args must be strings"}
	var cwd := String(body.get("cwd", "res://"))
	var checked := PathGuard.validate(cwd, "read")
	if not checked.ok:
		return checked
	var timeout := int(body.get("timeout_ms", DEFAULT_TIMEOUT_MS))
	var cap := int(body.get("max_output_bytes", DEFAULT_MAX_OUTPUT_BYTES))
	if timeout <= 0 or timeout > MAX_TIMEOUT_MS:
		return {"ok": false, "code": ErrorCodes.INVALID_PARAM, "error": "timeout_ms must be in 1..60000"}
	if cap <= 0 or cap > MAX_OUTPUT_BYTES:
		return {"ok": false, "code": ErrorCodes.INVALID_PARAM, "error": "max_output_bytes must be in 1..1048576"}
	return {
		"ok": true,
		"executable": executable,
		"args": args,
		"cwd": ProjectSettings.globalize_path(checked.path),
		"timeout_ms": timeout,
		"max_output_bytes": cap
	}
```

（删除了 executables allowlist、cwd_roots、policy 上限比较。`start`/`tick`/`cancel` 不变。）

- [ ] **Step 2: 改 `routes/process/run.gd`**

四处修改：
1. 删除 `Policy` preload 与整个 gate 块（`var policy := Policy.new()`、`authorize("process", ...)`、拒绝分支）。
2. `Service.validate(req.body)` 去掉第二个参数（原 `policy.settings("process")`）。
3. 两处 denial audit（gate 拒绝）整块删除；保留 validate 失败与 terminal audit，summary 中删除 `"force": ...` 字段（原 `{"executable": ..., "force": req.get_body("force", false)}` → `{"executable": ...}`）。
4. `doc()`：删除 `force` param 与示例中的 `"force":true`；desc 改为"executable 与 argv 原样传递，不经过 shell；timeout 上限 60s、输出上限 1 MiB"。

- [ ] **Step 3: 更新 `tests/e2e/m6/test_process_run.py`**

- 删除 `test_process_run_requires_force`（替换为：无 force 直接成功，即并入现有成功用例）。
- 其余 body 删除 `"force": True`（grep 定位：:20、:32、:51）。
- 保留 timeout（:31-34）、取消、audit 断言。

- [ ] **Step 4: 验证并提交**

```bash
python scripts/format-gd.py && python scripts/format-gd.py --check
gdlint gdapi/addon/runtime/services/process_service.gd gdapi/addon/routes/process/run.gd
cargo test --workspace
uv run pytest tests/e2e/m6/test_process_run.py -v
```

Commit: `refactor(process): drop policy allowlists, enforce built-in caps`.

---

## Task 3: network 栈整改 + body_size_limit（缺口）

**Files:**
- Modify: `gdapi/addon/runtime/services/network_target_guard.gd`
- Modify: `gdapi/addon/runtime/services/network_service.gd`
- Modify: `gdapi/addon/routes/network/http_request.gd`
- Modify: `tests/fixture_project/tests/test_network_target_guard.gd` 与 `tests/fixtures/e2e_project/tests/test_network_target_guard.gd`
- Modify: `tests/e2e/m6/test_network_request.py`

**Interfaces:**
- Produces: `GdApiNetworkTargetGuard.authorize(url) -> Dictionary`（单参）；`GdApiNetworkService.validate(body) -> Dictionary`（单参）；`start(spec, response)` 设置 `HTTPRequest.body_size_limit`

- [ ] **Step 1: 整体替换 `network_target_guard.gd`**

```gdscript
@tool
class_name GdApiNetworkTargetGuard
extends RefCounted

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")

const ALLOWED_SCHEMES := ["http", "https"]


## 结构校验 URL：仅 http/https；禁止内嵌 credentials/fragment/控制字符；host/port 合法。
## 不做 host/port 白名单与私网检查（开发期工具，Bearer token 已构成访问控制）。
static func authorize(url: String) -> Dictionary:
	if url.contains("#") or url.contains("@") or url.contains("\n") or url.contains("\r"):
		return _error(
			ErrorCodes.INVALID_PARAM, "URL credentials, fragments, and controls are not allowed"
		)
	var parts := url.split("://", true, 1)
	if parts.size() != 2:
		return _error(ErrorCodes.INVALID_PARAM, "URL scheme is required")
	var scheme := parts[0].to_lower()
	if not ALLOWED_SCHEMES.has(scheme):
		return _error(ErrorCodes.PERMISSION_DENIED, "URL scheme is not allowed")
	var authority := parts[1].split("/", true, 1)[0]
	var host := authority
	var port := 443 if scheme == "https" else 80
	if authority.begins_with("["):
		var close := authority.find("]")
		if close < 0:
			return _error(ErrorCodes.INVALID_PARAM, "invalid IPv6 host")
		host = authority.substr(1, close - 1)
		if close + 1 < authority.length():
			port = int(authority.substr(close + 2))
	elif authority.count(":") == 1:
		var fields := authority.rsplit(":", true, 1)
		host = fields[0]
		port = int(fields[1])
	if host.is_empty() or port < 1 or port > 65535:
		return _error(ErrorCodes.INVALID_PARAM, "invalid host or port")
	return {"ok": true, "url": url, "scheme": scheme, "host": host, "port": port}


static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "error": message}
```

（删除 `is_public_address`、`_is_ip_literal`、`_normalize_addresses`、hosts/ports allowlist、DNS 解析与私网拒绝。）

- [ ] **Step 2: 改 `network_service.gd`**

类头加常量：

```gdscript
const DEFAULT_TIMEOUT_MS := 30_000
const MAX_TIMEOUT_MS := 60_000
const DEFAULT_MAX_RESPONSE_BYTES := 4 * 1024 * 1024
const MAX_RESPONSE_BYTES := 4 * 1024 * 1024
const MAX_REDIRECTS := 5
```

`validate` 整体替换：

```gdscript
static func validate(body: Dictionary) -> Dictionary:
	var url := String(body.get("url", ""))
	var target := TargetGuard.authorize(url)
	if not target.ok:
		return target
	var method := String(body.get("method", "GET")).to_upper()
	if method not in ["GET", "HEAD"]:
		return _error(ErrorCodes.PERMISSION_DENIED, "HTTP method is not allowed")
	var timeout := int(body.get("timeout_ms", DEFAULT_TIMEOUT_MS))
	var cap := int(body.get("max_response_bytes", DEFAULT_MAX_RESPONSE_BYTES))
	if timeout <= 0 or timeout > MAX_TIMEOUT_MS:
		return _error(ErrorCodes.INVALID_PARAM, "timeout_ms must be in 1..60000")
	if cap <= 0 or cap > MAX_RESPONSE_BYTES:
		return _error(ErrorCodes.INVALID_PARAM, "max_response_bytes must be in 1..4194304")
	return {
		"ok": true,
		"url": target.url,
		"scheme": target.scheme,
		"host": target.host,
		"port": target.port,
		"method": method,
		"timeout_ms": timeout,
		"max_response_bytes": cap,
		"max_redirects": clampi(int(body.get("max_redirects", MAX_REDIRECTS)), 0, MAX_REDIRECTS),
		"headers": body.get("headers", {}),
		"body": String(body.get("body", ""))
	}
```

`start()` 修改点：
1. 创建节点后设置下载上限（**缺口修复：下载阶段即截断，而非下载完再切**）：

```gdscript
	var node := HTTPRequest.new()
	node.timeout = float(spec.timeout_ms) / 1000.0
	node.max_redirects = 0
	node.body_size_limit = spec.max_response_bytes
	plugin.add_child(node)
```

2. `spec` 中删除 `"redirect_policy"` 字段（`:51` 的 `"redirect_policy": policy.duplicate(true)`）；`visited` 与 `spec.url` 保留（redirect 环检测）。
3. `request_completed` 回调开头，把"下载超限"视为截断成功：

```gdscript
	func(result, response_code, headers, body):
		if state.done:
			return
		var forced_truncated := result == HTTPRequest.RESULT_BODY_SIZE_LIMIT_REACHED
		if forced_truncated:
			result = HTTPRequest.RESULT_SUCCESS
		var is_redirect = response_code >= 300 and response_code < 400
		...
```

4. redirect 分支的 target 校验改为 `var target := TargetGuard.authorize(location)`（无 policy）。
5. 成功分支：`var truncated := forced_truncated`；`if body.size() > spec.max_response_bytes: body = body.slice(0, spec.max_response_bytes); truncated = true` 保留为双保险。

- [ ] **Step 3: 改 `routes/network/http_request.gd`**

1. 删除 `Policy` preload 与整个 gate 块（`authorize("network", ...)` 拒绝分支）。
2. `Service.validate(req.body)` 去掉 `policy.settings("network")` 参数。
3. denial audit 删除；validate 失败与 terminal audit 的 summary 删除 `"force"` 字段（原 `{"url": ..., "force": ...}` → `{"url": ...}`）。
4. `doc()`：删除 `force` param、`"force":true` 示例；desc 改为"仅 http/https，下载上限 4 MiB、重定向 ≤5、超时 ≤60s"。

- [ ] **Step 4: 更新两处 `test_network_target_guard.gd`（按新单参签名重写）**

```gdscript
func _init() -> void:
	_test_scheme_allowlist()
	_test_structural_rejections()
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed > 0 else 0)


func test_scheme_allowlist() -> void:
	_assert_true(Guard.authorize("https://example.com/").ok, "https allowed")
	_assert_true(Guard.authorize("http://example.com:8080/x").ok, "http with port allowed")
	var ftp := Guard.authorize("ftp://example.com/")
	_assert_eq(ftp.code, "permission_denied", "non-http scheme denied")


func _test_structural_rejections() -> void:
	_assert_eq(Guard.authorize("example.com").code, "invalid_param", "scheme required")
	_assert_eq(
		Guard.authorize("http://user:pass@example.com/").code, "invalid_param", "credentials denied"
	)
	_assert_eq(Guard.authorize("http://example.com/#frag").code, "invalid_param", "fragment denied")
	_assert_eq(Guard.authorize("http://:1/").code, "invalid_param", "empty host denied")
	_assert_eq(Guard.authorize("http://example.com:70000/").code, "invalid_param", "port range")
```

（`_assert_true`/`_assert_eq` helper 沿用文件现有实现。）

- [ ] **Step 5: 更新 `tests/e2e/m6/test_network_request.py`**

- 所有 body 删除 `"force": True`。
- 私网拒绝测试（:11-14 请求 `http://10.0.0.1/ok`）改为：不再 permission_denied，改为"连接类错误"：

```python
def test_network_request_unreachable_host(m6_editor_network):
    error = exec_error(m6_editor_network, "network/http_request", {
        "url": "http://10.0.0.1/ok",
    })
    assert error["code"] in {"godot_error", "timeout"}
```

- redirect-private（:17-21）：私网目标现在允许，改为断言成功重定向：

```python
def test_network_request_redirect_is_followed(m6_editor_network, local_http_server):
    result = exec_ok(m6_editor_network, "network/http_request", {
        "url": local_http_server.url("/redirect-ok"),
    })
    assert result["status"] == 200
    assert result["redirects"] == 1
```

- /large + `max_response_bytes: 1024`（:47-52）：现在 `body_size_limit` 在下载阶段截断，断言 `truncated is True and size <= 1024`（若 result 为 error，断言 code 是 `godot_error` 且说明 body_size_limit 未生效——按失败处理）。改为：

```python
    result = _exec_raw(m6_editor_network, "network/http_request", {
        "url": local_http_server.url("/large"), "max_response_bytes": 1024,
    })
    assert result.get("code") is None or result.get("code") == ""
    assert result["truncated"] is True
    assert result["size"] <= 1024
```

- redirect-loop（:24-28）与 redirect-limit 断言保持（`conflict`）。
- :40-43 timeout 用例保留（去 force）。

- [ ] **Step 6: 验证并提交**

```bash
python scripts/format-gd.py && python scripts/format-gd.py --check
gdlint gdapi/addon/runtime/services/network_target_guard.gd gdapi/addon/runtime/services/network_service.gd gdapi/addon/routes/network/http_request.gd tests/fixture_project/tests/test_network_target_guard.gd tests/fixtures/e2e_project/tests/test_network_target_guard.gd
cargo test --workspace
uv run pytest tests/e2e/m6/test_network_request.py -v
```

Commit: `fix(network): body_size_limit at download time; drop policy target allowlists`.

---

## Task 4: bulk 栈整改

**Files:**
- Modify: `gdapi/addon/runtime/services/bulk_file_service.gd:22-25,102-105`
- Modify: `gdapi/addon/runtime/services/bulk_deploy_service.gd`
- Modify: `gdapi/addon/routes/filesystem/batch/delete.gd`、`replace.gd`、`recover.gd`
- Modify: `gdapi/addon/routes/export/android/deploy_many.gd`
- Modify: `tests/e2e/m6/test_bulk_files.py`、`test_bulk_deploy.py`

**Interfaces:**
- Consumes: `GdApiBulkFileService.delete(body)` / `replace(body)` 仍要求 `plan_hash` 一致才 apply（保留，非权限门禁）

- [ ] **Step 1: 改 `bulk_file_service.gd`**

- `delete()`：删除

```gdscript
	if not bool(body.get("force", false)):
		return _error(ErrorCodes.UNSAFE_OPERATION, "batch delete requires force:true")
```

- `replace()`：删除

```gdscript
	if not bool(body.get("force", false)):
		return _error(ErrorCodes.UNSAFE_OPERATION, "batch replace requires force:true")
```

- 保留 `plan_hash` 一致性检查、trash + manifest + rollback、dry_run 语义。

- [ ] **Step 2: 改 `bulk_deploy_service.gd`**

- 删除 apply 路径中的 force 检查；`deploy_many` 传给 bridge 的 body 中 `"force": true` 字段删除（Task 8 中 bridge 会删 force 检查，这里去掉传入）。
- 保留 serials 校验、plan_hash、每设备终态。

- [ ] **Step 3: 改 4 个 route handler**

每个文件：
1. 删除 `Policy` preload 与 gate 块（`authorize("bulk_files"/"bulk_deploy", ...)` 拒绝分支 + 对应 denial audit）。
2. 保留 outcome audit，summary 删除 `"force"` 字段（如 `{"dry_run": ..., "count": ...}`）。
3. `doc()`：删除 `force` param、示例中的 `"force":true`、desc 中 force 措辞（如"再以 force:true 应用"→"再以 plan_hash 应用"）。

- [ ] **Step 4: 更新 `tests/e2e/m6/test_bulk_files.py` 与 `test_bulk_deploy.py`**

- 所有 body 删除 `"force": True`（grep 定位：test_bulk_files.py:50、54；test_bulk_deploy.py:22；m6/conftest.py 的 `replace_plan`/`apply_replace`/`delete_plan`/`apply_delete` 辅助函数 :323、:335、:364、:373）。
- test_bulk_deploy.py:21-25 的 deny-all 断言（`permission_denied`）删除——policy 已移除；改为断言无 permission_denied 或直接删除该用例（apply 流程由 test_bulk_files 覆盖）。
- test_bulk_files.py recover 二次调用 `conflict` 断言保留。

- [ ] **Step 5: 验证并提交**

```bash
python scripts/format-gd.py && python scripts/format-gd.py --check
gdlint gdapi/addon/runtime/services/bulk_file_service.gd gdapi/addon/runtime/services/bulk_deploy_service.gd gdapi/addon/routes/filesystem/batch/delete.gd gdapi/addon/routes/filesystem/batch/replace.gd gdapi/addon/routes/filesystem/batch/recover.gd gdapi/addon/routes/export/android/deploy_many.gd
cargo test --workspace
uv run pytest tests/e2e/m6/test_bulk_files.py tests/e2e/m6/test_bulk_deploy.py -v
```

Commit: `refactor(bulk): drop force gate, keep plan_hash consistency check`.

---

## Task 5: 场景/脚本/文件/资源/审计域 force 移除 + script/write 审计名修复

**Files:**
- Modify: `gdapi/addon/runtime/error_codes.gd:34-38`（删 `require_force`）
- Modify: `gdapi/addon/routes/gdapi/audit/clear.gd`（整体替换）
- Modify: `gdapi/addon/routes/scene/create.gd`、`save.gd`、`add_node.gd`、`load_sprite.gd`、`export_mesh_library.gd`、`scene/current/save.gd`
- Modify: `gdapi/addon/runtime/services/scene_editor.gd:89-132`
- Modify: `gdapi/addon/routes/script/create.gd`、`write.gd`、`patch.gd`
- Modify: `gdapi/addon/runtime/services/text_edit.gd:65-112,116-161`（**含 script/write 审计名修复**）
- Modify: `gdapi/addon/routes/filesystem/write.gd`
- Modify: `gdapi/addon/routes/resource/create.gd`、`delete.gd`、`move.gd`
- Modify: `gdapi/addon/runtime/services/resource_editor.gd:147-177,202-204,264-288,308-310,323-354`
- Modify: `tests/e2e/m2/test_filesystem_routes.py`、`test_resource_routes.py`、`test_scene_editor.py`、`test_script_routes.py`
- Modify: `tests/e2e/test_m1_smoke.py`、`tests/e2e/shared_fixture.py:362`

**Interfaces:**
- Produces: `TextEditService.create_script(path, content, route := "script/create")`、`write_script(path, content, route := "script/write")`、`patch_script(path, first, last, text)`；`SceneEditor.save_scene(path)`；`ResourceEditor.create(path, type, properties)` / `delete(path)` / `move(from_path, to_path)`

- [ ] **Step 1: 删除 `error_codes.gd` 的 `require_force`**

删除 `require_force` 函数（34-38 行）。`UNSAFE_OPERATION` 常量与 `HTTP_STATUS` 映射保留。

- [ ] **Step 2: 整体替换 `gdapi/audit/clear.gd`**

```gdscript
@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")

const ROUTE := "gdapi/audit/clear"


func handle(_req: GdApiRequest, res: GdApiResponse) -> void:
	if not Engine.has_meta("gdapi_plugin"):
		res.error("gdapi plugin is unavailable", ErrorCodes.GODOT_ERROR, 500)
		return
	var plugin = Engine.get_meta("gdapi_plugin")
	plugin.clear_audit()
	AuditLog.record(ROUTE, "dangerous", {}, true, "")
	res.json({"ok": true, "cleared": true, "changed": true, "undoable": false})


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("清空 gdapi 审计日志")
		. desc("清空内存审计缓冲区。")
		. returns("清空结果", {"ok": "bool", "cleared": "bool", "changed": "bool", "undoable": "bool"})
	)
```

- [ ] **Step 3: scene 域（5 个文件型 route + current/save）**

通用变换（每个文件按 grep 到的当前代码执行）：
1. 删除 `var force: bool = req.get_body("force", false)` 及 `ErrorCodes.require_force(...)` 块与对应 denial audit。
2. "目标已存在时要求 force"（create.gd:33-42、save.gd:49-58、export_mesh_library.gd:45-54）→ 删除整个块，直接保存/覆盖。
3. "始终要求 force"（add_node.gd:38-46、load_sprite.gd:33-41）→ 删除整个块。
4. 成功 audit summary 删除 `"force"` 字段（如 `{"target": ..., "force": force}` → `{"target": ...}`）。
5. `doc()`：删除 `force` param 与示例中的 `"force":...`，desc 去掉 force 措辞。
6. `res.error(..., 403 if ... else 400)` 类三元（若本文件存在）→ `ErrorCodes.http_status(code)`（需确认该文件已 preload ErrorCodes；scene/create.gd 等已有）。

`scene_editor.gd` 的 `save_scene(path, force)` → `save_scene(path)`：删除 `force` 参数、`target_exists and not force` 块（102-115）与其 audit；成功 audit（131）summary 去掉 force。route `scene/current/save.gd` 对应改调用与 doc。

- [ ] **Step 4: script 域 — 含审计名修复（缺口）**

`text_edit.gd`：

```gdscript
## 写入新脚本文件（或覆盖已有文件）。
static func create_script(path: String, content: String, route: String = "script/create") -> Dictionary:
	var checked := PathGuard.validate(path, "write")
	if not checked.ok:
		return {"ok": false, "code": checked.code, "error": checked.error}
	if not content.ends_with("\n"):
		content += "\n"
	var dir: String = checked.path.get_base_dir()
	if dir != "res://" and !DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(dir)):
		return {"ok": false, "code": ErrorCodes.INVALID_PATH, "error": "directory does not exist"}
	var abs_path := ProjectSettings.globalize_path(checked.path)
	var tmp := abs_path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "code": ErrorCodes.GODOT_ERROR, "error": "cannot write file"}
	f.store_string(content)
	f.close()
	DirAccess.rename_absolute(tmp, abs_path)
	AuditLog.record(route, "file", {"path": checked.path}, true, "")
	return {
		"ok": true,
		"changed": true,
		"saved": true,
		"undoable": false,
		"path": checked.path
	}


## 完整覆盖写入（等价于 create_script，审计名不同）。
static func write_script(path: String, content: String, route: String = "script/write") -> Dictionary:
	return create_script(path, content, route)
```

（删除 force 参数、force 检查与对应 audit；audit route 名由调用方 route 决定——**修复 script/write 审计记为 script/create 的缺口**。`patch_script(path, first, last, text)`：删除 `force` 参数与 137-143 的 force 检查；"有变化才写盘"逻辑保留，无变化返回 `{"ok": true, "changed": false, ...}` 不写盘；成功 audit（157-160）summary 删除 force。）

对应 route 文件：
- `script/create.gd`：`TextEditService.create_script(path, content)`，doc 去 force。
- `script/write.gd`：`TextEditService.write_script(path, content)`，doc 去 force、desc 不再提"必须 force"。
- `script/patch.gd`：`TextEditService.patch_script(path, first, last, text)`，doc 去 force。
- 三个文件的 `res.error(..., 403 if result.code == "unsafe_operation" else 400)` → `res.error(result.error, result.code, ErrorCodes.http_status(result.code))`。

- [ ] **Step 5: `filesystem/write.gd`**

删除 `force` 读取（:18）、exists 检查块（:30-41）与对应 audit；成功 audit（:53）summary 去 force；doc 去 force。

- [ ] **Step 6: resource 域**

`resource_editor.gd`：
- `create(path, type, properties)`：删 force 参数、165-177 的 exists/force 块与其 audit；成功 audit（202-204）summary 去 force。
- `move(from_path, to_path)`：删 force 参数、276-288 块；audit（308-310）去 force。
- `delete(path)`：删 force 参数、334-346 块；audit（354）去 force。
- route 文件（create/delete/move.gd）：删 force 读取与传参；`403 if result.code == "unsafe_operation" else 400` → `ErrorCodes.http_status(result.code)`；doc 去 force。

- [ ] **Step 7: 更新 m2 测试与共享 harness**

- `tests/e2e/m2/test_filesystem_routes.py`：
  - `test_filesystem_write_requires_force`（:24-42）→ 改写为"覆盖已有文件直接成功"：

```python
def test_filesystem_write_overwrites_without_force(m2_editor):
    path = "res://notes/test.md"
    exec_ok(m2_editor, "filesystem/write", {"path": path, "content": "first"})
    written = exec_ok(m2_editor, "filesystem/write", {"path": path, "content": "second"})
    assert written["saved"] is True
    assert exec_ok(m2_editor, "filesystem/read", {"path": path})["content"] == "second"
```

  - `test_filesystem_write_atomic_with_force`（:45-59）→ 去 force。
  - parametrize（:61-64）中 `"force": True` 字段删除。
- `tests/e2e/m2/test_resource_routes.py`：
  - `test_resource_overwrite_requires_force`（:31-43）→ 改为覆盖成功；`delete`（:48-55）去 force。

```python
def test_resource_overwrite_without_force(m2_editor):
    created = exec_ok(m2_editor, "resource/create", {
        "path": "res://resources/generated.tres",
        "type": "Resource",
        "properties": {"resource_name": "Generated"},
    })
    assert created["saved"] is True
    overwritten = exec_ok(m2_editor, "resource/create", {
        "path": "res://resources/generated.tres",
        "type": "Resource",
        "properties": {"resource_name": "Again"},
    })
    assert overwritten["saved"] is True
    deleted = exec_ok(m2_editor, "resource/delete", {
        "path": "res://resources/generated.tres",
    })
    assert deleted["deleted"] is True
```

- `tests/e2e/m2/test_scene_editor.py`：
  - `test_scene_current_save_rejects_overwrite_without_force`（:47-54）→ 改为"同路径再次另存直接覆盖成功"。
- `tests/e2e/m2/test_script_routes.py`：
  - :18-28 patch 用例去 force、删除无 force 拒绝断言。
  - parametrize（:45-49）删除 `("script/write", {"path": ..., "content": "x"}, "unsafe_operation")` 一行；其余去 force。
- `tests/e2e/test_m1_smoke.py`：
  - `test_audit_clear_requires_force` → 改为"无 force 清空成功"：

```python
def test_audit_clear_without_force(e2e_editor):
    resp = _exec(e2e_editor, "gdapi/audit/clear")
    assert resp["ok"] is True
    assert resp["cleared"] is True
```

  - `test_uid_update_requires_force`（:184-186）→ Task 7 一并处理（uid/update_all 在本 task 未动）；此处先删除该测试或留待 Task 7——**留待 Task 7**，本 task 跳过该文件内 uid 测试。
- `tests/e2e/shared_fixture.py:362`：`{"force": True}` → `{}`。

- [ ] **Step 8: 验证并提交**

```bash
python scripts/format-gd.py && python scripts/format-gd.py --check
gdlint gdapi/addon/runtime/error_codes.gd gdapi/addon/routes/gdapi/audit/clear.gd gdapi/addon/routes/scene gdapi/addon/routes/script gdapi/addon/routes/filesystem/write.gd gdapi/addon/routes/resource gdapi/addon/runtime/services/scene_editor.gd gdapi/addon/runtime/services/text_edit.gd gdapi/addon/runtime/services/resource_editor.gd
cargo test --workspace
uv run pytest tests/e2e/m2/test_filesystem_routes.py tests/e2e/m2/test_resource_routes.py tests/e2e/m2/test_scene_editor.py tests/e2e/m2/test_script_routes.py -v
uv run pytest tests/e2e/test_m1_smoke.py -v
```

Commit: `refactor(write paths): drop force gates; fix script/write audit route name`.

---

## Task 6: M4 域 force 移除 + theme 类型精确 + tilemap 审计 + doc 补齐 + HTTP 状态映射

**Files:**
- Modify: `gdapi/addon/runtime/services/material_editor.gd:87-105,154-183`
- Modify: `gdapi/addon/runtime/services/shader_editor.gd:25-68,92-127,211-230`
- Modify: `gdapi/addon/runtime/services/theme_editor.gd`（整体替换）
- Modify: `gdapi/addon/runtime/services/navigation_editor.gd:21-59`
- Modify: `gdapi/addon/runtime/services/tilemap_editor.gd:126-138`（**+ 审计**）
- Modify: `gdapi/addon/runtime/services/audio_editor.gd:37-59`
- Modify: `gdapi/addon/routes/material/save.gd`、`duplicate.gd`；`shader/write.gd`、`shader/material/create.gd`、`shader/param/set.gd`；`theme/create.gd`、`theme/color/set.gd`、`theme/constant/set.gd`、`theme/font_size/set.gd`、`theme/stylebox/set.gd`；`navigation/mesh/bake.gd`；`tilemap/layer/clear.gd`；`audio/bus/remove.gd`
- Modify: `gdapi/addon/routes/physics/body/create.gd`、`physics/shape/create.gd`、`physics/layer/set.gd`、`physics/joint/create.gd`（doc 补齐 + 状态映射）
- Modify: `gdapi/addon/routes/audio/bus/list.gd`（doc desc 补齐）
- Modify: `tests/e2e/m4/test_rendering.py`、`test_tilemap.py`、`test_navigation.py`、`test_audio.py`、`test_m4_contract.py`

- [ ] **Step 1: `theme_editor.gd` 整体替换（force 移除 + 类型精确，缺口）**

```gdscript
@tool
class_name GdApiThemeEditor
extends RefCounted

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")
const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")
const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")
const VariantCodec := preload("res://addons/gdapi/runtime/variant_codec.gd")


static func create(path: Variant) -> Dictionary:
	var checked := _path(path, "write")
	if not checked.ok:
		return checked
	var theme := Theme.new()
	return _save(theme, checked.path, "theme/create")


static func set_item(
	path: Variant, kind: String, type_name: Variant, item: Variant, value: Variant
) -> Dictionary:
	var checked := _path(path, "write")
	if not checked.ok:
		return checked
	var theme := ResourceLoader.load(checked.path, "Theme", ResourceLoader.CACHE_MODE_IGNORE)
	if not theme is Theme:
		return _error(ErrorCodes.NOT_FOUND, "theme not found")
	var decoded := VariantCodec.decode(value)
	if not decoded.ok:
		return _error(ErrorCodes.INVALID_PARAM, decoded.error)
	match kind:
		"color":
			if not decoded.value is Color:
				return _error(ErrorCodes.INVALID_PARAM, "value must be a Color")
			theme.set_color(String(item), String(type_name), decoded.value)
		"constant":
			if typeof(decoded.value) != TYPE_INT:
				return _error(ErrorCodes.INVALID_PARAM, "value must be an int")
			theme.set_constant(String(item), String(type_name), int(decoded.value))
		"font_size":
			if typeof(decoded.value) != TYPE_INT:
				return _error(ErrorCodes.INVALID_PARAM, "value must be an int")
			theme.set_font_size(String(item), String(type_name), int(decoded.value))
		_:
			return _error(ErrorCodes.INVALID_PARAM, "unsupported theme item kind")
	return _save(theme, checked.path, "theme/" + kind + "/set")


static func set_stylebox(
	path: Variant, type_name: Variant, item: Variant, value: Variant
) -> Dictionary:
	var checked := _path(path, "write")
	if not checked.ok:
		return checked
	var theme := ResourceLoader.load(checked.path, "Theme", ResourceLoader.CACHE_MODE_IGNORE)
	if not theme is Theme:
		return _error(ErrorCodes.NOT_FOUND, "theme not found")
	var decoded := VariantCodec.decode(value)
	if not decoded.ok or not decoded.value is StyleBox:
		return _error(ErrorCodes.INVALID_PARAM, "value must be a StyleBox")
	theme.set_stylebox(String(item), String(type_name), decoded.value)
	return _save(theme, checked.path, "theme/stylebox/set")


static func _save(resource: Resource, path: String, route: String) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path).get_base_dir())
	var error := ResourceSaver.save(resource, path)
	if error != OK:
		AuditLog.record(route, "file", {"path": path}, false, ErrorCodes.GODOT_ERROR)
		return _error(ErrorCodes.GODOT_ERROR, "failed to save theme")
	AuditLog.record(route, "file", {"path": path}, true)
	return {"ok": true, "changed": true, "saved": true, "undoable": false, "path": path}


static func _path(path: Variant, mode: String) -> Dictionary:
	if typeof(path) != TYPE_STRING:
		return _error(ErrorCodes.INVALID_PARAM, "path must be a string")
	var checked := PathGuard.validate(path, mode)
	if not checked.ok:
		return _error(checked.code, checked.error)
	if (
		not String(checked.path).begins_with("res://")
		or not String(checked.path).ends_with(".tres")
	):
		return _error(ErrorCodes.INVALID_PATH, "theme path must be project-local .tres")
	return checked


static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "error": message}
```

（`_force` 删除；`_save` 补失败审计——顺带修复 review INFO 项。）

- [ ] **Step 2: 其余 M4 service 的 force 移除**

每个文件删除 force 参数与检查块（grep 已定位确切行）：
- `material_editor.gd`：`save(node_path, path, route := "material/save")`、`duplicate_material(node_path, path)`；`_save_resource(resource, path, route)` 删除 typeof(force) 检查（161-163）、exists/force 块（164-174）及其 audit；成功 audit（182）summary 去 force。
- `shader_editor.gd`：`write(path, source)` 删除 37-52 的 force 检查；`create_material(shader_path, path)`；`set_param(path, name, value)` 删除 117-127 的 force 检查；`_save_material(material, path, route)` 删除 force 参数与 218-227 块；audit summary（:67）去 force。
- `navigation_editor.gd`：`bake(region_path, path)` 删除 37-48 的 exists/force 块；audit（:57）summary 去 force。
- `tilemap_editor.gd`：`clear(path)` 删除 126-132 的 force 检查，**并补审计（缺口）**：

```gdscript
static func clear(path: String) -> Dictionary:
	var found := layer(path)
	if not found.ok:
		return found
	found.layer.clear()
	var saved := _save_layer()
	if not saved.ok:
		return saved
	AuditLog.record("tilemap/layer/clear", "dangerous", {"layer_path": path}, true, "")
	return {"ok": true, "changed": true, "undoable": false}
```

（按现有 `clear` 的实现体调整——保留原有 layer 查找与保存逻辑，仅替换 force 门与补 audit；`tilemap_editor.gd` 需新增 `AuditLog` preload。）

- `audio_editor.gd`：`remove_bus(name)` 删除 46-54 的 force 检查与其 audit；成功路径保留 `_save_layout("audio/bus/remove")` 的审计（:145）。

- [ ] **Step 3: M4 route 文件更新**

每个 route：删除 force 读取/传参、删除 `_send` 中 `403 if ... else 400`（统一 `ErrorCodes.http_status(r.code)`，需加 `ErrorCodes` preload——检查各文件，缺失则加）、doc 删 force param/示例/措辞。`_send` 统一为：

```gdscript
func _send(res: GdApiResponse, r: Dictionary) -> void:
	if r.ok:
		res.json(r)
	else:
		res.error(r.error, r.code, ErrorCodes.http_status(r.code))
```

`physics/*` 四个 route 的 `_send` 中 `501 if r.code == "not_supported" else 400` 同样替换为 `ErrorCodes.http_status(r.code)`（not_supported→501、其余→映射值）。

- [ ] **Step 4: M4 doc() 补齐（缺口：10 个 route）**

`physics/body/create.gd`：

```gdscript
func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("创建 2D 物理体")
		. desc("在当前编辑场景中创建 StaticBody2D/CharacterBody2D/RigidBody2D 并挂到 parent_path 下，接入 UndoRedo。")
		. param("parent_path", "String", true, "父节点绝对路径")
		. param("name", "String", true, "新节点名称")
		. param("type", "String", false, "物理体类型，缺省值见 physics_editor.gd", "")
		. example('{"parent_path":"/root/PhysicsDomain","name":"Wall","type":"StaticBody2D"}')
		. returns("body", {"undoable": "true"})
	)
```

`physics/shape/create.gd`：

```gdscript
func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("创建 2D 碰撞形状")
		. desc("给物理体挂 CollisionShape2D；shape 支持 rectangle/circle/capsule，接入 UndoRedo。")
		. param("body_path", "String", true, "物理体节点路径")
		. param("shape", "String", true, "形状类型 rectangle|circle|capsule")
		. param("size", "Variant", true, "尺寸（rectangle 为 Vector2，circle/capsule 为数值）")
		. example('{"body_path":"/root/PhysicsDomain/Wall","shape":"rectangle","size":{"type":"Vector2","value":[4.0,2.0]}}')
		. returns("shape", {"undoable": "true"})
	)
```

`physics/layer/set.gd`：

```gdscript
func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("设置 2D 碰撞层")
		. desc("设置节点 collision_layer/collision_mask 属性，接入 UndoRedo。")
		. param("node_path", "String", true, "目标节点路径")
		. param("property", "String", true, "collision_layer 或 collision_mask")
		. param("value", "int", true, "层位掩码")
		. example('{"node_path":"/root/PhysicsDomain/Wall","property":"collision_layer","value":1}')
		. returns("layer", {"undoable": "true"})
	)
```

`physics/joint/create.gd`：

```gdscript
func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("创建 2D 物理关节")
		. desc("在当前编辑场景中创建 PinJoint2D/GrooveJoint2D/DampedSpringJoint2D 并挂到 parent_path 下，接入 UndoRedo。")
		. param("parent_path", "String", true, "父节点绝对路径")
		. param("type", "String", true, "关节类型")
		. param("name", "String", false, "新节点名称", "Joint")
		. example('{"parent_path":"/root/PhysicsDomain","type":"PinJoint2D","name":"Pivot"}')
		. returns("joint", {"undoable": "true"})
	)
```

`theme/color/set.gd`：

```gdscript
func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("设置 Theme 颜色")
		. desc("修改项目内 .tres Theme 的 color item 并保存（不可撤销）。")
		. param("path", "String", true, "Theme 的 res:// 路径")
		. param("type", "String", false, "控件类型名", "Control")
		. param("item", "String", true, "item 名")
		. param("value", "Variant", true, "Color 编码值")
		. example('{"path":"res://themes/main.tres","type":"Button","item":"font_color","value":{"type":"Color","value":[1.0,0.0,0.0]}}')
		. returns("theme", {"undoable": "false"})
	)
```

`theme/constant/set.gd` 与 `theme/font_size/set.gd`：同上结构，`make("设置 Theme 常量"/"设置 Theme 字号")`，value 描述 "int"；示例 `"value": 4` / `"value": 16`。

`theme/stylebox/set.gd`：

```gdscript
func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("设置 Theme StyleBox")
		. desc("修改项目内 .tres Theme 的 stylebox item 并保存（不可撤销）。")
		. param("path", "String", true, "Theme 的 res:// 路径")
		. param("type", "String", true, "控件类型名")
		. param("item", "String", true, "item 名")
		. param("value", "Variant", true, "StyleBox 编码值")
		. example('{"path":"res://themes/main.tres","type":"Button","item":"normal","value":{"type":"Resource","value":"res://resources/box.tres"}}')
		. returns("theme", {"undoable": "false"})
	)
```

`audio/bus/list.gd`：doc 补 desc（无参数 route，无需 example）：

```gdscript
	return (
		GdApiRouteDoc
		. make("列出音频总线")
		. desc("返回当前 AudioServer 的全部总线名（排序后）。")
		. returns("buses", {"buses": "Array<String>", "undoable": "false"})
	)
```

`navigation/region/list.gd`：已有 desc/returns，无参数；补一个说明即可（可跳过——无参数 route 不受 example 要求约束；确认无 .param 缺失后不动）。

- [ ] **Step 5: 更新 m4 测试**

- `test_rendering.py`：`test_shader_write_requires_force_for_existing_project_file`（:21-27）→ 改为"无 force 覆盖成功"；其余 body 去 force（:86、:99、:105、:128）。
- `test_tilemap.py`：`test_tilemap_rejects_invalid_cell_and_clear_without_force`（:40-43）→ 拆为：非法坐标仍 invalid_param；clear 无 force 直接成功（断言 cleared/changed）。
- `test_navigation.py`：`test_navigation_regions_bake_to_project_local_resource_with_force`（:19-39）→ 去 force，改名去掉 `_with_force`。
- `test_audio.py`：bus remove 相关 body 去 force（grep 定位）。
- `test_m4_contract.py`：force 相关条目（若有）去 force。

- [ ] **Step 6: 验证并提交**

```bash
python scripts/format-gd.py && python scripts/format-gd.py --check
gdlint gdapi/addon/runtime/services/material_editor.gd gdapi/addon/runtime/services/shader_editor.gd gdapi/addon/runtime/services/theme_editor.gd gdapi/addon/runtime/services/navigation_editor.gd gdapi/addon/runtime/services/tilemap_editor.gd gdapi/addon/runtime/services/audio_editor.gd gdapi/addon/routes/material gdapi/addon/routes/shader gdapi/addon/routes/theme gdapi/addon/routes/navigation gdapi/addon/routes/tilemap gdapi/addon/routes/audio gdapi/addon/routes/physics
cargo test --workspace
uv run pytest tests/e2e/m4/ -v
```

Commit: `fix(m4): drop force gates, type-check theme values, audit tilemap clear, complete docs`.

---

## Task 7: project/uid/classdb/diagnostics 域 + 小修

**Files:**
- Modify: `gdapi/addon/runtime/services/project_config.gd:57-76,106-143,178-193`
- Modify: `gdapi/addon/routes/project/settings/reset.gd`、`project/input_map/action/remove.gd`、`project/input_map/unbind.gd`、`project/autoload/remove.gd`
- Modify: `gdapi/addon/routes/uid/update_all.gd:23-27`、`gdapi/addon/runtime/services/uid_repair.gd:11-19`
- Modify: `gdapi/addon/routes/uid/repair.gd:11`（状态映射）
- Modify: `gdapi/addon/routes/classdb/methods.gd`、`properties.gd`、`signals.gd`、`inheriters.gd`（out.ok 检查）
- Modify: `gdapi/addon/routes/diagnostics/health.gd`、`unused_resources.gd`、`cycle_deps.gd`、`script_errors.gd`（out.ok 检查）
- Modify: `gdapi/addon/routes/runtime/status.gd:25-40`（fallback 字段补齐）
- Modify: `gdapi/addon/runtime/response.gd:93`（`read_error` → `godot_error`）
- Modify: `gdapi/addon/routes/scene/current.gd:52`（doc 修正）
- Modify: `tests/e2e/m5/test_m5_smoke.py:19`、`test_uid_repair.py`、`test_project_config_routes.py`、`test_classdb_routes.py`、`test_diagnostics_routes.py`
- Modify: `tests/e2e/test_m1_smoke.py:184-186`

- [ ] **Step 1: `project_config.gd`**

- `reset(name)`：删除 `force` 参数与 58-62 的 force 检查；audit（:75）summary 去 force。
- `remove_action(name)`：删除 force 检查（107-111）；`unbind(name, event)`：删除 128-132；`remove_autoload(name)`：删除 178-182。
- 对应 4 个 route 文件：删 force 读取/传参、doc 去 force、示例去 `"force":true`。

- [ ] **Step 2: `uid/update_all.gd`**

删除 24-27 的 require_force 块与其 denial audit；保留其余逻辑。doc 删 force param、示例去 force。

- [ ] **Step 3: `uid_repair.gd`**

```gdscript
static func repair(body: Dictionary) -> Dictionary:
	var dry_run := bool(body.get("dry_run", true))
	var paths: Array = []
	# 其余逻辑保持不变
```

（删除 force 读取与 13-19 的检查；dry_run 语义保留。）

`routes/uid/repair.gd`：`res.error(out.error, out.code, 400, ...)` → `res.error(out.error, out.code, ErrorCodes.http_status(out.code), ...)`；doc 删 force param（:20）。

- [ ] **Step 4: classdb 与 diagnostics 的 out.ok 检查（缺口）**

`classdb/methods.gd`、`properties.gd`、`signals.gd`、`inheriters.gd` 的 handle 从：

```gdscript
func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	res.json(S.members(req))  # 各文件具体调用不同
```

改为（以 `classdb/class.gd:9-11` 的既有模式为准）：

```gdscript
func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var out := S.members(req)  # 保留各文件原有调用
	if out.ok:
		res.json(out)
	else:
		res.error(out.error, out.code, ErrorCodes.http_status(out.code))
```

（各文件需确认 `ErrorCodes` preload；`classdb_query.gd` 返回 `not_found` 时现在走 404。`diagnostics/*.gd` 四个 route 同样处理：`S.analyze(req)` / `S.health(req)` 等调用先查 `out.ok`，失败走 `res.error`。）

- [ ] **Step 5: 小修三处**

- `routes/runtime/status.gd` broker==null 分支补齐字段：

```gdscript
	if broker == null:
		res.json(
			{
				"ok": true,
				"state": "stopped",
				"protocol_version": 1,
				"session_id": -1,
				"pending": 0,
				"broker_registered": false,
				"session_started_at": 0.0,
				"transport": "none",
				"editor_playing": editor_playing,
			}
		)
		return
```

- `runtime/response.gd:93`：`error("cannot read file: " + path, "read_error", 500)` → `error("cannot read file: " + path, "godot_error", 500)`。
- `routes/scene/current.gd:52` doc：`"edited": "bool, 是否未保存的临时场景(目前恒为 false)"` → `"edited": "bool, 场景未落盘(路径为空或未保存)时为 true"`。

- [ ] **Step 6: 更新 m5/m1 测试**

- `test_m5_smoke.py:19`：

```python
def test_uid_repair_applies_without_force(m5_editor):
    result = exec_ok(m5_editor, "uid/repair", {"roots": ["res://fixtures"], "dry_run": False})
    assert result["ok"] is True
```

- `test_uid_repair.py`：body 去 force（:11）。
- `test_project_config_routes.py`、`test_classdb_routes.py`、`test_diagnostics_routes.py`：force 相关断言（若有）去 force；classdb unknown class 断言若期望 404，保持（行为增强一致）。
- `test_m1_smoke.py:184-186`：`test_uid_update_requires_force` → 改为"无 force 执行成功"：

```python
def test_uid_update_without_force(e2e_editor):
    resp = _exec(e2e_editor, "uid/update_all", '{"project_path":"res://tests"}')
    assert resp["ok"] is True
```

- [ ] **Step 7: 验证并提交**

```bash
python scripts/format-gd.py && python scripts/format-gd.py --check
gdlint gdapi/addon/runtime/services/project_config.gd gdapi/addon/runtime/services/uid_repair.gd gdapi/addon/routes/project gdapi/addon/routes/uid gdapi/addon/routes/classdb gdapi/addon/routes/diagnostics gdapi/addon/routes/runtime/status.gd gdapi/addon/runtime/response.gd gdapi/addon/routes/scene/current.gd
cargo test --workspace
uv run pytest tests/e2e/m5/ -v
uv run pytest tests/e2e/test_m1_smoke.py -v
```

Commit: `fix(project/uid/classdb): drop force, error-status consistency, out.ok checks`.

---

## Task 8: export/android 域（失败审计 + timeout 上限 + deploy 审计 + 测试 unskip）

**Files:**
- Modify: `gdapi/addon/runtime/services/export_service.gd:32-99`
- Modify: `gdapi/addon/runtime/services/android_bridge.gd:33-85`
- Modify: `gdapi/addon/routes/export/run.gd`、`export/android/deploy.gd`
- Modify: `tests/e2e/m5/test_export_android.py`（unskip）、`test_m5_smoke.py:20`

- [x] **Step 1: `export_service.run()` — 删除 force、补失败审计、timeout 上限（缺口）**

修改点：
1. 删除 43-44 的 exists/force 冲突检查（目标存在直接覆盖）。
2. `var deadline := Time.get_ticks_msec() + int(body.get("timeout_ms", 120000))` → `var deadline := Time.get_ticks_msec() + clampi(int(body.get("timeout_ms", 120000)), 10000, 600000)`。
3. 失败分支（71-89）补审计：

```gdscript
	if exit_code != 0 or not FileAccess.file_exists(output):
		if FileAccess.file_exists(output):
			DirAccess.remove_absolute(output)
		if (
			output_text.to_lower().contains("template")
			or output_text.to_lower().contains("not installed")
		):
			AuditLog.record(
				"export/run", "dangerous", {"preset": preset_name, "path": checked.path},
				false, ErrorCodes.NOT_SUPPORTED
			)
			return {
				"ok": false,
				"code": ErrorCodes.NOT_SUPPORTED,
				"error": "export template is unavailable",
				"details": {"platform": found.platform, "preset": preset_name}
			}
		AuditLog.record(
			"export/run", "dangerous", {"preset": preset_name, "path": checked.path},
			false, ErrorCodes.GODOT_ERROR
		)
		return {
			"ok": false,
			"code": ErrorCodes.GODOT_ERROR,
			"error": "export failed",
			"details": {"exit_code": exit_code}
		}
```

4. 成功 audit（:90）保持（summary 已无 force）。

- [x] **Step 2: `android_bridge.deploy()` — 删除 force、补审计（缺口）**

类头加 `const AuditLog := preload("res://addons/gdapi/runtime/audit_log.gd")`。`deploy(body)`：

```gdscript
static func deploy(body: Dictionary) -> Dictionary:
	var serial := String(body.get("serial", ""))
	var regex := RegEx.new()
	regex.compile("^[A-Za-z0-9._:-]+$")
	if regex.search(serial) == null:
		return _record_deploy_failure(body, ErrorCodes.INVALID_PARAM, "invalid device serial")
	var package_name := String(body.get("package", ""))
	var activity := String(body.get("activity", ""))
	var identifier := RegEx.new()
	identifier.compile("^[A-Za-z][A-Za-z0-9_.]*$")
	if identifier.search(package_name) == null or identifier.search(activity) == null:
		return _record_deploy_failure(
			body, ErrorCodes.INVALID_PARAM, "invalid package or activity"
		)
	var path := PathGuard.validate(String(body.get("apk_path", "")), "read")
	if (
		not path.ok
		or not path.path.to_lower().ends_with(".apk")
		or not FileAccess.file_exists(path.path)
	):
		return _record_deploy_failure(body, ErrorCodes.INVALID_PATH, "APK path is invalid")
	var listed := devices()
	if not listed.ok:
		return _record_deploy_failure(body, String(listed.code), "device list unavailable")
	var selected: Array = listed.devices.filter(func(item): return item.serial == serial)
	if selected.size() != 1 or selected[0].state != "device":
		return _record_deploy_failure(
			body, ErrorCodes.NOT_SUPPORTED, "selected device is not online"
		)
	var adb := _adb_path()
	if adb.is_empty() or not FileAccess.file_exists(adb):
		return _record_deploy_failure(
			body, ErrorCodes.NOT_FOUND, "configured ADB executable not found"
		)
	var install := _execute(
		["-s", serial, "install", "-r", ProjectSettings.globalize_path(path.path)], 60000, adb
	)
	if not install.ok:
		return _record_deploy_failure(body, String(install.code), "adb install failed")
	var launch := _execute(
		["-s", serial, "shell", "am", "start", "-n", package_name + "/" + activity], 60000, adb
	)
	if not launch.ok:
		return _record_deploy_failure(body, String(launch.code), "adb launch failed")
	AuditLog.record(
		"export/android/deploy",
		"dangerous",
		{"serial": serial, "package": package_name},
		true
	)
	return {"ok": true, "serial": serial, "installed": true, "launched": true, "undoable": false}


static func _record_deploy_failure(body: Dictionary, code: String, message: String) -> Dictionary:
	AuditLog.record(
		"export/android/deploy",
		"dangerous",
		{
			"serial": body.get("serial", ""),
			"package": body.get("package", ""),
			"apk_path": body.get("apk_path", ""),
		},
		false,
		code
	)
	return {"ok": false, "code": code, "error": message}
```

（删除原 force 检查 34-39；审计不含 secret——serial/package/apk 路径均为非敏感。）

- [x] **Step 3: route 文件**

- `routes/export/run.gd`：`res.error(out.error, out.code, 400, ...)` → `res.error(out.error, out.code, ErrorCodes.http_status(out.code), ...)`（加 ErrorCodes preload）；doc 删 force param（:20）与示例 `"force":true`。
- `routes/export/android/deploy.gd`：同状态映射；doc 删 force param（:22）与示例 force（:29）。

- [x] **Step 4: 更新 `test_export_android.py` 并按工具链约束跳过 Android 用例**

- 保留模块级 `pytestmark = pytest.mark.skip(...)`：Android SDK/ADB 工具链不完善，相关用例按需求显式跳过。
- `test_export_android`（:14-18）：body 去 force；artifact 断言改为条件（模板缺失时设计要求显式 not_supported 而非 skip）：

```python
def test_export_run_verifies_artifact(m5_editor):
    output = Path(m5_editor["project"]) / "build" / "m5.pck"
    result = exec_export(m5_editor, "export/run", {
        "preset": "M5 PCK", "path": "res://build/m5.pck",
    })
    if result.get("code") == "not_supported":
        assert not output.exists()  # 模板缺失：显式错误且无半成品产物
    else:
        assert output.is_file()
        assert result["size"] == output.stat().st_size
```

- missing-template 测试（:27-30）：body 去 force；断言 `not_supported` 不变（该测试不依赖环境）。
- `test_m5_smoke.py:20`：`exec_error(..., {"serial": "bad", "force": False})["code"] == "unsafe_operation"` → `exec_error(..., {"serial": "bad"})["code"] == "invalid_param"`。

- [x] **Step 5: 验证并提交**

```bash
python scripts/format-gd.py && python scripts/format-gd.py --check
gdlint gdapi/addon/runtime/services/export_service.gd gdapi/addon/runtime/services/android_bridge.gd gdapi/addon/routes/export
cargo test --workspace
uv run pytest tests/e2e/m5/test_export_android.py tests/e2e/m5/test_m5_smoke.py -v
```

Commit: `fix(export): audit failures, bound export timeout, audit single-device deploy`.

---

## Task 9: 信号/分组 UndoRedo（缺口）

**Files:**
- Modify: `gdapi/addon/routes/node/signal/connect.gd`
- Modify: `gdapi/addon/routes/node/signal/disconnect.gd`
- Modify: `gdapi/addon/routes/node/group/add.gd`
- Modify: `gdapi/addon/routes/node/group/remove.gd`
- Modify: `tests/e2e/m2/test_signal_group_routes.py:18,25`

**Interfaces:**
- Consumes: `GdApiEditAction.undo_redo() -> EditorUndoRedoManager`

- [ ] **Step 1: `node/signal/connect.gd` — UndoRedo 化**

在文件头加 `const EditAction := preload("res://addons/gdapi/runtime/edit_action.gd")`，将 43-44 行替换为：

```gdscript
	var manager := EditAction.undo_redo()
	if manager == null:
		res.error("EditorUndoRedoManager is unavailable", ErrorCodes.NOT_SUPPORTED, 501)
		return
	var flags: int = int(req.get_body("flags", Object.CONNECT_PERSIST))
	manager.create_action("gdcli: connect signal", UndoRedo.MERGE_DISABLE, source)
	manager.add_do_method(source, "connect", signal_name, Callable(target, method), flags)
	manager.add_undo_method(source, "disconnect", signal_name, Callable(target, method))
	manager.commit_action()
```

（原 43 行的 `var flags` 声明上移。注意重复连接检查在 create_action 之前完成——失败不创建 action，符合"失败不创建 action"契约。）响应中 `"undoable": false` → `"undoable": true`；doc 的 returns 描述同步改。

- [ ] **Step 2: `node/signal/disconnect.gd`**

40 行替换为：

```gdscript
	var manager := EditAction.undo_redo()
	if manager == null:
		res.error("EditorUndoRedoManager is unavailable", ErrorCodes.NOT_SUPPORTED, 501)
		return
	manager.create_action("gdcli: disconnect signal", UndoRedo.MERGE_DISABLE, source)
	manager.add_do_method(source, "disconnect", signal_name, Callable(target, method))
	manager.add_undo_method(source, "connect", signal_name, Callable(target, method), Object.CONNECT_PERSIST)
	manager.commit_action()
```

（undo 用 CONNECT_PERSIST 恢复原 flags——与 connect 默认一致。）`undoable: false` → `true`；doc 同步。

- [ ] **Step 3: `node/group/add.gd`**

27 行替换为：

```gdscript
	var manager := EditAction.undo_redo()
	if manager == null:
		res.error("EditorUndoRedoManager is unavailable", ErrorCodes.NOT_SUPPORTED, 501)
		return
	manager.create_action("gdcli: add to group", UndoRedo.MERGE_DISABLE, node)
	manager.add_do_method(node, "add_to_group", group, persistent)
	manager.add_undo_method(node, "remove_from_group", group)
	manager.commit_action()
```

`undoable: false` → `true`；doc 同步。

- [ ] **Step 4: `node/group/remove.gd`**

26 行替换为：

```gdscript
	var manager := EditAction.undo_redo()
	if manager == null:
		res.error("EditorUndoRedoManager is unavailable", ErrorCodes.NOT_SUPPORTED, 501)
		return
	manager.create_action("gdcli: remove from group", UndoRedo.MERGE_DISABLE, node)
	manager.add_do_method(node, "remove_from_group", group)
	manager.add_undo_method(node, "add_to_group", group, true)
	manager.commit_action()
```

`undoable: false` → `true`；doc 同步。

- [ ] **Step 5: 更新 `test_signal_group_routes.py`**

- :18 `assert connect_result["undoable"] is False` → `is True`。
- :25 `assert group_add["undoable"] is False` → `is True`。
- 其余断言不变（保存重开仍可查询）。

- [ ] **Step 6: 验证并提交**

```bash
python scripts/format-gd.py && python scripts/format-gd.py --check
gdlint gdapi/addon/routes/node/signal/connect.gd gdapi/addon/routes/node/signal/disconnect.gd gdapi/addon/routes/node/group/add.gd gdapi/addon/routes/node/group/remove.gd
cargo test --workspace
uv run pytest tests/e2e/m2/test_signal_group_routes.py -v
```

Commit: `fix(node): signal/group mutations are undoable via EditorUndoRedoManager`.

---

## Task 10: 删除 policy 机制本体

**Files:**
- Delete: `gdapi/addon/runtime/capability_policy.gd`
- Delete: `tests/fixture_project/tests/test_capability_policy.gd`、`tests/fixtures/e2e_project/tests/test_capability_policy.gd`
- Delete: `tests/e2e/test_policy_restore.py`
- Delete: `tests/fixtures/e2e_project/.godot/gdapi-policy.json`（若存在；同时检查 `tests/fixture_project/.godot/gdapi-policy.json` 一并删除）
- Modify: `tests/e2e/test_gdscript_units.py`（移除 `test_capability_policy.gd` 条目）
- Modify: `tests/e2e/shared_fixture.py`（删 `E2E_DEFAULT_POLICY_PATH`、`temporary_policy`、`reset_shared_state` 中 policy restore 块）
- Modify: `tests/e2e/conftest.py`（删 `temporary_policy` import）
- Modify: `tests/e2e/test_shared_editor_lifecycle.py`（删 3 个 policy 测试与 `SAMPLE_POLICY`）
- Modify: `tests/e2e/test_unified_fixture_contract.py`（删 `DEFAULT_POLICY_BYTES` 与对应测试）

- [ ] **Step 1: 删除源码与单测**

删除 `capability_policy.gd`、两处 `test_capability_policy.gd`、`test_policy_restore.py`、policy fixture JSON。`test_gdscript_units.py` 列表移除：

```python
        "res://tests/test_capability_policy.gd",
```

- [ ] **Step 2: 清理 `shared_fixture.py`**

- 删除 `E2E_DEFAULT_POLICY_PATH` 常量（:44）与其注释。
- 删除 `temporary_policy` context manager（:379-400 附近整块）与 `import contextlib` 若不再使用。
- `reset_shared_state` 中删除 policy restore 块（:364-368）。

- [ ] **Step 3: 清理 `conftest.py` 与生命周期/契约测试**

- `conftest.py`：`from e2e.shared_fixture import (...)` 中删除 `temporary_policy`。
- `test_shared_editor_lifecycle.py`：删除 `SAMPLE_POLICY`（:29）与 `test_reset_shared_state_restores_default_policy`、`test_temporary_policy_overlays_and_restores`、`test_temporary_policy_restores_on_exception`、`test_temporary_policy_reports_restoration_failure` 四个测试（policy 相关全部删除；保留 reset/其它 lifecycle 测试）。
- `test_unified_fixture_contract.py`：删除 `DEFAULT_POLICY_BYTES`（:75-132 区域）与 `test_unified_fixture_carries_default_capability_policy`。

- [ ] **Step 4: 全局验证无残留**

```bash
git grep -n "capability_policy\|gdapi-policy\|temporary_policy\|require_force" -- gdapi tests | cat
```

Expected: 零匹配（`temporary_policy` 与 `require_force` 已随各自 task 清理）。

- [ ] **Step 5: 验证并提交**

```bash
python scripts/format-gd.py && python scripts/format-gd.py --check
cargo test --workspace
uv run pytest tests/e2e/test_gdscript_units.py tests/e2e/test_shared_editor_lifecycle.py tests/e2e/test_unified_fixture_contract.py -v
uv run pytest tests/e2e/m6/ -v
```

Commit: `chore(policy): remove capability policy subsystem entirely`.

---

## Task 11: 文档更新

**Files:**
- Modify: `README.md`（:259、:323-324、:337、:349-352、:365、:373、:384、:405 区域）
- Modify: `docs/gdcli/gdcli-manual.md`、`docs/gdcli/gdcli-exec.md`（grep `force|policy|capability` 后逐处更新）
- Modify: `docs/superpowers/specs/2026-07-30-single-editor-e2e-design.md`、`docs/superpowers/plans/2026-07-30-single-editor-e2e-plan.md`（temporary_policy/capability 引用标注为已废弃——或按历史文档保留并加注）
- Modify: `gdcli-full-capability-roadmap-design-2026-06-27.md`（追加需求变更记录）
- Delete（引用清理）: README 中对 `docs/security/high-risk-capabilities.md` 的引用（文件不存在）

- [ ] **Step 1: README 更新**

- :259 `scene/current/save`：`{path, force?}` → `{path?}`。
- :323-324 `script/write`：删除"需 force:true"；`script/patch`：`{path, start_line, end_line, text, force?}` → 去 force。
- :337 `filesystem/write`："写入文件（需 force:true）`{path, content, force?}`" → "写入文件 `{path, content}`"。
- :349-352 `resource/create`/`delete`/`move`：去 force 措辞。
- :365 M4 段落："覆盖已有目标必须显式传 force:true" → "覆盖已有文件直接生效（开发期工具，无 force 门禁），写入不可撤销"。
- :373 M5 段落："删除/修复/覆盖操作要求 force:true" → "删除/修复/覆盖为不可撤销写入"。
- :384 mutation 表："文件/资源操作 | ❌ undoable:false | 需 force:true" → "❌ undoable:false | 直接覆盖"。
- :405 M6 段落整段替换：

```markdown
M6 高风险能力（`editor/eval`、`runtime/eval`、`process/run`、`network/http_request`、
`filesystem/batch/delete`、`filesystem/batch/replace`、`filesystem/batch/recover`、
`export/android/deploy_many`）自 2026-08-01 起默认可用，不再需要
`.godot/gdapi-policy.json` 配置或 `force:true`（gdcli 为开发期工具，鉴权由
loopback + Bearer token 承担）。能力仍受内置硬上限约束：eval 源码 ≤16 KiB、
process 超时 ≤60s/输出 ≤1 MiB、network 仅 http(s)/超时 ≤60s/响应 ≤4 MiB/
重定向 ≤5、export 超时 ≤600s。所有危险操作保留审计日志（不含 secret）。
```

- [ ] **Step 2: docs/gdcli 更新**

对 `gdcli-manual.md` 与 `gdcli-exec.md` 执行 `grep -n "force\|policy\|capability"`，逐处：删除 force 参数说明、policy 配置说明，改为与 README 一致的新语义（有参 route 的 `force?` 标记删除）。

- [ ] **Step 3: 设计文档追加修订记录**

在 `gdcli-full-capability-roadmap-design-2026-06-27.md` 的"历史决策记录"末尾追加：

```markdown
### 2026-08-01 需求变更：移除 policy 与 force

用户决定 gdcli 仅面向开发期使用，取消"高风险能力默认关闭"方针：

- 删除 capability_policy 机制（`.godot/gdapi-policy.json`）与全部 `force:true` 要求。
- 高风险能力默认可用，受 service 内置硬上限约束（见 implementation plan
  `docs/superpowers/plans/2026-08-01-gdcli-policy-force-removal-and-gap-closure.md`）。
- 审计、标准错误码、mutation 模型（编辑器状态 mutation 应 undoable）等其余 contract 不变。
```

- [ ] **Step 4: 验证并提交**

```bash
git grep -n "force:true\|gdapi-policy\|需 .*force\|force 要求" -- README.md docs | cat
```

Expected: 仅剩设计文档中"历史快照"性质的历史引用（M3 历史段、设计原文），无"当前行为"描述残留。Commit: `docs: reflect policy/force removal and dev-tool posture`.

---

## Task 12: closure 报告

**Files:**
- Create: `docs/reports/2026-07-29-gdcli-m3-runtime-remediation-closure.md`
- Create: `docs/reports/2026-07-29-gdcli-m4-game-systems-closure.md`
- Create: `docs/reports/2026-07-30-gdcli-full-capability-roadmap-remediation-closure.md`
- Create: `docs/reports/2026-08-01-gdcli-policy-force-removal-and-gap-closure.md`

- [ ] **Step 1: 创建三份历史 milestone closure 报告**

每份包含：日期、范围、验收证据（对应测试套件与通过数——以本 plan Task 13 实测输出为准填写）、已知遗留。M3 报告引用 `docs/superpowers/plans/2026-07-29-gdcli-m3-runtime-remediation.md`（该 plan 文件缺失——报告中注明"plan 文档未入库，本报告以 2026-08-01 复核代码与测试为准"）。M4 报告说明 51 route 锁定与类型断言。M6 报告说明 8 route 门禁验收（并注明 2026-08-01 门禁已按新方针移除，历史验收记录保留）。

- [ ] **Step 2: 创建本 plan 的 closure 报告**

内容：需求变更摘要、缺口清单逐项 → 修复 commit、验收命令与结果（Task 13 实测）、设计文档修订记录、遗留项（如有）。

- [ ] **Step 3: 验证并提交**

```bash
git add docs/reports && git commit -m "docs: milestone closure reports (m3/m4/m6 + 2026-08-01 remediation)"
```

---

## Task 13: 最终验证

- [ ] **Step 1: GDScript 门禁与 Rust 门禁**

```bash
python scripts/format-gd.py --check
uv tool run gdtoolkit 2>/dev/null || uv tool install gdtoolkit
python scripts/format-gd.py && python scripts/format-gd.py --check
$gdFiles = @(git diff --name-only --diff-filter=ACMR | Where-Object { $_ -like '*.gd' })
if ($gdFiles.Count -gt 0) { gdlint $gdFiles }
cargo fmt --check
cargo clippy --workspace
cargo test --workspace
```

Expected: 全部 exit 0。

- [ ] **Step 2: 残留扫描**

```bash
git grep -n "require_force\|capability_policy\|gdapi-policy" -- gdapi tests README.md | cat
git grep -n '"force"' -- gdapi tests | cat
```

Expected: 零匹配（设计文档历史段落除外——单独验证）。

- [ ] **Step 3: E2E 全套**

```bash
cargo build --workspace
gdcli install --project tests/fixture_project --force
python scripts/setup-dev.py --no-build
uv run pytest tests/e2e/ -v
```

Expected: 全绿（预算测试按需排除）。`gdapi/routes` 与 `tests/e2e/route_manifests.py` 一致（M3=35、M4=51、M5=27、M6=8）。

- [ ] **Step 4: 修复任何残留并更新 Task 12 报告数据，提交**

```bash
git add -A && git commit -m "chore: final verification pass"
```

---

## Self-Review

**Spec coverage（需求变更 + review 缺口）:**

| 需求/缺口 | Task |
|---|---|
| 移除 policy 配置（全部 8 个 gate route + 机制本体） | 1-4、10 |
| 移除全部 force:true 要求（~30 个 route + service） | 1-8 |
| export/run 门禁（需求变更消解）+ 失败审计 + timeout 上限 | 8 |
| export/android/deploy 无门禁（消解）+ 无审计 | 8 |
| signal/group undoable:false 违反 mutation 模型 | 9 |
| script/write 审计记为 script/create | 5 |
| network 下载无界（body_size_limit） | 3 |
| runtime/eval 审计记为 eval | 1 |
| runtime_eval max_source_bytes 策略不生效（随 policy 移除消解，统一 16 KiB 常量） | 1 |
| tilemap/layer/clear 无审计 | 6 |
| theme 类型不精确 | 6 |
| M4 10 route doc() 不完整 | 6 |
| HTTP status 扁平化 400 | 5、6、7、8 |
| classdb/diagnostics HTTP 200 + ok:false | 7 |
| test_export_android.py skip | 8 |
| closure 报告缺失 | 12 |
| status.gd fallback 缺字段 / response.gd read_error / scene/current doc 漂移 | 7 |
| m2/m4/m5/m6 测试的 force/policy 断言 | 1-8 |
| README/docs 残留 force/policy 描述 | 11 |
| audio bus layout 无 force 覆盖保护（force 移除后自然消解，无需单独修复） | 6（消解） |

**Placeholder scan:** 无 TBD/TODO；`physics/body/create` 的 `type` 默认值标注"以 physics_editor.gd 为准"——执行时从服务实现抄录（唯一参数级不确定性，已显式标注）。

**Type consistency:** `execute(source, inputs)`、`validate(body)`、`authorize(url)`、`save_scene(path)`、`create_script(path, content, route)`、`write_script(path, content, route)`、`remove_bus(name)`、`clear(path)`、`bake(region_path, path)`、`reset(name)`、`remove_action(name)`、`unbind(name, event)`、`remove_autoload(name)`、`repair(body)` 在各 task 中签名一致；`runtime_route.dispatch` 的 `_complete`/`_reject` 新签名（多一个 `public_route` 参数）在 Task 1 定义后被 Task 1 内部所有调用点同步更新。
