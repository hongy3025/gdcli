# gdlint: ignore=max-returns
@tool
extends RefCounted

const CaptureOps := preload("res://addons/gdapi/runtime/runtime_capture_ops.gd")
const PathGuard := preload("res://addons/gdapi/runtime/path_guard.gd")
const MAX_PNG_BYTES := 3 * 1024 * 1024


static func compare(payload: Dictionary) -> Dictionary:
	var validated := CaptureOps.validate_viewport_payload(payload)
	if not validated.get("ok", false):
		return validated
	var deadline := Time.get_ticks_msec() + int(validated.timeout_ms)
	var threshold: Variant = payload.get("threshold", 0.0)
	var allowed_ratio: Variant = payload.get("max_diff_ratio", 0.0)
	if not _unit_number(threshold) or not _unit_number(allowed_ratio):
		return _fail("invalid_param", "threshold and max_diff_ratio must be finite 0..1 numbers")
	var expected := _image(payload.get("expected", null))
	if not expected.get("ok", false):
		return expected
	var actual: Dictionary
	if payload.has("actual"):
		actual = _image(payload.actual)
	else:
		var capture := await CaptureOps.viewport(
			{"timeout_ms": maxi(1, deadline - Time.get_ticks_msec())}
		)
		if not capture.get("ok", false):
			return capture
		actual = _image(capture.result)
	if not actual.get("ok", false):
		return actual
	if Time.get_ticks_msec() >= deadline:
		return _fail("timeout", "image comparison timed out during decode")
	var left: Image = expected.image
	var right: Image = actual.image
	if left.get_size() != right.get_size():
		return {
			"ok": true,
			"result":
			{
				"matches": false,
				"dimensions_match": false,
				"expected_size": [left.get_width(), left.get_height()],
				"actual_size": [right.get_width(), right.get_height()],
				"diff_ratio": null,
				"diff_pixels": null,
				"max_error": null,
				"mean_squared_error": null,
				"diff_bbox": null
			}
		}
	left.convert(Image.FORMAT_RGBA8)
	right.convert(Image.FORMAT_RGBA8)
	var width := left.get_width()
	var height := left.get_height()
	var a := left.get_data()
	var b := right.get_data()
	var changed := 0
	var max_error := 0.0
	var squared := 0.0
	var min_x := width
	var min_y := height
	var max_x := -1
	var max_y := -1
	for y in height:
		if Time.get_ticks_msec() >= deadline:
			return _fail("timeout", "image comparison timed out")
		for x in width:
			var offset := (y * width + x) * 4
			var pixel_error := 0.0
			for channel in 4:
				var error := absf(float(a[offset + channel]) - float(b[offset + channel])) / 255.0
				pixel_error = maxf(pixel_error, error)
				squared += error * error
			max_error = maxf(max_error, pixel_error)
			if pixel_error > float(threshold):
				changed += 1
				min_x = mini(min_x, x)
				min_y = mini(min_y, y)
				max_x = maxi(max_x, x)
				max_y = maxi(max_y, y)
	var ratio := float(changed) / float(width * height)
	return {
		"ok": true,
		"result":
		{
			"matches": ratio <= float(allowed_ratio),
			"dimensions_match": true,
			"width": width,
			"height": height,
			"diff_pixels": changed,
			"diff_ratio": ratio,
			"max_error": max_error,
			"mean_squared_error": squared / float(width * height * 4),
			"threshold": threshold,
			"max_diff_ratio": allowed_ratio,
			"diff_bbox":
			(
				{"x": min_x, "y": min_y, "width": max_x - min_x + 1, "height": max_y - min_y + 1}
				if changed > 0
				else null
			)
		}
	}


static func _image(source: Variant) -> Dictionary:
	if typeof(source) != TYPE_DICTIONARY:
		return _fail("invalid_param", "PNG source requires {path} or {data_base64}")
	var bytes: PackedByteArray
	if source.has("path"):
		if typeof(source.path) != TYPE_STRING:
			return _fail("invalid_param", "PNG path must be a string")
		var guarded := PathGuard.validate(String(source.path), "read")
		if not guarded.get("ok", false):
			return guarded
		var file := FileAccess.open(guarded.path, FileAccess.READ)
		if file == null:
			return _fail("not_found", "PNG file not found")
		if file.get_length() > MAX_PNG_BYTES:
			return _fail("invalid_param", "PNG exceeds 3 MiB limit")
		bytes = file.get_buffer(file.get_length())
	elif source.has("data_base64") and typeof(source.data_base64) == TYPE_STRING:
		if String(source.data_base64).length() > MAX_PNG_BYTES * 4 / 3 + 4:
			return _fail("invalid_param", "PNG base64 exceeds allocation limit")
		bytes = Marshalls.base64_to_raw(source.data_base64)
	else:
		return _fail("invalid_param", "PNG source requires path or data_base64")
	if bytes.size() < 33 or bytes.size() > MAX_PNG_BYTES:
		return _fail("invalid_param", "invalid PNG byte size")
	var signature := PackedByteArray([137, 80, 78, 71, 13, 10, 26, 10])
	for index in 8:
		if bytes[index] != signature[index]:
			return _fail("invalid_param", "image must be PNG")
	if bytes.slice(12, 16).get_string_from_ascii() != "IHDR":
		return _fail("invalid_param", "PNG IHDR is missing")
	var width := _big_endian(bytes, 16)
	var height := _big_endian(bytes, 20)
	if width < 1 or height < 1 or width > CaptureOps.MAX_WIDTH or height > CaptureOps.MAX_HEIGHT:
		return _fail("invalid_param", "PNG dimensions exceed 1920x1080 allocation limit")
	var image := Image.new()
	if image.load_png_from_buffer(bytes) != OK or image.is_empty():
		return _fail("invalid_param", "PNG decoding failed")
	return {"ok": true, "image": image}


static func _big_endian(bytes: PackedByteArray, offset: int) -> int:
	return (
		(int(bytes[offset]) << 24)
		| (int(bytes[offset + 1]) << 16)
		| (int(bytes[offset + 2]) << 8)
		| int(bytes[offset + 3])
	)


static func _unit_number(value: Variant) -> bool:
	return (
		(typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT)
		and is_finite(float(value))
		and value >= 0
		and value <= 1
	)


static func _fail(code: String, error: String) -> Dictionary:
	return {"ok": false, "code": code, "error": error}
