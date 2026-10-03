"""Milestone-owned public route manifests.

Keep post-milestone additions explicit so a later route cannot silently change
an earlier milestone's contract.
"""

M3_RUNTIME_ROUTES = {
    "runtime/status", "runtime/scene/tree",
    *{f"runtime/node/{name}" for name in (
        "info", "get", "set", "call", "find", "remove", "reparent",
        "create", "duplicate", "rename",
    )},
    *{f"runtime/input/{name}" for name in (
        "key", "mouse", "gamepad", "touch", "action", "sequence",
    )},
    *{f"runtime/screenshot/{name}" for name in ("viewport", "camera", "frames")},
    *{f"runtime/log/{name}" for name in ("read", "clear")},
    *{f"runtime/assert/{name}" for name in (
        "condition", "node_exists", "property_equals", "signal_received",
    )},
    *{f"runtime/signal/{name}" for name in ("connect", "disconnect", "emit", "await")},
    *{f"runtime/debug/{name}" for name in (
        "performance", "monitors", "errors", "breakpoints",
    )},
}

M4_ROUTES = {
    "animation/create", "animation/delete", "animation/play", "animation/stop",
    "animation/track/add", "animation/track/remove", "animation/key/add", "animation/key/remove",
    "animation_tree/state/add", "animation_tree/transition/add", "animation_tree/blend/set",
    "tilemap/info", "tilemap/cell/get", "tilemap/cell/set", "tilemap/rect/fill", "tilemap/layer/clear", "tilemap/used_cells",
    "material/create", "material/info", "material/set", "material/assign", "material/duplicate", "material/save",
    "shader/read", "shader/write", "shader/uniforms", "shader/material/create", "shader/param/set",
    "audio/bus/list", "audio/bus/add", "audio/bus/remove", "audio/player/create", "audio/play", "audio/stop",
    "ui/control/set_anchor", "ui/text/set", "ui/layout/build",
    "theme/create", "theme/color/set", "theme/constant/set", "theme/font_size/set", "theme/stylebox/set",
    "physics/body/create", "physics/shape/create", "physics/layer/set", "physics/raycast", "physics/joint/create",
    "navigation/region/list", "navigation/mesh/bake", "navigation/path/get", "navigation/agent/target",
}

M5_ROUTES = {
    "project/settings/get", "project/settings/set", "project/settings/list", "project/settings/reset",
    "project/input_map/list", "project/input_map/action/add", "project/input_map/action/remove",
    "project/input_map/bind", "project/input_map/unbind", "project/autoload/list",
    "project/autoload/add", "project/autoload/remove", "classdb/classes", "classdb/class",
    "classdb/methods", "classdb/properties", "classdb/signals", "classdb/inheriters", "uid/repair",
    "diagnostics/health", "diagnostics/unused_resources", "diagnostics/cycle_deps", "diagnostics/script_errors",
    "export/presets", "export/run",
}

M6_ROUTES = {
    "editor/eval", "runtime/eval", "process/run", "network/http_request",
    "filesystem/batch/delete", "filesystem/batch/replace", "filesystem/batch/recover",
}

assert len(M3_RUNTIME_ROUTES) == 35
assert len(M4_ROUTES) == 51
assert len(M5_ROUTES) == 25
assert len(M6_ROUTES) == 7
