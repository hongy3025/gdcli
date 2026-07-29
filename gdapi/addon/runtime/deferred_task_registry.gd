@tool
## Owns deferred route work whose HTTP response outlives RouteHandler.handle().
##
## A registration retains its response and supplies `tick(now_ms) -> bool` plus
## `cancel(reason)`.  Successful ticks must send their response before returning
## true.  The registry supplies the only failure response for timeout/shutdown.
extends RefCounted

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")

var _tasks: Array[Dictionary] = []


func register(task: Dictionary) -> bool:
	if not _is_valid_task(task):
		return false
	_tasks.append(task)
	return true


func tick(now_ms: int) -> void:
	for index in range(_tasks.size() - 1, -1, -1):
		var task: Dictionary = _tasks[index]
		if _has_timed_out(task, now_ms):
			_fail_and_remove(index, "timeout", ErrorCodes.TIMEOUT, "deferred task timed out")
			continue
		var finished: Variant = task["tick"].call(now_ms)
		if bool(finished):
			if not _response_is_sent(task["response"]):
				_fail_task(
					task, ErrorCodes.GODOT_ERROR, "deferred task completed without a response"
				)
			_tasks.remove_at(index)
		elif _response_is_sent(task["response"]):
			# A task may send its terminal response and report completion on the next
			# poll.  Do not retain it long enough to permit another response.
			_tasks.remove_at(index)


func cancel_all(reason: String) -> void:
	for index in range(_tasks.size() - 1, -1, -1):
		_fail_and_remove(index, reason, ErrorCodes.CONFLICT, "deferred task cancelled: %s" % reason)


func pending_count() -> int:
	return _tasks.size()


func _is_valid_task(task: Dictionary) -> bool:
	if not task.has("response") or task["response"] == null:
		return false
	if not task.has("tick") or typeof(task["tick"]) != TYPE_CALLABLE:
		return false
	if not task.has("cancel") or typeof(task["cancel"]) != TYPE_CALLABLE:
		return false
	if not task.has("deadline_ms") or typeof(task["deadline_ms"]) != TYPE_INT:
		return false
	return int(task["deadline_ms"]) >= 0


func _has_timed_out(task: Dictionary, now_ms: int) -> bool:
	var deadline_ms: int = task["deadline_ms"]
	return deadline_ms > 0 and now_ms >= deadline_ms


func _fail_and_remove(index: int, reason: String, code: String, message: String) -> void:
	var task: Dictionary = _tasks[index]
	var cancel: Callable = task["cancel"]
	cancel.call(reason)
	_fail_task(task, code, message)
	_tasks.remove_at(index)


func _fail_task(task: Dictionary, code: String, message: String) -> void:
	var response = task["response"]
	if _response_is_sent(response):
		return
	if response.has_method("error"):
		response.error(message, code, ErrorCodes.http_status(code))


func _response_is_sent(response: Variant) -> bool:
	return response != null and response.has_method("is_sent") and bool(response.is_sent())
