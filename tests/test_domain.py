from pathlib import Path

import pytest
from pydantic import ValidationError

from graphischema.dot import to_dot
from graphischema.models import DiagramNode, DiagramProject
from graphischema.validation import validate_diagram


ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def project() -> DiagramProject:
    return DiagramProject.model_validate_json((ROOT / "examples" / "starter.json").read_text())


def test_starter_model_has_expected_graph() -> None:
    project = DiagramProject.model_validate_json((ROOT / "examples" / "starter.json").read_text())
    assert len(project.nodes) == 4
    assert len(project.edges) == 3
    assert len(project.containers) == 2


def test_duplicate_ids_are_rejected(project: DiagramProject) -> None:
    data = project.model_dump(mode="json")
    data["nodes"][0]["id"] = data["containers"][0]["id"]
    with pytest.raises(ValidationError, match="unique"):
        DiagramProject.model_validate(data)


def test_missing_edge_endpoint_is_rejected(project: DiagramProject) -> None:
    data = project.model_dump(mode="json")
    data["edges"][0]["target"] = "missing_node"
    with pytest.raises(ValidationError, match="missing target"):
        DiagramProject.model_validate(data)


def test_container_cycles_are_rejected(project: DiagramProject) -> None:
    data = project.model_dump(mode="json")
    data["containers"][0]["parent_id"] = data["containers"][1]["id"]
    data["containers"][1]["parent_id"] = data["containers"][0]["id"]
    with pytest.raises(ValidationError, match="cycle"):
        DiagramProject.model_validate(data)


def test_invalid_color_is_rejected(project: DiagramProject) -> None:
    data = project.model_dump(mode="json")
    data["nodes"][0]["style"]["fill"] = "red; URL"
    with pytest.raises(ValidationError, match="#RRGGBB"):
        DiagramProject.model_validate(data)


def test_container_padding_defaults_and_is_bounded(project: DiagramProject) -> None:
    assert project.containers[0].padding == 16
    project.containers[0].padding = 32
    assert "margin=0.444444444444" in to_dot(project)
    data = project.model_dump(mode="json")
    data["containers"][0]["padding"] = 80
    with pytest.raises(ValidationError, match="less than or equal to 48"):
        DiagramProject.model_validate(data)


def test_node_size_is_optional_but_must_be_a_valid_pair(project: DiagramProject) -> None:
    project.nodes[0].width = 3.25
    project.nodes[0].height = 1.1
    dot = to_dot(project)
    assert 'fixedsize=true' in dot
    assert 'width=3.25' in dot and 'height=1.1' in dot
    data = project.model_dump(mode="json")
    data["nodes"][0]["height"] = None
    with pytest.raises(ValidationError, match="set together"):
        DiagramProject.model_validate(data)
    data["nodes"][0]["height"] = 1.1
    data["nodes"][0]["width"] = 12
    with pytest.raises(ValidationError, match="less than or equal to 10"):
        DiagramProject.model_validate(data)


def test_dot_generation_is_deterministic_and_escapes_labels(project: DiagramProject) -> None:
    project.nodes[0].label = 'Client "A"'
    dot = to_dot(project)
    assert dot == to_dot(project)
    assert 'Client \\\"A\\\"' in dot
    assert '"waf" -> "api"' in dot


def test_quality_validation_reports_disconnected_node(project: DiagramProject) -> None:
    project.nodes.append(DiagramNode(id="orphan", label="Orphan"))
    issues = validate_diagram(project)
    assert any(issue.code == "NODE_UNCONNECTED" and issue.element_ids == ("orphan",) for issue in issues)
