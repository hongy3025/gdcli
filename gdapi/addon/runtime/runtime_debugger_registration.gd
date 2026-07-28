## Testable registration pair for the native EditorDebuggerPlugin instance.

@tool
class_name GdApiRuntimeDebuggerRegistration
extends RefCounted

var _plugin: Object = null
var _add: Callable = Callable()
var _remove: Callable = Callable()
var registered: bool = false

func setup(plugin: Object, add: Callable, remove: Callable) -> void:
	_plugin = plugin
	_add = add
	_remove = remove

func register() -> void:
	if registered or _plugin == null or not _add.is_valid():
		return
	_add.call(_plugin)
	registered = true

func unregister() -> void:
	if not registered:
		return
	if _remove.is_valid():
		_remove.call(_plugin)
	registered = false
