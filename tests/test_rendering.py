from pathlib import Path
import shutil
from xml.etree import ElementTree

import pytest

from graphischema.models import DiagramProject
from graphischema.rendering import LayoutError, render_fallback_svg, render_png, render_svg


ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def project() -> DiagramProject:
    return DiagramProject.model_validate_json((ROOT / "examples" / "starter.json").read_text())


def test_fallback_svg_is_valid_and_contains_graph_labels(project: DiagramProject) -> None:
    svg = render_fallback_svg(project)
    assert svg.startswith('<svg xmlns="http://www.w3.org/2000/svg"')
    assert "WAF" in svg
    assert "PostgreSQL" in svg
    assert "DMZ" in svg
    assert "HTTPS" in svg
    assert svg.endswith("</svg>")


def test_fallback_svg_is_deterministic(project: DiagramProject) -> None:
    assert render_fallback_svg(project) == render_fallback_svg(project)


def test_fallback_svg_paints_nodes_by_z_index(project: DiagramProject) -> None:
    project.nodes[0].z_index = 3
    root = ElementTree.fromstring(render_fallback_svg(project))
    labels = [item.text for item in root.iter() if item.tag.endswith("text") and item.text in {node.label for node in project.nodes}]
    expected = [node.label for _, node in sorted(enumerate(project.nodes), key=lambda pair: (pair[1].z_index, pair[0]))]
    assert labels == expected


@pytest.mark.parametrize(("routing", "segments"), [
    ("straight", 1),
    ("angled", 2),
    ("orthogonal", 3),
])
def test_fallback_svg_respects_edge_routing(project: DiagramProject, routing: str, segments: int) -> None:
    edge = project.edges[0]
    edge.style.color = "#123ABC"
    project.diagram.edge_routing = routing

    svg = ElementTree.fromstring(render_fallback_svg(project))
    path = next(
        item for item in svg.iter()
        if item.tag.endswith("path") and item.get("fill") == "none" and item.get("stroke") == "#123ABC"
    )

    assert path.get("d", "").count(" L ") == segments


def test_fallback_svg_reflects_custom_node_dimensions(project: DiagramProject) -> None:
    project.nodes[0].shape = "box"
    project.nodes[0].width = 4.0
    project.nodes[0].height = 1.2
    svg = render_fallback_svg(project)
    assert 'width="304.0" height="162.6"' in svg


def test_fallback_svg_escapes_untrusted_text(project: DiagramProject) -> None:
    project.nodes[0].label = '<script>alert("x")</script>'
    svg = render_fallback_svg(project)
    assert "<script>" not in svg
    assert "&lt;script&gt;" in svg


@pytest.mark.skipif(not shutil.which("dot"), reason="Graphviz dot is not installed")
def test_graphviz_layout_returns_parseable_svg(project: DiagramProject) -> None:
    svg, engine = render_svg(project)
    assert engine == "dot"
    assert ElementTree.fromstring(svg).tag.endswith("svg")
    assert "WAF" in svg


def test_rgba_node_style_exports_transparency(project: DiagramProject) -> None:
    project.nodes[0].style.fill = "#12345680"
    project.nodes[0].style.stroke = "#ABCDEF40"
    root = ElementTree.fromstring(render_svg(project)[0])
    group = next(item for item in root.iter() if item.get("data-node") == project.nodes[0].id)
    path = next(item for item in group if item.tag.endswith("path") and item.get("fill") != "none")
    assert path.get("fill") == "#123456"
    assert float(path.get("fill-opacity", "1")) == pytest.approx(128/255, abs=0.001)
    assert path.get("stroke") == "#ABCDEF"
    assert float(path.get("stroke-opacity", "1")) == pytest.approx(64/255, abs=0.001)


def test_empty_container_exports_with_stored_geometry() -> None:
    project = DiagramProject.model_validate({
        "containers": [{"id": "empty", "label": "Пустая зона", "x": 2.5, "y": 1.5, "width": 3, "height": 2}],
    })
    svg, _ = render_svg(project)
    root = ElementTree.fromstring(svg)
    assert any(item.tag.endswith("rect") and item.get("fill") == "#F1F5F9" for item in root.iter())
    assert any(item.tag.endswith("text") and item.text == "Пустая зона" for item in root.iter())


def test_svg_paints_nodes_by_z_index_and_keeps_stable_order_for_ties(project: DiagramProject) -> None:
    project.nodes[0].z_index = 2
    project.nodes[1].z_index = -1
    root = ElementTree.fromstring(render_svg(project)[0])
    painted_ids = [item.get("data-node") for item in root.iter() if item.tag.endswith("g") and item.get("data-node")]
    expected = [node.id for _, node in sorted(enumerate(project.nodes), key=lambda pair: (pair[1].z_index, pair[0]))]
    assert painted_ids == expected


@pytest.mark.skipif(not shutil.which("dot"), reason="Graphviz dot is not installed")
def test_graphviz_png_export_respects_scale_and_background(project: DiagramProject) -> None:
    png_1x, engine = render_png(project, scale=1, background="#FFFFFF")
    png_2x, _ = render_png(project, scale=2, background="transparent")
    assert engine == "dot"
    assert png_1x.startswith(b"\x89PNG\r\n\x1a\n")
    assert png_2x.startswith(b"\x89PNG\r\n\x1a\n")
    assert png_2x[25] == 6
    width_1x, height_1x = int.from_bytes(png_1x[16:20], "big"), int.from_bytes(png_1x[20:24], "big")
    width_2x, height_2x = int.from_bytes(png_2x[16:20], "big"), int.from_bytes(png_2x[20:24], "big")
    assert abs(width_2x - 2 * width_1x) <= 1
    assert abs(height_2x - 2 * height_1x) <= 1


def test_png_export_rejects_invalid_scale_and_background(project: DiagramProject) -> None:
    with pytest.raises(LayoutError, match="Масштаб PNG"):
        render_png(project, scale=5)
    with pytest.raises(LayoutError, match="Фон PNG"):
        render_png(project, background="url(unsafe)")
