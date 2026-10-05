from pathlib import Path
import re

import pytest

from .conftest import exec_error, exec_ok


def _root(env, path):
    return "res://" + path.relative_to(Path(env["project"])).as_posix()




def test_uid_repair_preflights_all_targets_before_writing(m5_editor, uid_workspace):
    """A late read-only collision must reject the whole batch before any UID writes."""
    import os

    work = uid_workspace
    root = _root(m5_editor, work)
    (work / "a.tres").write_text(
        '[gd_resource type="Resource" format=3]\n\n[resource]\n', encoding="utf-8"
    )
    (work / "b.tres").write_text(
        '[gd_resource type="Resource" format=3]\n\n[resource]\n', encoding="utf-8"
    )
    exec_ok(m5_editor, "uid/repair", {
        "roots": [root], "dry_run": False,
    })
    for source_name, target_name in (("a.tres", "c.tres"), ("b.tres", "d.tres")):
        for suffix in ("", ".uid"):
            source = work / (source_name + suffix)
            if source.exists():
                (work / (target_name + suffix)).write_bytes(source.read_bytes())

    before = exec_ok(m5_editor, "uid/repair", {
        "roots": [root], "dry_run": True,
    })
    assert len(before["changes"]) == 2, before
    assert all(change["status"] == "collision" for change in before["changes"]), before
    assert all(change["old_uid"] for change in before["changes"]), before
    assert [change["path"] for change in before["changes"]] == [
        root + "/c.tres",
        root + "/d.tres",
    ], before

    blocked = work / "d.tres"
    mode = blocked.stat().st_mode
    blocked.chmod(mode & ~0o222)
    assert not os.access(blocked, os.W_OK), "前置条件：d.tres 必须不可写"
    before_bytes = {path.name: path.read_bytes() for path in work.iterdir() if path.is_file()}
    try:
        error = exec_error(m5_editor, "uid/repair", {
            "roots": [root], "dry_run": False,
        })
        assert error["code"] == "permission_denied", error
        details = error["details"]
        assert details["failed_path"].endswith("d.tres"), details
        assert details["applied"] == 0, details
        assert {
            path.name: path.read_bytes() for path in work.iterdir() if path.is_file()
        } == before_bytes

        after = exec_ok(m5_editor, "uid/repair", {
            "roots": [root], "dry_run": True,
        })

        def _state(plan):
            # new_uid 每次规划都会重新生成，比较状态字段（path/old_uid/status）
            return [
                {"path": c["path"], "old_uid": c["old_uid"], "status": c["status"]}
                for c in plan["changes"]
            ]

        assert _state(after) == _state(before), (after, before)
    finally:
        blocked.chmod(mode)


def test_uid_repair_dry_run_writes_nothing(m5_editor, uid_workspace):
    """dry_run must not create or modify either resource bytes or UID sidecars."""
    fixtures = uid_workspace
    existing = fixtures / "existing.tres"
    existing.write_bytes(b'[gd_resource type="Resource" format=3]\n\n[resource]\n')
    exec_ok(m5_editor, "uid/repair", {"roots": [_root(m5_editor, fixtures)], "dry_run": False})
    match = re.search(r'uid="([^"]+)"', existing.read_text(encoding="utf-8"))
    assert match, existing.read_text(encoding="utf-8")
    sidecar = (match.group(1) + "\n").encode("utf-8")
    (fixtures / "existing.tres.uid").write_bytes(sidecar)
    assert exec_ok(m5_editor, "uid/get", {"file_path": _root(m5_editor, existing)})["uid"] == match.group(1)
    (fixtures / "missing.tres").write_bytes(b'[gd_resource type="Resource" format=3]\n\n[resource]\n')
    before = {path.name: path.read_bytes() for path in fixtures.iterdir()}
    plan = exec_ok(m5_editor, "uid/repair", {"roots": [_root(m5_editor, fixtures)], "dry_run": True})
    assert plan["changed"] is False
    assert {path.name: path.read_bytes() for path in fixtures.iterdir()} == before
    assert fixtures.is_dir()


def test_uid_repair_dry_run_apply_is_idempotent(m5_editor, uid_workspace):
    (uid_workspace / "missing.tres").write_bytes(b'[gd_resource type="Resource" format=3]\n\n[resource]\n')
    root = _root(m5_editor, uid_workspace)
    body = {"roots": [root], "dry_run": True}
    dry_run = exec_ok(m5_editor, "uid/repair", body)
    assert dry_run["changes"]
    assert dry_run["changed"] is False

    applied = exec_ok(m5_editor, "uid/repair", {
        "roots": [root], "dry_run": False,
    })
    assert applied["changed"] is True
    written = exec_ok(m5_editor, "filesystem/read", {"path": root + "/missing.tres"})["content"]
    assert written == (uid_workspace / "missing.tres").read_text(encoding="utf-8")
    assert 'uid="uid://' in written, written
    second = exec_ok(m5_editor, "uid/repair", body)
    assert second["changes"] == []
    assert second["changed"] is False


@pytest.mark.parametrize("root", [
    "res://addons/gdapi", "res://addons/gdapi/",
    "res://addons/gdapi/runtime", "res://addons/gdapi/runtime/protected.tres",
    "res://.godot", "res://.godot/",
    "res://./addons/gdapi", "res://./.godot",
])
@pytest.mark.parametrize("dry_run", [True, False])
def test_uid_repair_rejects_protected_roots_atomically(m5_editor, uid_workspace, root, dry_run):
    work = uid_workspace
    target = work / "missing.tres"
    target.write_text('[gd_resource type="Resource" format=3]\n\n[resource]\n', encoding="utf-8")
    before = {path.name: path.read_bytes() for path in work.iterdir()}
    error = exec_error(m5_editor, "uid/repair", {
        "roots": [_root(m5_editor, work), root], "dry_run": dry_run,
    })
    assert error["code"] == "permission_denied", error
    assert {path.name: path.read_bytes() for path in work.iterdir()} == before


def test_uid_repair_broad_scan_skips_protected_files_and_deduplicates_roots(m5_editor, uid_workspace):
    project = Path(m5_editor["project"])
    protected = project / "addons" / "gdapi" / "uid_protected.tres"
    protected.write_text('[gd_resource type="Resource" format=3]\n\n[resource]\n', encoding="utf-8")
    protected_before = protected.read_bytes()
    target = uid_workspace / "root_scan_target.tres"
    target_path = _root(m5_editor, target)
    original = b'[gd_resource type="Resource" format=3]\n\n[resource]\n'
    target.write_bytes(original)
    shader = uid_workspace / "root_scan_shader.gdshader"
    shader_path = _root(m5_editor, shader)
    shader_source = b"shader_type canvas_item;\nuniform float strength = 0.5;\n"
    shader.write_bytes(shader_source)
    try:
        single = exec_ok(m5_editor, "uid/repair", {"dry_run": True})
        target_changes = [item for item in single["changes"] if item["path"] == target_path]
        assert [item["status"] for item in target_changes] == ["missing"]
        assert [
            item["status"] for item in single["changes"] if item["path"] == shader_path
        ] == ["missing"]
        assert not shader.with_suffix(".gdshader.uid").exists()
        assert target.read_bytes() == original
        repeated = exec_ok(m5_editor, "uid/repair", {
            "roots": ["res://fixtures", "res://", "res://fixtures/", "res://.", "res:////"],
            "dry_run": True,
        })
        assert repeated["scanned"] == single["scanned"]
        fields = lambda plan: [
            (item["path"], item["old_uid"], item["status"]) for item in plan["changes"]
        ]
        assert fields(repeated) == fields(single)
        assert all(
            not item["path"].startswith(("res://addons/gdapi/", "res://.godot/"))
            for item in repeated["changes"]
        )
        applied = exec_ok(m5_editor, "uid/repair", {"roots": ["res://"], "dry_run": False})
        assert applied["changed"] is True
        assert target.read_bytes() != original
        assert shader.read_bytes() == shader_source
        shader_uid = exec_ok(m5_editor, "uid/get", {"file_path": shader_path})
        assert shader_uid["uid_exists"] is True
        assert shader_uid["uid"].startswith("uid://"), shader_uid
        assert shader.with_suffix(".gdshader.uid").read_text(encoding="utf-8").strip() == shader_uid["uid"]
        after = exec_ok(m5_editor, "uid/repair", {"roots": ["res://"], "dry_run": True})
        assert target_path not in [item["path"] for item in after["changes"]]
        assert shader_path not in [item["path"] for item in after["changes"]]
        assert protected.read_bytes() == protected_before
        assert not protected.with_suffix(".tres.uid").exists()
    finally:
        protected.unlink(missing_ok=True)
        protected.with_suffix(".tres.uid").unlink(missing_ok=True)


def test_uid_repair_read_only_missing_uid_does_not_partially_create_uids(m5_editor, uid_workspace):
    work = uid_workspace
    for name in ("a.tres", "z.tres"):
        (work / name).write_text(
            '[gd_resource type="Resource" format=3]\n\n[resource]\n', encoding="utf-8"
        )
    blocked = work / "z.tres"
    mode = blocked.stat().st_mode
    blocked.chmod(mode & ~0o222)
    before = {path.name: path.read_bytes() for path in work.iterdir()}
    try:
        error = exec_error(m5_editor, "uid/repair", {
            "roots": [_root(m5_editor, work)], "dry_run": False,
        })
        assert error["code"] == "permission_denied", error
        assert {path.name: path.read_bytes() for path in work.iterdir()} == before
    finally:
        blocked.chmod(mode)


@pytest.mark.parametrize(("first_name", "existing_sidecar"), [
    ("a_valid.tres", False),
    ("a_valid.gdshader", False),
    ("a_valid.gdshader", True),
])
def test_uid_repair_restores_all_target_bytes_when_late_resource_is_invalid(
    m5_editor, uid_workspace, first_name, existing_sidecar,
):
    """A failed set_uid on a later target restores earlier and partially changed bytes."""
    work = uid_workspace
    first = work / first_name
    invalid = work / "z_invalid.tres"
    first.write_bytes(
        b"shader_type canvas_item;\n"
        if first.suffix == ".gdshader"
        else b'[gd_resource type="Resource" format=3]\n\n[resource]\n'
    )
    if existing_sidecar:
        first.with_suffix(".gdshader.uid").write_bytes(b"invalid UID; preserve these bytes\n")
    invalid.write_bytes(b"not a Godot resource; preserve these exact bytes\n")
    before = {path.name: path.read_bytes() for path in work.iterdir() if path.is_file()}

    error = exec_error(m5_editor, "uid/repair", {
        "roots": [_root(m5_editor, work)], "dry_run": False,
    })

    assert error["code"] == "godot_error", error
    assert error["details"]["failed_path"] == _root(m5_editor, invalid)
    assert {path.name: path.read_bytes() for path in work.iterdir() if path.is_file()} == before
    dry_run = exec_ok(m5_editor, "uid/repair", {
        "roots": [_root(m5_editor, work)], "dry_run": True,
    })
    assert [change["path"] for change in dry_run["changes"]] == [
        _root(m5_editor, first),
        _root(m5_editor, invalid),
    ]
    assert all(change["status"] == "missing" for change in dry_run["changes"]), dry_run


def test_uid_repair_shader_collision_updates_only_the_duplicate_sidecar(m5_editor, uid_workspace):
    source = b"shader_type canvas_item;\nuniform float strength = 0.5;\n"
    first = uid_workspace / "a.gdshader"
    duplicate = uid_workspace / "b.gdshader"
    first.write_bytes(source)
    root = _root(m5_editor, uid_workspace)
    exec_ok(m5_editor, "uid/repair", {"roots": [root], "dry_run": False})
    first_uid = first.with_suffix(".gdshader.uid").read_bytes()
    duplicate.write_bytes(source)
    duplicate_uid = duplicate.with_suffix(".gdshader.uid")
    duplicate_uid.write_bytes(first_uid)

    dry_run = exec_ok(m5_editor, "uid/repair", {"roots": [root], "dry_run": True})
    assert [(change["path"], change["status"]) for change in dry_run["changes"]] == [
        (_root(m5_editor, duplicate), "collision"),
    ]
    assert first.with_suffix(".gdshader.uid").read_bytes() == first_uid
    assert duplicate_uid.read_bytes() == first_uid

    applied = exec_ok(m5_editor, "uid/repair", {"roots": [root], "dry_run": False})
    assert applied["changed"] is True
    assert first.read_bytes() == duplicate.read_bytes() == source
    assert first.with_suffix(".gdshader.uid").read_bytes() == first_uid
    assert duplicate_uid.read_bytes() != first_uid
    assert exec_ok(m5_editor, "uid/get", {"file_path": _root(m5_editor, duplicate)})["uid"] == (
        duplicate_uid.read_text(encoding="utf-8").strip()
    )
    assert exec_ok(m5_editor, "uid/repair", {"roots": [root], "dry_run": True})["changes"] == []


def test_uid_repair_read_only_shader_sidecar_preflights_the_whole_batch(m5_editor, uid_workspace):
    first = uid_workspace / "a_missing.tres"
    first.write_bytes(b'[gd_resource type="Resource" format=3]\n\n[resource]\n')
    shader = uid_workspace / "z_shader.gdshader"
    shader.write_bytes(b"shader_type canvas_item;\n")
    sidecar = shader.with_suffix(".gdshader.uid")
    sidecar.write_bytes(b"invalid UID; preserve these bytes\n")
    mode = sidecar.stat().st_mode
    sidecar.chmod(mode & ~0o222)
    before = {path.name: path.read_bytes() for path in uid_workspace.iterdir()}
    try:
        error = exec_error(m5_editor, "uid/repair", {
            "roots": [_root(m5_editor, uid_workspace)], "dry_run": False,
        })
        assert error["code"] == "permission_denied", error
        assert error["details"]["failed_path"] == _root(m5_editor, sidecar)
        assert error["details"]["applied"] == 0
        assert {path.name: path.read_bytes() for path in uid_workspace.iterdir()} == before
    finally:
        sidecar.chmod(mode)
