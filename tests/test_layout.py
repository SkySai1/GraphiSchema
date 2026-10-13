from pathlib import Path
import shutil

import pytest

from graphischema.layout import compute_layout
from graphischema.models import DiagramProject


ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def project() -> DiagramProject:
    return DiagramProject.model_validate_json((ROOT / "examples" / "starter.json").read_text())


def test_empty_project_has_usable_canvas_geometry() -> None:
    project = DiagramProject.model_validate({"project": {"title": "Пустая схема"}})
    layout = compute_layout(project)
    assert layout["width"] > 0 and layout["height"] > 0
    assert layout["nodes"] == [] and layout["edges"] == []


@pytest.mark.skipif(not shutil.which("dot"), reason="Graphviz dot is not installed")
def test_graphviz_layout_returns_canvas_geometry(project: DiagramProject) -> None:
    layout = compute_layout(project)
    assert layout["engine"] == "dot"
    assert layout["width"] > 0 and layout["height"] > 0
    assert {node["id"] for node in layout["nodes"]} == {node.id for node in project.nodes}
    assert len(layout["edges"]) == len(project.edges)
    assert all(len(edge["points"]) >= 4 for edge in layout["edges"])


@pytest.mark.skipif(not shutil.which("dot") or not shutil.which("neato"), reason="Graphviz is not installed")
@pytest.mark.parametrize("manual", [False, True])
@pytest.mark.parametrize("routing", ["straight", "angled", "orthogonal"])
def test_graphviz_routes_in_auto_and_manual_modes(project: DiagramProject, routing: str, manual: bool) -> None:
    project.diagram.edge_routing = routing
    if manual:
        project.diagram.layout_mode = "manual"
        for index, node in enumerate(project.nodes):
            node.x, node.y = index * 3.0, (index % 2) * 2.0

    layout = compute_layout(project)

    assert layout["edgeRouting"] == routing
    assert len(layout["edges"]) == len(project.edges)
    for edge in layout["edges"]:
        points = edge["points"]
        assert len(points) >= 2
        if routing == "orthogonal":
            assert all(
                abs(first["x"] - second["x"]) < 0.001 or abs(first["y"] - second["y"]) < 0.001
                for first, second in zip(points, points[1:])
            )
        elif routing == "straight":
            start, end = points[0], points[-1]
            dx, dy = end["x"] - start["x"], end["y"] - start["y"]
            assert all(abs((point["x"] - start["x"]) * dy - (point["y"] - start["y"]) * dx) < 0.002 for point in points)


@pytest.mark.parametrize("direction", ["LR", "TB"])
def test_fallback_orthogonal_routes_stay_aligned(project: DiagramProject, direction: str, monkeypatch: pytest.MonkeyPatch) -> None:
    from graphischema import layout as layout_module

    monkeypatch.setattr(layout_module.shutil, "which", lambda _: None)
    project.diagram.edge_routing = "orthogonal"
    project.diagram.direction = direction
    project.diagram.layout_mode = "manual"
    for index, node in enumerate(project.nodes):
        node.x, node.y = index * 3.0, index * 2.0

    layout = compute_layout(project)

    assert layout["edgeRouting"] == "orthogonal"
    for edge in layout["edges"]:
        assert all(first["x"] == second["x"] or first["y"] == second["y"]
                   for first, second in zip(edge["points"], edge["points"][1:]))


@pytest.mark.skipif(not shutil.which("neato"), reason="Graphviz neato is not installed")
def test_manual_layout_preserves_relative_node_positions(project: DiagramProject) -> None:
    project.diagram.layout_mode = "manual"
    project.diagram.layout_engine = "neato"
    for index, node in enumerate(project.nodes):
        node.x = float(index * 3 - 3)
        node.y = float(index - 1)

    layout = compute_layout(project)
    positions = {node["id"]: node["x"] for node in layout["nodes"]}
    assert layout["engine"] == "neato"
    assert positions[project.nodes[1].id] - positions[project.nodes[0].id] == pytest.approx(3.0)
    assert layout["minX"] < 0 and layout["minY"] < 0


@pytest.mark.skipif(not shutil.which("dot"), reason="Graphviz dot is not installed")
def test_graphviz_layout_uses_persisted_node_dimensions(project: DiagramProject) -> None:
    project.nodes[0].width = 3.1
    project.nodes[0].height = 1.2
    layout = compute_layout(project)
    node = next(item for item in layout["nodes"] if item["id"] == project.nodes[0].id)
    assert node["width"] == pytest.approx(3.1)
    assert node["height"] == pytest.approx(1.2)


def test_fallback_layout_uses_persisted_node_dimensions(project: DiagramProject, monkeypatch: pytest.MonkeyPatch) -> None:
    from graphischema import layout as layout_module

    monkeypatch.setattr(layout_module.shutil, "which", lambda _: None)
    project.nodes[0].width = 3.4
    project.nodes[0].height = 1.35
    layout = compute_layout(project)
    node = next(item for item in layout["nodes"] if item["id"] == project.nodes[0].id)
    assert layout["engine"] == "fallback"
    assert node["width"] == pytest.approx(3.4)
    assert node["height"] == pytest.approx(1.35)
