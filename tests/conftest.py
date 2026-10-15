"""Every test uses a temporary repository and never migrates real user data."""
from pathlib import Path
import pytest

@pytest.fixture(autouse=True)
def isolated_application_storage(tmp_path, monkeypatch):
    from graphischema.rendering import _render_geometry_slot
    _render_geometry_slot.cache_clear()
    from graphischema import api
    from graphischema.storage import ProjectStore, REQUEST_SCOPE
    from graphischema.application.controller import ApplicationController
    monkeypatch.setenv("GRAPHI_SCHEMA_CONFIG_DIR", str(tmp_path/"config"))
    monkeypatch.setenv("GRAPHI_SCHEMA_DATA_DIR", str(tmp_path/"projects"))
    monkeypatch.setenv("GRAPHI_SCHEMA_DISABLE_MIGRATION", "1")
    store = ProjectStore(tmp_path/"projects", Path(__file__).resolve().parents[1]/"examples"/"starter.json")
    monkeypatch.setattr(api, "STORE", store)
    monkeypatch.setattr(api, "CONTROLLER", ApplicationController(store))
    token = REQUEST_SCOPE.set((None, None))
    try:
        yield store
    finally:
        REQUEST_SCOPE.reset(token)
        _render_geometry_slot.cache_clear()
