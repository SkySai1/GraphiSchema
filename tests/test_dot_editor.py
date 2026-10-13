from pathlib import Path

import pytest

from graphischema.dot import to_dot
from graphischema.dot_editor import DOTEditError, apply_dot
from graphischema.models import DiagramProject


ROOT = Path(__file__).resolve().parents[1]


def starter() -> DiagramProject:
    return DiagramProject.model_validate_json((ROOT / "examples" / "starter.json").read_text())


def test_generated_dot_round_trips_without_changes() -> None:
    project = starter()

    candidate, changes = apply_dot(project, to_dot(project))

    assert candidate == project
    assert changes == {"containers": [], "nodes": [], "edges": [], "settings": []}


def test_dot_attribute_edit_preserves_stable_ids() -> None:
    project = starter()
    source = to_dot(project).replace('label="WAF"', 'label="WAF v2"')

    candidate, changes = apply_dot(project, source)

    assert next(node for node in candidate.nodes if node.id == "waf").label == "WAF v2"
    assert {edge.id for edge in candidate.edges} == {edge.id for edge in project.edges}
    assert changes["nodes"] == ["~ waf"]


def test_dot_preserves_graphically_resized_node_dimensions() -> None:
    project = starter()
    node = next(item for item in project.nodes if item.id == "waf")
    node.width, node.height = 3.2, 1.15
    candidate, _ = apply_dot(project, to_dot(project))
    resized = next(item for item in candidate.nodes if item.id == "waf")
    assert resized.width == pytest.approx(3.2)
    assert resized.height == pytest.approx(1.15)


def test_dot_can_add_nodes_and_edges_with_stable_safe_ids() -> None:
    project = DiagramProject.model_validate({"project": {"title": "Тест"}, "nodes": [{"id": "a", "label": "A"}, {"id": "b", "label": "B"}]})
    source = '''digraph G {
      graph [rankdir=TB, compound=true, pad=0.25];
      node [fontname="Arial", fontsize=10, margin="0.16,0.1"];
      edge [fontname="Arial", fontsize=9];
      a [label="Alpha", shape=box, style="filled,rounded", fillcolor="#FFFFFF", color="#2563EB", fontcolor="#0F172A", penwidth=1.5, tooltip="service"];
      b [label="Beta"];
      queue [label="Queue"];
      a -> queue [label="events", style=dashed, color="#F59E0B"];
    }'''

    candidate, changes = apply_dot(project, source)

    assert {node.id for node in candidate.nodes} == {"a", "b", "queue"}
    assert candidate.edges[0].source == "a" and candidate.edges[0].target == "queue"
    assert candidate.edges[0].id.startswith("edge_")
    assert changes["nodes"] == ["+ queue", "~ a", "~ b"]
    assert changes["edges"] == [f"+ {candidate.edges[0].id}"]


@pytest.mark.parametrize(("before", "after", "reason"), [
    ('label="WAF"', 'label="WAF", URL="https://example.test"', "URL"),
    ('label="WAF"', 'label="WAF", image="/tmp/private.png"', "image"),
    ('shape="hexagon"', 'shape="record"', "shape"),
])
def test_dot_rejects_unsupported_constructs_instead_of_dropping_them(before: str, after: str, reason: str) -> None:
    project = starter()
    source = to_dot(project).replace(before, after)

    with pytest.raises(DOTEditError, match=reason):
        apply_dot(project, source)


def test_dot_manual_positions_require_every_new_node_to_have_coordinates() -> None:
    project = starter()
    source = to_dot(project).replace('label="WAF"', 'label="WAF", pos="144,288!"')

    with pytest.raises(DOTEditError, match="задайте pos всем новым узлам"):
        apply_dot(project, source)


def test_dot_rejects_graphviz_label_substitutions_that_would_change_meaning() -> None:
    project = starter()
    source = to_dot(project).replace('label="WAF"', 'label="\\N"')

    with pytest.raises(DOTEditError, match="escape"):
        apply_dot(project, source)
