"""Milestone-owned public route manifests.

Keep post-milestone additions explicit so a later route cannot silently change
an earlier milestone's contract.
"""


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

