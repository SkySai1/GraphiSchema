import json
from pathlib import Path
import shutil

import pytest
from fastapi.testclient import TestClient

from graphischema import api
from graphischema.models import DiagramProject
from graphischema.storage import ProjectStore


ROOT = Path(__file__).resolve().parents[1]


def test_health_and_local_editor_routes(monkeypatch) -> None:
    monkeypatch.delenv("GRAPHI_SCHEMA_DATA_DIR", raising=False)
    with TestClient(api.app) as client:
        health = client.get("/api/health").json()
        assert health["status"] == "ok"
        assert health["revision_merge"] == "three_way_v1"
        assert health["edge_routing"] == "graphviz_v1"
        assert health["storage_scope"] == "project-local"
        assert client.get("/").json()["client"] == "native macOS AppKit"
    monkeypatch.setenv("GRAPHI_SCHEMA_DATA_DIR", "/tmp/graphischema-test-projects")
    assert api.health()["storage_scope"] == "application-support"


def test_diagram_api_merges_independent_stale_edits_and_rejects_overlapping_edits(tmp_path: Path, monkeypatch) -> None:
    store = ProjectStore(tmp_path, ROOT / "examples" / "starter.json")
    monkeypatch.setattr(api, "STORE", store)
    monkeypatch.setattr(api, "CONTROLLER", api.ApplicationController(store))
    with TestClient(api.app) as client:
        current = client.get("/api/diagram").json()
        project = DiagramProject.model_validate(current["diagram"])
        invalid = project.model_dump(mode="json")
        invalid["edges"][0]["target"] = "missing_node"
        rejected = client.put("/api/diagram", headers={"If-Match": current["revision"]}, json=invalid)
        assert rejected.status_code == 422
        assert store.load().project.title == "Защищённая веб-платформа"

        project.project.title = "Обновлённая схема"
        saved = client.put("/api/diagram", headers={"If-Match": current["revision"]}, json=project.model_dump(mode="json"))
        assert saved.status_code == 200
        assert saved.json()["diagram"]["project"]["title"] == "Обновлённая схема"

        stale_edit = DiagramProject.model_validate(current["diagram"])
        stale_edit.nodes[0].label = "Изменено во втором окне"
        merged = client.put("/api/diagram", headers={"If-Match": current["revision"]}, json=stale_edit.model_dump(mode="json"))
        assert merged.status_code == 200
        assert merged.json()["diagram"]["project"]["title"] == "Обновлённая схема"
        assert merged.json()["diagram"]["nodes"][0]["label"] == "Изменено во втором окне"

        overlapping_edit = DiagramProject.model_validate(current["diagram"])
        overlapping_edit.project.title = "Параллельное переименование"
        conflict = client.put("/api/diagram", headers={"If-Match": current["revision"]}, json=overlapping_edit.model_dump(mode="json"))
        assert conflict.status_code == 409
        assert "одно и то же поле" in conflict.json()["detail"].lower()
        assert store.load().project.title == "Обновлённая схема"
        assert store.load().nodes[0].label == "Изменено во втором окне"


def test_version_history_reports_diff_and_restores_snapshot(tmp_path: Path, monkeypatch) -> None:
    store = ProjectStore(tmp_path, ROOT / "examples" / "starter.json")
    monkeypatch.setattr(api, "STORE", store)
    monkeypatch.setattr(api, "CONTROLLER", api.ApplicationController(store))
    with TestClient(api.app) as client:
        initial = client.get("/api/diagram").json()
        original = DiagramProject.model_validate(initial["diagram"])
        original_revision = initial["revision"]

        changed = original.model_copy(deep=True)
        changed.project.title = "Новая версия архитектуры"
        changed.nodes[0].label = "Интернет"
        saved = client.put("/api/diagram", headers={"If-Match": original_revision}, json=changed.model_dump(mode="json"))
        assert saved.status_code == 200

        versions = client.get("/api/versions").json()["versions"]
        baseline = next(version for version in versions if version["revision"] == original_revision)
        diff = client.get(f"/api/versions/{baseline['id']}/diff")
        assert diff.status_code == 200
        assert "title" in diff.json()["project"]
        assert original.nodes[0].id in diff.json()["nodes"]["modified"]
        assert diff.json()["nodes"]["details"][0]["fields"] == ["label"]

        restored = client.post(f"/api/versions/{baseline['id']}/restore", headers={"If-Match": saved.json()["revision"]})
        assert restored.status_code == 200
        assert restored.json()["diagram"]["project"]["title"] == original.project.title
        assert restored.json()["diagram"]["nodes"][0]["label"] == original.nodes[0].label
        assert len(client.get("/api/versions").json()["versions"]) == 3


def test_undo_redo_are_revision_checked_and_new_changes_clear_redo(tmp_path: Path, monkeypatch) -> None:
    store = ProjectStore(tmp_path, ROOT / "examples" / "starter.json")
    controller = api.ApplicationController(store)
    monkeypatch.setattr(api, "STORE", store)
    monkeypatch.setattr(api, "CONTROLLER", controller)
    with TestClient(api.app) as client:
        initial = client.get("/api/diagram").json()
        assert client.get("/api/history").json() == {"canUndo": False, "canRedo": False}
        assert client.post("/api/undo", headers={"If-Match": initial["revision"]}).status_code == 409

        first = DiagramProject.model_validate(initial["diagram"])
        first.project.title = "Версия A"
        saved = client.put("/api/diagram", headers={"If-Match": initial["revision"]}, json=first.model_dump(mode="json"))
        undone = client.post("/api/undo", headers={"If-Match": saved.json()["revision"]})
        assert undone.status_code == 200
        assert undone.json()["diagram"]["project"]["title"] == "Защищённая веб-платформа"
        assert client.get("/api/history").json() == {"canUndo": False, "canRedo": True}

        redone = client.post("/api/redo", headers={"If-Match": undone.json()["revision"]})
        assert redone.status_code == 200
        assert redone.json()["diagram"]["project"]["title"] == "Версия A"
        second = DiagramProject.model_validate(redone.json()["diagram"])
        second.project.title = "Версия B"
        newer = client.put("/api/diagram", headers={"If-Match": redone.json()["revision"]}, json=second.model_dump(mode="json"))
        assert newer.status_code == 200
        assert client.get("/api/history").json() == {"canUndo": True, "canRedo": False}
        assert client.post("/api/redo", headers={"If-Match": newer.json()["revision"]}).status_code == 409


def test_validate_and_export_routes() -> None:
    with TestClient(api.app) as client:
        starter = json.loads((ROOT / "examples" / "starter.json").read_text())
        result = client.post("/api/validate", json=starter)
        assert result.status_code == 200
        assert result.json()["valid"] is True
        dot = client.get("/api/dot")
        assert dot.status_code == 200
        assert dot.text.startswith("digraph GraphiSchema")
        layout = client.get("/api/layout")
        assert layout.status_code == 200
        assert layout.json()["engine"] in {"fallback", "dot"}
        assert layout.json()["nodes"]
        rendered = client.get("/api/render.svg")
        assert rendered.status_code == 200
        assert rendered.headers["x-graphischema-layout"] in {"fallback", "dot"}
        assert "<svg" in rendered.text and "WAF" in rendered.text
        exported = client.get("/api/export.json")
        assert exported.status_code == 200
        assert exported.headers["content-type"].startswith("application/json")
        assert DiagramProject.model_validate_json(exported.content).project.title == "Защищённая веб-платформа"


def test_dot_preview_is_validated_and_does_not_write_project(tmp_path: Path, monkeypatch) -> None:
    store = ProjectStore(tmp_path, ROOT / "examples" / "starter.json")
    monkeypatch.setattr(api, "STORE", store)
    monkeypatch.setattr(api, "CONTROLLER", api.ApplicationController(store))
    with TestClient(api.app) as client:
        original = store.load()
        source = client.get("/api/dot").text.replace('label="WAF"', 'label="WAF preview"')

        preview = client.post("/api/dot/preview", json={"dot": source})

        assert preview.status_code == 200
        assert next(node for node in preview.json()["diagram"]["nodes"] if node["id"] == "waf")["label"] == "WAF preview"
        assert preview.json()["changes"]["nodes"] == ["~ waf"]
        assert preview.json()["layout"]["nodes"]
        assert store.load() == original

        rejected = client.post("/api/dot/preview", json={"dot": source.replace('label="WAF preview"', 'label="WAF preview", image="/tmp/a.png"')})
        assert rejected.status_code == 422
        assert "image" in rejected.json()["detail"]
        assert store.load() == original


def test_json_import_export_acceptance_preserves_nested_containers_and_styles(tmp_path: Path, monkeypatch) -> None:
    store = ProjectStore(tmp_path, ROOT / "examples" / "starter.json")
    monkeypatch.setattr(api, "STORE", store)
    monkeypatch.setattr(api, "CONTROLLER", api.ApplicationController(store))
    with TestClient(api.app) as client:
        current = client.get("/api/diagram").json()
        candidate_data = current["diagram"]
        candidate_data["containers"].append({
            "id": "dmz_services",
            "label": "DMZ services",
            "parent_id": "dmz",
            "padding": 24,
            "style": {"fill": "#FFF7ED", "stroke": "#EA580C", "text": "#9A3412"},
        })
        candidate = DiagramProject.model_validate(candidate_data)
        next(node for node in candidate.nodes if node.id == "waf").container_id = "dmz_services"
        next(node for node in candidate.nodes if node.id == "waf").style.fill = "#FEF3C7"

        imported = client.put("/api/diagram", headers={"If-Match": current["revision"]}, json=candidate.model_dump(mode="json"))
        assert imported.status_code == 200
        exported = client.get("/api/export.json")
        reimported = client.put(
            "/api/diagram",
            headers={"If-Match": imported.json()["revision"], "Content-Type": "application/json"},
            content=exported.content,
        )

        assert exported.status_code == 200
        assert reimported.status_code == 200
        assert DiagramProject.model_validate(reimported.json()["diagram"]) == candidate
        assert next(item for item in store.load().containers if item.id == "dmz_services").padding == 24


def test_ollama_routes_preview_edit_and_review_without_persisting(tmp_path: Path, monkeypatch) -> None:
    store = ProjectStore(tmp_path, ROOT / "examples" / "starter.json")
    original = store.load()
    monkeypatch.setattr(api, "STORE", store)
    monkeypatch.setattr(api, "CONTROLLER", api.ApplicationController(store))

    async def mock_check(_endpoint: str, _timeout: float):
        return [{"name": "qwen2.5:latest"}]

    async def mock_edit(_request, _current):
        return [{"op": "update_node", "id": "waf", "changes": {"label": "WAF proposal"}}]

    async def mock_generate(_request, current):
        candidate = current.model_copy(deep=True)
        candidate.project.title = "Generated proposal"
        return candidate

    async def mock_review(_request, _current):
        return {"errors": [], "warnings": ["Проверьте резервирование"], "recommendations": []}

    monkeypatch.setattr(api, "check_connection", mock_check)
    monkeypatch.setattr(api, "edit_operations", mock_edit)
    monkeypatch.setattr(api, "generate_project", mock_generate)
    monkeypatch.setattr(api, "review_project", mock_review)
    request = {"settings": {"model": "qwen2.5:latest"}, "prompt": "Проверь архитектуру"}
    with TestClient(api.app) as client:
        check = client.post("/api/ollama/check", json={"endpoint": "http://127.0.0.1:11434"})
        assert check.status_code == 200
        assert check.json()["models"] == [{"name": "qwen2.5:latest"}]

        stale = client.post("/api/ollama/generate", headers={"If-Match": "stale"}, json=request)
        assert stale.status_code == 409

        generated = client.post("/api/ollama/generate", headers={"If-Match": store.revision(original)}, json=request)
        assert generated.status_code == 200
        assert generated.json()["diagram"]["project"]["title"] == "Generated proposal"
        assert store.load() == original

        edit = client.post("/api/ollama/edit", json=request)
        assert edit.status_code == 200
        assert next(node for node in edit.json()["diagram"]["nodes"] if node["id"] == "waf")["label"] == "WAF proposal"
        assert store.load() == original

        review = client.post("/api/ollama/review", json=request)
        assert review.status_code == 200
        assert review.json()["report"]["warnings"] == ["Проверьте резервирование"]
        assert store.load() == original


@pytest.mark.skipif(not shutil.which("dot"), reason="Graphviz dot is not installed")
def test_png_export_route_accepts_scale_and_background() -> None:
    with TestClient(api.app) as client:
        response = client.get("/api/export.png", params={"scale": 1.5, "background": "transparent"})
        assert response.status_code == 200
        assert response.headers["content-type"] == "image/png"
        assert response.headers["x-graphischema-layout"] == "dot"
        assert response.content.startswith(b"\x89PNG\r\n\x1a\n")

        invalid = client.get("/api/export.png", params={"scale": 5, "background": "transparent"})
        assert invalid.status_code == 422
