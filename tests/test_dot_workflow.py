from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from graphischema import api
from graphischema.dot import to_dot
from graphischema.dot_editor import apply_dot
from graphischema.models import DiagramProject
from graphischema.storage import ProjectStore


ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def workflow(tmp_path, monkeypatch):
    store = ProjectStore(tmp_path, ROOT / "examples" / "starter.json")
    controller = api.ApplicationController(store)
    monkeypatch.setattr(api, "STORE", store)
    monkeypatch.setattr(api, "CONTROLLER", controller)
    with TestClient(api.app) as client:
        yield client, store, controller


def canvas_edits(base: DiagramProject) -> DiagramProject:
    current = base.model_copy(deep=True)
    current.diagram.layout_mode = "manual"
    for index, node in enumerate(current.nodes):
        node.x, node.y = 2.123456789 + index * 3, 3.987654321
    current.nodes[0].style.stroke = "#AA3399"
    added = current.nodes[0].model_copy(deep=True)
    added.id, added.label, added.container_id = "recent_node", "Added on canvas", None
    added.x, added.y = 8.123456789, 7.987654321
    current.nodes.append(added)
    return current


def test_unchanged_old_dot_keeps_all_recent_canvas_edits_and_history(workflow):
    client, store, controller = workflow
    base = store.load()
    current = canvas_edits(base)
    controller.replace_project(current)
    versions, history = store.list_versions(), controller.history_state
    response = client.post("/api/dot/preview", headers={"If-Match": store.revision(current)},
                           json={"dot": to_dot(base), "base_diagram": base.model_dump(mode="json")})
    assert response.status_code == 200
    assert DiagramProject.model_validate(response.json()["diagram"]) == current
    assert response.json()["changes"] == {"nodes": [], "containers": [], "edges": [], "settings": []}
    assert store.load() == current
    assert store.list_versions() == versions
    assert controller.history_state == history


def test_dot_label_edit_merges_with_canvas_add_move_and_style_and_undo(workflow):
    client, store, controller = workflow
    base = store.load()
    current = canvas_edits(base)
    controller.replace_project(current)
    revision = store.revision(current)
    source = to_dot(base).replace('label="WAF"', 'label="DOT label"')
    preview = client.post("/api/dot/preview", headers={"If-Match": revision},
                          json={"dot": source, "base_diagram": base.model_dump(mode="json")})
    assert preview.status_code == 200
    expected = current.model_copy(deep=True)
    next(node for node in expected.nodes if node.id == "waf").label = "DOT label"
    assert DiagramProject.model_validate(preview.json()["diagram"]) == expected
    assert preview.json()["changes"] == {"nodes": ["~ waf"], "containers": [], "edges": [], "settings": []}
    assert store.load() == current
    applied = client.put("/api/diagram", headers={"If-Match": revision}, json=preview.json()["diagram"])
    assert applied.status_code == 200
    undo = client.post("/api/undo", headers={"If-Match": applied.json()["revision"]})
    assert undo.status_code == 200
    assert DiagramProject.model_validate(undo.json()["diagram"]) == current
    redo = client.post("/api/redo", headers={"If-Match": undo.json()["revision"]})
    assert redo.status_code == 200
    assert DiagramProject.model_validate(redo.json()["diagram"]) == expected


def test_dot_check_does_not_restore_objects_deleted_on_canvas(workflow):
    client, store, controller = workflow
    base = store.load()
    current = base.model_copy(deep=True)
    current.nodes = [node for node in current.nodes if node.id != "waf"]
    current.edges = [edge for edge in current.edges if "waf" not in (edge.source, edge.target)]
    controller.replace_project(current)
    response = client.post("/api/dot/preview", json={"dot": to_dot(base), "base_diagram": base.model_dump(mode="json")})
    assert response.status_code == 200
    assert DiagramProject.model_validate(response.json()["diagram"]) == current
    assert store.load() == current


def test_dot_conflicting_label_edit_is_rejected_without_writes(workflow):
    client, store, controller = workflow
    base = store.load()
    current = base.model_copy(deep=True)
    next(node for node in current.nodes if node.id == "waf").label = "Canvas label"
    controller.replace_project(current)
    versions, history = store.list_versions(), controller.history_state
    response = client.post("/api/dot/preview", json={
        "dot": to_dot(base).replace('label="WAF"', 'label="DOT label"'),
        "base_diagram": base.model_dump(mode="json"),
    })
    assert response.status_code == 409
    assert "одни и те же поля" in response.json()["detail"]
    assert store.load() == current
    assert store.list_versions() == versions
    assert controller.history_state == history


def test_dot_fetch_and_check_reject_a_stale_revision(workflow):
    client, store, controller = workflow
    base = store.load()
    revision = store.revision(base)
    controller.replace_project(canvas_edits(base))
    assert client.get("/api/dot", headers={"If-Match": revision}).status_code == 409
    assert client.post("/api/dot/preview", headers={"If-Match": revision}, json={"dot": to_dot(base)}).status_code == 409


def test_dot_rejects_a_draft_from_another_project(workflow):
    client, store, _ = workflow
    base = store.load()
    foreign = base.model_copy(deep=True)
    foreign.project.id = "another_project"
    response = client.post("/api/dot/preview", json={"dot": to_dot(base), "base_diagram": foreign.model_dump(mode="json")})
    assert response.status_code == 422
    assert store.load() == base


@pytest.mark.parametrize("edit", [False, True])
def test_dot_check_preserves_exact_manual_coordinates_and_container_padding(workflow, edit):
    _, store, _ = workflow
    project = canvas_edits(store.load())
    project.containers[0].padding = 14.123456789
    source = to_dot(project)
    if edit:
        source = source.replace('label="WAF"', 'label="DOT label"')
    candidate, changes = apply_dot(project, source)
    expected = project.model_copy(deep=True)
    if edit:
        next(node for node in expected.nodes if node.id == "waf").label = "DOT label"
    assert candidate == expected
    assert changes["nodes"] == (["~ waf"] if edit else [])
    assert changes["containers"] == []
