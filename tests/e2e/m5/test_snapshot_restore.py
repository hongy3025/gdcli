from pathlib import Path

from .conftest import assert_snapshot_restored, project_snapshot, restore_snapshot, tree_digest


def test_project_snapshot_restores_after_mutation(m5_editor):
    before = project_snapshot(m5_editor)
    path = Path(m5_editor["project"]) / "project.godot"
    path.write_text(path.read_text(encoding="utf-8") + "\n[temporary]\nvalue=1\n", encoding="utf-8")
    restore_snapshot(m5_editor)
    assert_snapshot_restored(m5_editor, before)


def test_source_fixture_is_immutable(m5_editor):
    assert tree_digest(m5_editor["source_fixture"]) == m5_editor["source_digest"]

