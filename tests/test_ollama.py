from pathlib import Path
import asyncio

import pytest

from graphischema.models import DiagramProject
from graphischema.ollama import OllamaError, OllamaSettings, _chat_json, apply_operations, _normalize_endpoint


ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def project() -> DiagramProject:
    return DiagramProject.model_validate_json((ROOT / "examples" / "starter.json").read_text())


def test_ollama_endpoint_only_accepts_http_endpoint_without_path() -> None:
    assert _normalize_endpoint("http://127.0.0.1:11434/") == "http://127.0.0.1:11434"
    with pytest.raises(OllamaError, match="endpoint Ollama"):
        _normalize_endpoint("http://127.0.0.1:11434/api?token=secret")
    with pytest.raises(OllamaError, match="endpoint Ollama"):
        _normalize_endpoint("file:///tmp/ollama")


def test_ollama_operations_apply_atomically_and_preserve_existing_ids(project: DiagramProject) -> None:
    candidate, changes = apply_operations(project, [{
        "op": "update_node",
        "id": "waf",
        "changes": {"label": "WAF v2", "style": {"stroke": "#DC2626"}},
    }])

    node = next(item for item in candidate.nodes if item.id == "waf")
    assert node.label == "WAF v2"
    assert node.style.stroke == "#DC2626"
    assert changes["nodes"] == ["~ waf"]
    assert next(item for item in project.nodes if item.id == "waf").label == "WAF"


def test_ollama_invalid_operation_batch_is_not_partially_applied(project: DiagramProject) -> None:
    with pytest.raises(OllamaError, match="не найден"):
        apply_operations(project, [
            {"op": "update_node", "id": "waf", "changes": {"label": "Changed"}},
            {"op": "update_node", "id": "missing", "changes": {"label": "Broken"}},
        ])
    assert next(item for item in project.nodes if item.id == "waf").label == "WAF"


def test_ollama_operations_reject_unknown_fields_and_invalid_graph(project: DiagramProject) -> None:
    with pytest.raises(OllamaError, match="недопустимые поля"):
        apply_operations(project, [{"op": "update_node", "id": "waf", "changes": {"shell": "touch /tmp/x"}}])
    with pytest.raises(OllamaError, match="не применены"):
        apply_operations(project, [{"op": "delete_node", "id": "waf"}])


def test_ollama_chat_uses_json_schema_and_configured_generation_options(monkeypatch) -> None:
    calls = []

    def fake_request(endpoint, path, body, timeout):
        calls.append((endpoint, path, body, timeout))
        return {"message": {"content": "{\"ok\":true}"}}

    monkeypatch.setattr("graphischema.ollama._request", fake_request)
    settings = OllamaSettings(model="qwen2.5", temperature=0.4, num_ctx=4096, timeout=44)
    schema = {"type": "object", "properties": {"ok": {"type": "boolean"}}}

    response = asyncio.run(_chat_json(settings, "system", "user", schema))

    assert response == {"ok": True}
    endpoint, path, payload, timeout = calls[0]
    assert (endpoint, path, timeout) == ("http://127.0.0.1:11434", "/api/chat", 44)
    assert payload["stream"] is False
    assert payload["format"] == schema
    assert payload["options"] == {"temperature": 0.4, "num_ctx": 4096}
