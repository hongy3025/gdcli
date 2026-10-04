"""Acceptance: M2–M4 module fixtures observe the same shared environment.

The contract runs only when a Godot editor is available, because it asks
the e2e_editor fixture to start the shared process. It then requests each
of the legacy M2–M4 fixture names and asserts they observe the same PID,
resolved project directory, and gdapi metadata.
"""

from __future__ import annotations

import sys

import pytest

# 只导入模块，不要 `from ... import e2e_editor`：把 fixture 函数导入测试模块
# 会在该模块再注册一份定义，pytest 会为它单独建立一次会话级 fixture
# （实测导致同一会话启动两个编辑器，见本文件末尾的单编辑器断言）。
import e2e.shared_fixture as shared_fixture


pytestmark = pytest.mark.timeout(60)

# 历史缺陷：同一文件被 `e2e.shared_fixture` 与 `tests.e2e.shared_fixture`
# 各导入一次，产生两套 fixture 定义与两份启动计数，"单编辑器"契约失效。
DUPLICATE_FIXTURE_MODULE = "tests.e2e.shared_fixture"


def test_shared_fixture_has_a_single_module_identity() -> None:
    assert DUPLICATE_FIXTURE_MODULE not in sys.modules, (
        "shared_fixture 被重复导入，会注册第二套 e2e_editor fixture"
    )


def test_m2_alias_shares_e2e_editor(m2_editor, e2e_editor):
    assert m2_editor["editor_pid"] == e2e_editor["editor_pid"]
    assert m2_editor["project"].resolve() == e2e_editor["project"].resolve()
    assert m2_editor["meta"] == e2e_editor["meta"]


def test_m3_alias_shares_e2e_editor(m3_editor, e2e_editor):
    assert m3_editor["editor_pid"] == e2e_editor["editor_pid"]
    assert m3_editor["project"].resolve() == e2e_editor["project"].resolve()
    assert m3_editor["meta"] == e2e_editor["meta"]


def test_m4_alias_shares_e2e_editor(m4_env, e2e_editor):
    assert m4_env["editor_pid"] == e2e_editor["editor_pid"]
    assert m4_env["project"].resolve() == e2e_editor["project"].resolve()
    assert m4_env["meta"] == e2e_editor["meta"]


def test_editor_start_counter_records_one_start(e2e_editor):
    counter = shared_fixture.EDITOR_START_COUNTER
    assert counter["starts"] == 1, (
        f"expected exactly one editor start, got {counter['starts']}; "
        f"events={counter.get('events', [])}; callers={counter.get('callers', [])}"
    )
    assert e2e_editor["editor_pid"] in counter["pids"]
    # Emit machine-checkable line for the nested full-suite budget test
    print(f"\nGODOT_EDITOR_STARTS={counter['starts']}")
