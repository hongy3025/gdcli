"""Theme M4 route contracts: int coercion, reload readback and rejection.

`theme/constant/set` / `theme/font_size/set` used to reject the documented
`value: 4` / `value: 16` payloads: Godot's JSON parser decodes every JSON
number as float, so an `typeof(value) != TYPE_INT` check fails on `4.0`.
Integral floats must be accepted, non-integral and non-finite values rejected.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

from .helpers import exec_error, exec_ok


THEME_PATH = "res://themes/roundtrip.tres"
STYLEBOX_PATH = "res://themes/roundtrip_box.tres"


def _project_file(env: dict[str, Any], path: str) -> Path:
    return Path(env["project"]) / path.removeprefix("res://")


def test_theme_create_and_item_writes_round_trip_through_reload(m4_env):
    """Saving without a reloadable value (or a wrong value) must fail this test."""
    created = exec_ok(m4_env, "theme/create", {"path": THEME_PATH})
    assert created["saved"] is True
    assert created["undoable"] is False
    assert created["path"] == THEME_PATH
    assert _project_file(m4_env, THEME_PATH).is_file()

    stylebox = exec_ok(
        m4_env, "resource/create", {"path": STYLEBOX_PATH, "type": "StyleBoxFlat"}
    )
    assert stylebox["class"] == "StyleBoxFlat"

    writes = (
        (
            "theme/constant/set",
            {"path": THEME_PATH, "type": "Button", "item": "h_separation", "value": 4},
        ),
        (
            "theme/font_size/set",
            {"path": THEME_PATH, "type": "Button", "item": "font_size", "value": 16},
        ),
        (
            "theme/color/set",
            {
                "path": THEME_PATH,
                "type": "Button",
                "item": "font_color",
                "value": {"type": "Color", "value": [1.0, 0.0, 0.0, 1.0]},
            },
        ),
        (
            "theme/stylebox/set",
            {
                "path": THEME_PATH,
                "type": "Button",
                "item": "normal",
                "value": {"type": "Resource", "value": STYLEBOX_PATH},
            },
        ),
    )
    for route, body in writes:
        result = exec_ok(m4_env, route, body)
        assert result["changed"] is True, (route, result)
        assert result["saved"] is True, (route, result)
        assert result["undoable"] is False, (route, result)

    # Reload the saved .tres from disk and read every item back.
    properties = exec_ok(m4_env, "resource/info", {"path": THEME_PATH})["properties"]
    assert properties["Button/constants/h_separation"] == 4
    assert properties["Button/font_sizes/font_size"] == 16
    assert properties["Button/colors/font_color"] == {
        "type": "Color",
        "value": [1.0, 0.0, 0.0, 1.0],
    }
    assert properties["Button/styles/normal"] == {"type": "Resource", "value": STYLEBOX_PATH}
    assert exec_ok(m4_env, "resource/info", {"path": STYLEBOX_PATH})["class"] == "StyleBoxFlat"

    entries = exec_ok(m4_env, "gdapi/audit/list", {"since": 0, "limit": 100})["entries"]
    for route, _body in writes:
        assert any(
            entry["route"] == route
            and entry["ok"] is True
            and entry["summary"].get("path") == THEME_PATH
            for entry in entries
        ), (route, entries)


def test_theme_integer_items_accept_float_encoded_integers(m4_env):
    """Rejecting `4.0` breaks the documented examples; accepting `4.5` breaks ints."""
    path = "res://themes/integers.tres"
    exec_ok(m4_env, "theme/create", {"path": path})
    exec_ok(
        m4_env,
        "theme/constant/set",
        {"path": path, "type": "Button", "item": "h_separation", "value": 4},
    )
    exec_ok(
        m4_env,
        "theme/constant/set",
        {"path": path, "type": "Button", "item": "outline_size", "value": -4.0},
    )
    exec_ok(
        m4_env,
        "theme/font_size/set",
        {"path": path, "type": "Button", "item": "font_size", "value": 16.0},
    )

    properties = exec_ok(m4_env, "resource/info", {"path": path})["properties"]
    assert properties["Button/constants/h_separation"] == 4
    # Theme constants may be negative; no extra range restriction was requested.
    assert properties["Button/constants/outline_size"] == -4
    assert properties["Button/font_sizes/font_size"] == 16


def test_theme_rejects_non_integer_values_without_rewriting_file(m4_env):
    """A rejected write must return invalid_param and leave the .tres bytes intact."""
    path = "res://themes/reject.tres"
    exec_ok(m4_env, "theme/create", {"path": path})
    exec_ok(
        m4_env,
        "theme/constant/set",
        {"path": path, "type": "Button", "item": "h_separation", "value": 7},
    )
    target = _project_file(m4_env, path)
    before = target.read_bytes()

    cases = (
        (
            "theme/constant/set",
            {"path": path, "type": "Button", "item": "h_separation", "value": 4.5},
        ),
        (
            "theme/font_size/set",
            {"path": path, "type": "Button", "item": "font_size", "value": 4.5},
        ),
        (
            "theme/constant/set",
            {"path": path, "type": "Button", "item": "h_separation", "value": "4"},
        ),
        ("theme/constant/set", {"path": path, "type": "Button", "item": "h_separation"}),
    )
    for route, body in cases:
        error = exec_error(m4_env, route, body)
        assert error["code"] == "invalid_param", (route, body, error)
        assert "int" in error["error"], (route, body, error)
        assert target.read_bytes() == before, (route, body)

    properties = exec_ok(m4_env, "resource/info", {"path": path})["properties"]
    assert properties["Button/constants/h_separation"] == 7


def test_theme_rejects_non_finite_numbers_from_raw_request(m4_env):
    """`1e999` / `NaN` cannot pass gdcli's JSON validation, so post them raw.

    Godot's JSON parser turns `1e999` into `inf`, which must still be rejected
    as `invalid_param`; `NaN` is not valid JSON at all and is rejected before
    the route runs. Either way the theme file must stay untouched.
    """
    path = "res://themes/nonfinite.tres"
    exec_ok(m4_env, "theme/create", {"path": path})
    exec_ok(
        m4_env,
        "theme/constant/set",
        {"path": path, "type": "Button", "item": "h_separation", "value": 7},
    )
    target = _project_file(m4_env, path)
    before = target.read_bytes()

    for raw_value in ("1e999", "-1e999", "NaN"):
        status, payload = _raw_post(
            m4_env,
            "theme/constant/set",
            (
                '{"path":"%s","type":"Button","item":"h_separation","value":%s}'
                % (path, raw_value)
            ),
        )
        assert status == 400, (raw_value, status, payload)
        assert payload["code"] == "invalid_param", (raw_value, payload)
        assert target.read_bytes() == before, raw_value


def _raw_post(env: dict[str, Any], route: str, body: str) -> tuple[int, dict[str, Any]]:
    """POST a raw JSON body to the editor, bypassing gdcli's JSON validation."""
    meta = json.loads(
        (Path(env["project"]) / ".godot" / "gdapi.json").read_text(encoding="utf-8")
    )
    request = urllib.request.Request(
        "http://127.0.0.1:%d/%s" % (int(meta["http_port"]), route),
        data=body.encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": "Bearer " + str(meta.get("token", "")),
        },
        method="POST",
    )
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(request, timeout=30) as response:
            return response.status, json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        return error.code, json.loads(error.read().decode("utf-8"))
