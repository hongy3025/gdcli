"""T8 disk property transactions, actual PNG pixels and Theme read contracts."""
from __future__ import annotations

import base64
import os
import stat
import struct
import zlib
from pathlib import Path

import pytest

from .helpers import exec_error, exec_ok


def _file(env, path):
    return Path(env["project"]) / path.removeprefix("res://")


def _write_fixture(env, path, contents):
    target = _file(env, path)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(contents, encoding="utf-8")
    return target


def test_resource_typed_property_disk_roundtrip_and_rejected_writes(m4_env):
    path = "res://resources/property_roundtrip.tres"
    exec_ok(m4_env, "resource/create", {"path": path, "type": "StyleBoxFlat"})
    color = {"type": "Color", "value": [0.25, 0.5, 0.75, 1.0]}
    result = exec_ok(m4_env, "resource/set", {"path": path, "property": "bg_color", "value": color})
    assert result["saved"] is True and result["undoable"] is False
    read = exec_ok(m4_env, "resource/get", {"path": path, "property": "bg_color"})
    assert read["value"] == color
    assert read["type"] == "Color" and read["writable"] is True
    exec_ok(m4_env, "resource/set", {"path": path, "property": "corner_radius_top_left", "value": 7.0})
    assert exec_ok(m4_env, "resource/get", {"path": path, "property": "corner_radius_top_left"})["value"] == 7
    target = _file(m4_env, path)
    before = target.read_bytes()
    for property_name, value, code in [
        ("bg_color", "not a color", "invalid_param"),
        ("corner_radius_top_left", 2.5, "invalid_param"),
        ("script", None, "permission_denied"),
        ("resource_path", "res://elsewhere.tres", "permission_denied"),
        ("missing_property", 1, "not_found"),
    ]:
        exec_error(m4_env, "resource/set", {"path": path, "property": property_name, "value": value}, code)
        assert target.read_bytes() == before
    exec_error(m4_env, "resource/get", {"path": path, "property": "missing_property"}, "not_found")
    exec_error(m4_env, "resource/set", {"path": "res://addons/gdapi/resources/blocked.tres", "property": "resource_name", "value": "x"}, "permission_denied")


def test_resource_readonly_file_does_not_report_saved_or_mutate_cache(m4_env):
    path = "res://resources/readonly_property.tres"
    exec_ok(m4_env, "resource/create", {"path": path, "type": "StyleBoxFlat"})
    old = exec_ok(m4_env, "resource/info", {"path": path})["properties"]["bg_color"]
    target = _file(m4_env, path)
    before = target.read_bytes()
    mode = target.stat().st_mode
    try:
        target.chmod(stat.S_IREAD)
        if os.name != "nt" and os.geteuid() == 0:
            pytest.skip("root can bypass POSIX read-only permissions; Windows smoke covers this contract")
        exec_error(m4_env, "resource/set", {"path": path, "property": "bg_color", "value": {"type": "Color", "value": [1, 0, 0, 1]}}, "permission_denied")
        assert target.read_bytes() == before
        # resource/info uses the editor cache: also catch in-memory-only corruption.
        assert exec_ok(m4_env, "resource/info", {"path": path})["properties"]["bg_color"] == old
    finally:
        target.chmod(mode | stat.S_IWRITE)


def _png_pixels(encoded):
    """Decode actual 8-bit RGB/RGBA PNG scanlines, including all five filters."""
    png = base64.b64decode(encoded, validate=True)
    assert png[:8] == b"\x89PNG\r\n\x1a\n"
    pos = 8
    compressed = bytearray()
    while pos < len(png):
        length = struct.unpack_from(">I", png, pos)[0]
        tag = png[pos + 4:pos + 8]
        payload = png[pos + 8:pos + 8 + length]
        if tag == b"IHDR":
            width, height, depth, color, _, _, interlace = struct.unpack(">IIBBBBB", payload)
            assert depth == 8 and color in (2, 6) and interlace == 0
        elif tag == b"IDAT":
            compressed.extend(payload)
        pos += length + 12
    channels = 3 if color == 2 else 4
    stride = width * channels
    raw = zlib.decompress(compressed)
    assert len(raw) == height * (stride + 1)
    rows = []
    previous = bytearray(stride)
    for y in range(height):
        offset = y * (stride + 1)
        filter_type = raw[offset]
        row = bytearray(raw[offset + 1:offset + 1 + stride])
        assert filter_type in range(5)
        for x in range(stride):
            left = row[x - channels] if x >= channels else 0
            up = previous[x]
            upper_left = previous[x - channels] if x >= channels else 0
            if filter_type == 1:
                predictor = left
            elif filter_type == 2:
                predictor = up
            elif filter_type == 3:
                predictor = (left + up) // 2
            elif filter_type == 4:
                p = left + up - upper_left
                distances = [abs(p - left), abs(p - up), abs(p - upper_left)]
                predictor = [left, up, upper_left][distances.index(min(distances))]
            else:
                predictor = 0
            row[x] = (row[x] + predictor) & 255
        rows.extend(tuple(row[x:x + channels]) for x in range(0, stride, channels))
        previous = row
    return width, height, rows


def test_texture_preview_resizes_real_pixels_and_common_resource_preview(m4_env):
    path = "res://resources/red_texture.tres"
    _write_fixture(m4_env, path, '''[gd_resource type="GradientTexture2D" load_steps=2 format=3]

[sub_resource type="Gradient" id="Gradient_red"]
colors = PackedColorArray(1, 0, 0, 1, 1, 0, 0, 1)

[resource]
gradient = SubResource("Gradient_red")
width = 2
height = 3
''')
    vector = {"type": "Vector2", "value": [0.25, 0.5]}
    exec_ok(m4_env, "resource/set", {"path": path, "property": "fill_from", "value": vector})
    assert exec_ok(m4_env, "resource/get", {"path": path, "property": "fill_from"})["value"] == vector
    result = exec_ok(m4_env, "resource/preview", {"path": path, "width": 6, "height": 4})
    assert (result["width"], result["height"]) == (6, 4)
    assert (result["original_width"], result["original_height"]) == (2, 3)
    assert result["source"] == "texture"
    width, height, pixels = _png_pixels(result["png_base64"])
    assert (width, height) == (6, 4)
    assert all(pixel[:3] == (255, 0, 0) and (len(pixel) == 3 or pixel[3] == 255) for pixel in pixels)
    proportional = exec_ok(m4_env, "resource/preview", {"path": path, "width": 4})
    assert (proportional["width"], proportional["height"]) == (4, 6)
    gradient = "res://resources/preview_gradient.tres"
    _write_fixture(m4_env, gradient, '''[gd_resource type="Gradient" format=3]

[resource]
colors = PackedColorArray(1, 0, 0, 1, 1, 0, 0, 1)
''')
    common = exec_ok(m4_env, "resource/preview", {"path": gradient, "width": 8, "height": 8, "deadline_ms": 5000})
    assert common["source"] == "editor_resource_preview"
    width, height, pixels = _png_pixels(common["png_base64"])
    assert (width, height) == (8, 8)
    assert any(pixel[:3] == (255, 0, 0) for pixel in pixels)
    exec_error(m4_env, "resource/preview", {"path": path, "width": -1}, "invalid_param")
    exec_error(m4_env, "resource/preview", {"path": "res://resources/no_texture.tres"}, "not_found")
    exec_error(m4_env, "resource/preview", {"path": path, "deadline_ms": 0}, "invalid_param")
    plain = "res://resources/no_preview.tres"
    exec_ok(m4_env, "resource/create", {"path": plain, "type": "Resource"})
    exec_error(m4_env, "resource/preview", {"path": plain}, "not_supported")


def test_theme_get_all_writable_domains_font_items_and_inheritance(m4_env):
    theme = "res://themes/t8_reads.tres"
    box = "res://themes/t8_box.tres"
    font = "res://themes/t8_font.tres"
    _write_fixture(m4_env, theme, '''[gd_resource type="Theme" format=3]

[resource]
FancyButton/base_type = &"Control"
''')
    # Prime the editor cache before detached Theme writes; resource/set must
    # refresh disk state rather than overwrite those later writes with stale data.
    exec_ok(m4_env, "resource/info", {"path": theme})
    exec_ok(m4_env, "resource/create", {"path": box, "type": "StyleBoxFlat"})
    exec_ok(m4_env, "resource/create", {"path": font, "type": "SystemFont"})
    values = {
        "color": ("font_color", {"type": "Color", "value": [1, 0, 0, 1]}),
        "constant": ("h_separation", -4.0),
        "font_size": ("font_size", 19.0),
        "stylebox": ("normal", {"type": "Resource", "value": box}),
        "font": ("font", {"type": "Resource", "value": font}),
    }
    for kind, (item, value) in values.items():
        exec_ok(m4_env, f"theme/{kind}/set", {"path": theme, "type": "Button", "item": item, "value": value})
        read = exec_ok(m4_env, f"theme/{kind}/get", {"path": theme, "type": "Button", "item": item})
        assert read["has"] is True and read["local_has"] is True and read["inherited"] is False
        assert read["value"] == value
        assert read["resolved_type"] == "Button"
    entries = exec_ok(m4_env, "theme/items", {"path": theme, "type": "Button"})["items"]
    assert {(entry["data_type"], entry["item"]) for entry in entries} == {(kind, item) for kind, (item, _) in values.items()}
    for entry in entries:
        assert entry["value"] == values[entry["data_type"]][1]
    fonts = exec_ok(m4_env, "theme/items", {"path": theme, "data_type": "font"})["items"]
    assert fonts == [{"data_type": "font", "type": "Button", "item": "font", "value": {"type": "Resource", "value": font}, "has": True, "inherited": False}]
    exec_ok(m4_env, "theme/constant/set", {"path": theme, "type": "Control", "item": "base_constant", "value": 5})
    inherited = exec_ok(m4_env, "theme/constant/get", {"path": theme, "type": "Button", "item": "base_constant"})
    assert inherited["value"] == 5 and inherited["has"] is True
    assert inherited["inherited"] is True and inherited["local_has"] is False
    assert inherited["resolved_type"] == "Control"
    # Theme's actual variation property survives save/reload as a StringName.
    exec_ok(m4_env, "resource/set", {"path": theme, "property": "FancyButton/base_type", "value": "Button"})
    variation = exec_ok(m4_env, "theme/font/get", {"path": theme, "type": "FancyButton", "item": "font"})
    assert variation["has"] is True and variation["inherited"] is True
    assert variation["resolved_type"] == "Button" and variation["value"] == values["font"][1]
    for kind in values:
        missing = exec_ok(m4_env, f"theme/{kind}/get", {"path": theme, "type": "Button", "item": "no_such_item"})
        assert missing["has"] is False and missing["inherited"] is False
        assert missing["value"] is None and missing["resolved_type"] == ""
    exec_error(m4_env, "theme/items", {"path": theme, "data_type": "bad_type"}, "invalid_param")
    exec_error(m4_env, "theme/font/set", {"path": theme, "type": "Button", "item": "font", "value": {"type": "Resource", "value": box}}, "invalid_param")
    exec_error(m4_env, "theme/font/get", {"path": box, "type": "Button", "item": "font"}, "invalid_param")
