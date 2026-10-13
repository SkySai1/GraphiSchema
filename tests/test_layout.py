from pathlib import Path
import shutil

import pytest

from graphischema.layout import compute_layout
from graphischema.models import DiagramProject


ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def project() -> DiagramProject:
    return DiagramProject.model_validate_json((ROOT / "examples" / "starter.json").read_text())


@pytest.mark.skipif(not shutil.which("dot"), reason="Graphviz dot is not installed")
def test_graphviz_layout_returns_canvas_geometry(project: DiagramProject) -> None:
    layout = compute_layout(project)
    assert layout["engine"] == "dot"
    assert layout["width"] > 0 and layout["height"] > 0
    assert {node["id"] for node in layout["nodes"]} == {node.id for node in project.nodes}
    assert len(layout["edges"]) == len(project.edges)
    assert all(len(edge["points"]) >= 4 for edge in layout["edges"])


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
