"""E2E tests for export/android/deploy_many bulk deploy route."""

from __future__ import annotations

import pytest

pytestmark = pytest.mark.skip(
    reason="Android export tests require Android SDK/ADB environment"
)


from typing import Any



def test_bulk_deploy_docs_are_complete(m6_editor: dict[str, Any]) -> None:
    doc = command_doc(m6_editor, "export/android/deploy_many")
    assert doc["summary"]
    assert doc["returns"]["fields"]
    assert doc["examples"]
