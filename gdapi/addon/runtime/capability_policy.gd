@tool
## Fail-closed authorization for capabilities that can affect the host or project broadly.
##
## The policy is deliberately loaded only from the project's generated-data directory;
## callers cannot select another file through route data.
extends RefCounted

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")

const POLICY_PATH := "res://.godot/gdapi-policy.json"
const CAPABILITIES := [
	"editor_eval",
	"runtime_eval",
	"process",
	"network",
	"bulk_files",
	"bulk_deploy",
]

const CAPABILITY_FIELDS := {
	"editor_eval": ["enabled", "max_source_bytes", "allowed_input_keys"],
	"runtime_eval": ["enabled", "max_source_bytes", "allowed_input_keys"],
	"process": [
		"enabled", "executables", "cwd_roots", "max_timeout_ms", "max_output_bytes",
	],
	"network": [
		"enabled",
		"schemes",
		"hosts",
		"ports",
		"allow_private",
		"max_timeout_ms",
		"max_response_bytes",
	],
	"bulk_files": ["enabled"],
	"bulk_deploy": ["enabled"],
}

const MAX_PROCESS_TIMEOUT_MS := 60_000
const MAX_PROCESS_OUTPUT_BYTES := 1_048_576
const MAX_NETWORK_RESPONSE_BYTES := 4_194_304

var _path: String = ""
var _last_modified_time: int = -1
var _loaded: bool = false
var _valid: bool = false
var _policy: Dictionary = {}


func _init(path: String = POLICY_PATH) -> void:
	# Do not make the policy location caller-configurable.  The optional argument is
	# useful only for making an attempted alternate path testable as a denial.
	if path == POLICY_PATH:
		_path = path


func authorize(capability: String, _route: String, body: Dictionary) -> Dictionary:
	_reload_if_changed()
	if not _valid:
		return _denied(capability)
	if not CAPABILITIES.has(capability):
		return _denied(capability)
	var capabilities: Dictionary = _policy["capabilities"]
	var capability_policy: Dictionary = capabilities.get(capability, {})
	if not bool(capability_policy.get("enabled", false)):
		return _denied(capability)
	if typeof(body.get("force", false)) != TYPE_BOOL or not bool(body.get("force", false)):
		return {
			"ok": false,
			"code": ErrorCodes.UNSAFE_OPERATION,
			"error": "%s requires force:true" % capability,
		}
	return {"ok": true, "capability": capability}


func settings(capability: String) -> Dictionary:
	_reload_if_changed()
	if not _valid or not CAPABILITIES.has(capability):
		return {}
	var value: Variant = Dictionary(_policy.get("capabilities", {})).get(capability, {})
	return value.duplicate(true) if typeof(value) == TYPE_DICTIONARY else {}


func _reload_if_changed() -> void:
	if _path.is_empty():
		_valid = false
		_policy = {}
		return
	var modified_time := FileAccess.get_modified_time(_path)
	if _loaded and modified_time == _last_modified_time:
		return
	_loaded = true
	_last_modified_time = modified_time
	_valid = false
	_policy = {}
	if modified_time == 0:
		return
	var file := FileAccess.open(_path, FileAccess.READ)
	if file == null:
		return
	var source := file.get_as_text()
	file.close()
	var json := JSON.new()
	if json.parse(source) != OK or typeof(json.data) != TYPE_DICTIONARY:
		return
	var parsed: Dictionary = json.data
	if not _is_valid_policy(parsed):
		return
	_policy = parsed
	_valid = true


func _is_valid_policy(policy: Dictionary) -> bool:
	if not _has_exact_keys(policy, ["version", "capabilities"]):
		return false
	if not _is_json_integer(policy.get("version")) or int(policy["version"]) != 1:
		return false
	if typeof(policy.get("capabilities")) != TYPE_DICTIONARY:
		return false
	var capabilities: Dictionary = policy["capabilities"]
	for capability_name in capabilities:
		if typeof(capability_name) != TYPE_STRING or not CAPABILITIES.has(capability_name):
			return false
		if typeof(capabilities[capability_name]) != TYPE_DICTIONARY:
			return false
		if not _is_valid_capability(capability_name, capabilities[capability_name]):
			return false
	return true


func _is_valid_capability(name: String, capability: Dictionary) -> bool:
	var allowed_fields: Array = CAPABILITY_FIELDS[name]
	if not capability.has("enabled") or typeof(capability["enabled"]) != TYPE_BOOL:
		return false
	for field in capability:
		if typeof(field) != TYPE_STRING or not allowed_fields.has(field):
			return false
		var value: Variant = capability[field]
		match field:
			"max_source_bytes", "max_timeout_ms", "max_output_bytes", "max_response_bytes":
				if not _is_valid_limit(field, value):
					return false
			"executables", "cwd_roots", "allowed_input_keys", "schemes", "hosts":
				if not _is_string_array(value):
					return false
			"ports":
				if not _is_valid_ports(value):
					return false
			"allow_private":
				if typeof(value) != TYPE_BOOL:
					return false
	return true


func _is_valid_limit(field: String, value: Variant) -> bool:
	if not _is_json_integer(value) or int(value) < 0:
		return false
	match field:
		"max_timeout_ms":
			return int(value) <= MAX_PROCESS_TIMEOUT_MS
		"max_output_bytes":
			return int(value) <= MAX_PROCESS_OUTPUT_BYTES
		"max_response_bytes":
			return int(value) <= MAX_NETWORK_RESPONSE_BYTES
	return true


func _is_string_array(value: Variant) -> bool:
	if typeof(value) != TYPE_ARRAY:
		return false
	for item in value:
		if typeof(item) != TYPE_STRING:
			return false
	return true


func _is_valid_ports(value: Variant) -> bool:
	if typeof(value) != TYPE_ARRAY:
		return false
	for port in value:
		if not _is_json_integer(port) or int(port) < 1 or int(port) > 65_535:
			return false
	return true


func _is_json_integer(value: Variant) -> bool:
	if typeof(value) == TYPE_INT:
		return true
	if typeof(value) != TYPE_FLOAT:
		return false
	var number: float = value
	return is_finite(number) and number == floor(number)


func _has_exact_keys(value: Dictionary, expected_keys: Array) -> bool:
	if value.size() != expected_keys.size():
		return false
	for key in value:
		if typeof(key) != TYPE_STRING or not expected_keys.has(key):
			return false
	return true


func _denied(capability: String) -> Dictionary:
	return {
		"ok": false,
		"code": ErrorCodes.PERMISSION_DENIED,
		"error": "capability is not permitted: %s" % capability,
	}
