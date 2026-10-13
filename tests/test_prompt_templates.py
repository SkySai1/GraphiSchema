import asyncio
import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError

from graphischema import api, ollama
from graphischema.models import DiagramProject
from graphischema.prompt_templates import DEFAULT_VARIABLES, PromptTemplateError, PromptPreviewRequest, render_system_prompt


def test_default_graphviz_variable_and_custom_variable_overrides():
    result = render_system_prompt("{{ graphviz_attributes }}\n{{ team | upper }}", {"team": "network"})
    assert "tailport" in result and "splines=ortho" in result and result.endswith("NETWORK")
    assert render_system_prompt("{{ graphviz_attributes }}", {"graphviz_attributes": "custom"}) == "custom"
    assert DEFAULT_VARIABLES["graphviz_attributes"] != "custom"


def test_supported_text_filters_and_conditions_render_normally():
    assert render_system_prompt('{{ role | trim | lower | replace("a", "b") }}', {"role": " ABC "}) == "bbc"
    assert render_system_prompt('{{ missing | default("fallback") }}', {}) == "fallback"
    assert render_system_prompt('{% if role %}{{ role }}{% endif %}', {"role": "Architect"}) == "Architect"


@pytest.mark.parametrize("source", ["{{ missing }}", "{{ invalid", "{{ value.__class__ }}", "{% for i in range(100000) %}x{% endfor %}", "{{ 'x' * 100000000 }}", "{{ value | replace }}"])
def test_template_errors_are_reported_before_ollama(source):
    with pytest.raises(PromptTemplateError):
        render_system_prompt(source, {"value": "text"})


def test_expansion_and_variable_validation_limits():
    with pytest.raises(PromptTemplateError):
        render_system_prompt("{{ x }}"*3, {"x": "a"*32000})
    with pytest.raises(PromptTemplateError):
        render_system_prompt("{{ x | replace('a', 'aaa') }}", {"x": "a"*32000})
    with pytest.raises(ValidationError):
        PromptPreviewRequest(system_prompt="text", variables={"bad key": "value"})


def test_prompt_preview_is_local_and_does_not_change_project(monkeypatch):
    def fail(*args, **kwargs):
        raise AssertionError("Ollama must not be called by template preview")
    monkeypatch.setattr(ollama, "_request", fail)
    with TestClient(api.app) as client:
        before = client.get("/api/diagram").json()
        defaults = client.get("/api/ollama/variables/defaults").json()["variables"]
        assert defaults == DEFAULT_VARIABLES
        preview = client.post("/api/ollama/prompt/preview", json={"system_prompt": "{{ team }}\n{{ graphviz_attributes }}", "variables": {"team": "DMZ"}})
        assert preview.status_code == 200 and preview.json()["prompt"].startswith("DMZ\n")
        assert client.post("/api/ollama/prompt/preview", json={"system_prompt": "{{ missing }}"}).status_code == 422
        assert before == client.get("/api/diagram").json()


@pytest.mark.parametrize("mode", ["generate", "edit", "review"])
def test_all_ollama_modes_receive_rendered_prompt(mode, monkeypatch):
    calls = []
    async def fake_chat(settings, system, user, schema=None):
        calls.append(system)
        if mode == "generate": return DiagramProject().model_dump()
        if mode == "edit": return {"operations": []}
        return {"errors": [], "warnings": [], "recommendations": []}
    monkeypatch.setattr(ollama, "_chat_json", fake_chat)
    request = ollama.OllamaTaskRequest(settings=ollama.OllamaSettings(model="local", system_prompt="{{ role }}\n{{ graphviz_attributes }}", variables={"role": "Architect"}), prompt="Check")
    function = {"generate": ollama.generate_project, "edit": ollama.edit_operations, "review": ollama.review_project}[mode]
    asyncio.run(function(request, DiagramProject()))
    assert calls[0].startswith("Architect\n") and "tailport" in calls[0] and "{{" not in calls[0]
