@tool
extends SceneTree

const DeferredTaskRegistry := preload("res://addons/gdapi/runtime/deferred_task_registry.gd")

var passed := 0
var failed := 0


func _init() -> void:
	test_tick_removes_completed_task_after_one_response()
	test_timeout_cancels_and_sends_one_terminal_error()
	test_cancel_all_cleans_up_every_pending_task_once()
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed > 0 else 0)


func test_tick_removes_completed_task_after_one_response() -> void:
	var registry := DeferredTaskRegistry.new()
	var task := FakeTask.new(200, true)
	assert_true(registry.register(task.as_registration()), "task is registered")
	registry.tick(100)
	assert_eq(task.response.sent_count, 1, "completed task sends one response")
	assert_eq(registry.pending_count(), 0, "completed task is removed")
	registry.tick(101)
	assert_eq(task.response.sent_count, 1, "completed task cannot respond twice")


func test_timeout_cancels_and_sends_one_terminal_error() -> void:
	var registry := DeferredTaskRegistry.new()
	var task := FakeTask.new(50, false)
	registry.register(task.as_registration())
	registry.tick(50)
	assert_eq(task.cancel_reasons, ["timeout"], "timeout invokes task cleanup")
	assert_eq(task.response.error_codes, ["timeout"], "timeout is terminal error")
	assert_eq(registry.pending_count(), 0, "timed out task is removed")
	registry.cancel_all("plugin exiting")
	assert_eq(task.response.sent_count, 1, "timeout remains the only terminal response")


func test_cancel_all_cleans_up_every_pending_task_once() -> void:
	var registry := DeferredTaskRegistry.new()
	var first := FakeTask.new(1000, false)
	var second := FakeTask.new(1000, false)
	registry.register(first.as_registration())
	registry.register(second.as_registration())
	registry.cancel_all("plugin exiting")
	assert_eq(first.cancel_reasons, ["plugin exiting"], "first task is cancelled")
	assert_eq(second.cancel_reasons, ["plugin exiting"], "second task is cancelled")
	assert_eq(first.response.error_codes, ["conflict"], "shutdown uses conflict response")
	assert_eq(second.response.error_codes, ["conflict"], "shutdown uses conflict response")
	assert_eq(registry.pending_count(), 0, "shutdown clears registry")


class FakeResponse:
	extends RefCounted
	var sent_count := 0
	var error_codes: Array = []

	func is_sent() -> bool:
		return sent_count > 0

	func json(_body: Dictionary) -> void:
		if not is_sent():
			sent_count += 1

	func error(_message: String, code: String, _status: int) -> void:
		if not is_sent():
			sent_count += 1
			error_codes.append(code)


class FakeTask:
	extends RefCounted
	var response := FakeResponse.new()
	var deadline_ms: int
	var completes_on_tick: bool
	var cancel_reasons: Array = []

	func _init(deadline: int, should_complete: bool) -> void:
		deadline_ms = deadline
		completes_on_tick = should_complete

	func as_registration() -> Dictionary:
		return {
			"response": response,
			"deadline_ms": deadline_ms,
			"tick": tick,
			"cancel": cancel,
		}

	func tick(_now_ms: int) -> bool:
		if completes_on_tick:
			response.json({"ok": true})
			return true
		return false

	func cancel(reason: String) -> void:
		cancel_reasons.append(reason)


func assert_true(value: bool, context: String) -> void:
	assert_eq(value, true, context)


func assert_eq(actual, expected, context: String) -> void:
	if actual == expected:
		passed += 1
	else:
		failed += 1
		print("FAIL: %s expected=%s actual=%s" % [context, expected, actual])
