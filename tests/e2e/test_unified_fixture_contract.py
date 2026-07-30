"""Contract assertions for the unified E2E fixture root.

This test does not start a Godot editor; it checks the checked-in fixture tree
and the configured plugins. It fails when the merged root is missing required
paths, when the same destination resolves from two different sources, or when
the gdapi test plugin is not enabled.
"""

from __future__ import annotations

import re
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
E2E_PROJECT = REPO_ROOT / "tests" / "fixtures" / "e2e_project"
E2E_PROJECT_GODOT = E2E_PROJECT / "project.godot"


# Every checked-in source path the M2–M6 tests must reach from the merged
# project root, relative to the project root. Paths are case-sensitive and
# must use forward slashes.
REQUIRED_PATHS: tuple[str, ...] = (
    # M2 — editor UI, scenes/resources/scripts
    "project.godot",
    "scenes/main.tscn",
    "scripts/player.gd",
    "scripts/target.gd",
    "resources/player_data.tres",
    "addons/gdapi_test/plugin.gd",
    "addons/gdapi_test/plugin.cfg",
    # M3 — runtime probes
    "scenes/runtime_main.tscn",
    "scripts/runtime_main.gd",
    "scripts/probe_target.gd",
    "scripts/probe_input.gd",
    "scripts/probe_input_action.gd",
    "scripts/probe_finished_signal.gd",
    # M4 — game systems
    "scenes/animation.tscn",
    "scenes/audio.tscn",
    "scenes/navigation.tscn",
    "scenes/physics.tscn",
    "scenes/rendering.tscn",
    "scenes/tilemap.tscn",
    "scenes/ui.tscn",
    "resources/tile_set.tres",
    "resources/tile.svg",
    "resources/navigation_polygon.tres",
    "resources/tone.tres",
    "shaders/basic.gdshader",
    # M5 — diagnostics, project config, export
    "main.tscn",
    "main.gd",
    "fixtures/state.gd",
    "fixtures/broken.gd",
    "fixtures/cycle_a.tres",
    "fixtures/cycle_b.tres",
    "fixtures/unused.tres",
    "tests/test_android_bridge.gd",
    "export_presets.cfg",
    # M6 — bulk, network, process, runtime eval
    "bulk/a.txt",
    "bulk/b.txt",
    "tools/sleep.cmd",
    "tools/echo_args.cmd",
    "tools/echo_args.py",
    "tools/emit_output.py",
    "tools/sleep.py",
)


# A capability policy that enables every capability. Tests that need to deny
# a capability write a tighter policy on top and reset through temporary_policy.
DEFAULT_POLICY_BYTES = (
    b"{"
    b'"version":1,'
    b'"capabilities":{'
    b'"editor_eval":{"enabled":true,"max_source_bytes":16384,"allowed_input_keys":[]},'
    b'"runtime_eval":{"enabled":true,"max_source_bytes":16384,"allowed_input_keys":[]},'
    b'"process":{"enabled":true,"executables":["sleep","sleep.cmd","echo_args","echo_args.cmd","echo_args.py"],"cwd_roots":["res://tools"],"max_timeout_ms":5000,"max_output_bytes":65536},'
    b'"network":{"enabled":true,"schemes":["http"],"hosts":["127.0.0.1","localhost"],"ports":[80,443],"max_timeout_ms":5000,"max_response_bytes":1048576,"max_redirects":5,"allow_private":true},'
    b'"bulk_files":{"enabled":true},'
    b'"bulk_deploy":{"enabled":true}'
    b"}"
    b"}"
)


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def test_unified_fixture_root_exists() -> None:
    assert E2E_PROJECT.is_dir(), f"missing unified fixture root at {E2E_PROJECT}"


def test_unified_fixture_lists_every_required_path() -> None:
    missing = [
        path for path in REQUIRED_PATHS if not (E2E_PROJECT / path).is_file()
    ]
    assert not missing, f"missing fixture paths: {missing}"


def test_unified_fixture_has_no_path_duplicates() -> None:
    """Each required relative path must be unique under the merged root."""
    counter: dict[str, int] = {}
    for path in REQUIRED_PATHS:
        counter[path] = counter.get(path, 0) + 1
    duplicates = sorted(p for p, count in counter.items() if count > 1)
    assert not duplicates, f"duplicated fixture paths: {duplicates}"


def test_unified_fixture_enables_test_plugin() -> None:
    project = _read(E2E_PROJECT_GODOT)
    assert re.search(
        r'^\[editor_plugins\][^\[]*enabled=PackedStringArray\([^)]*res://addons/gdapi_test/plugin\.cfg[^)]*\)',
        project,
        re.MULTILINE | re.DOTALL,
    ), "unified project must enable res://addons/gdapi_test/plugin.cfg"
    assert re.search(
        r'^\[editor_plugins\][^\[]*enabled=PackedStringArray\([^)]*res://addons/gdapi/plugin\.cfg[^)]*\)',
        project,
        re.MULTILINE | re.DOTALL,
    ), "unified project must enable res://addons/gdapi/plugin.cfg"


def test_unified_fixture_runtime_probe_section_present() -> None:
    """M3's runtime probe autoload is required by the runtime fixtures."""
    project = _read(E2E_PROJECT_GODOT)
    assert "GdApiRuntimeProbe" in project, "M3 autoload GdApiRuntimeProbe missing"


def test_unified_fixture_carries_default_capability_policy() -> None:
    policy_path = E2E_PROJECT / ".godot" / "gdapi-policy.json"
    assert policy_path.is_file(), (
        f"missing default policy at {policy_path} (write {policy_path} with "
        f"bytes from DEFAULT_POLICY_BYTES)"
    )
    actual = policy_path.read_bytes().strip()
    expected = DEFAULT_POLICY_BYTES.strip()
    assert actual == expected, (
        "default policy contents drifted from contract; update DEFAULT_POLICY_BYTES "
        "and confirm every test still sees the capabilities it depends on"
    )
