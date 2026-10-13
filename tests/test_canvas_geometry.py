from pathlib import Path
import math
import shutil
from xml.etree import ElementTree

import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError

from graphischema import api
from graphischema.dot import to_dot
from graphischema.dot_editor import apply_dot, DOTEditError
from graphischema.geometry import attachment, icon_library, outline_paths, vertices
from graphischema.layout import compute_layout
from graphischema.models import DiagramProject
from graphischema.rendering import render_svg, render_png
from graphischema.storage import ProjectStore

ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize("icon", sorted(icon_library()))
def test_collection_figures_keep_the_original_svg_proportions(icon):
    project = DiagramProject.model_validate({"nodes": [{"id": "figure", "label": "Figure", "icon": icon}]})
    node = project.nodes[0]
    assert node.width/node.height == pytest.approx(icon_library()[icon]["aspect_ratio"])
    assert .5 <= node.width <= 10 and .5 <= node.height <= 10


def icon_project():
    return DiagramProject.model_validate({
        "diagram": {"layout_mode": "manual"},
        "nodes": [
            {"id": "shield", "label": "Защита", "icon": "tabler-icons/outline/shield.svg", "x": 0, "y": 0},
            {"id": "server", "label": "Сервер", "icon": "tabler-icons/outline/server.svg", "x": 4, "y": 2},
        ],
        "edges": [{"id": "link", "source": "shield", "target": "server"}],
    })


def contour_distance(point, contours):
    from graphischema.geometry import _nearest
    return min(math.dist(point, _nearest(point, a, b)) for contour in contours for a, b in zip(contour, contour[1:]))


@pytest.mark.parametrize("routing", ["straight", "angled", "orthogonal"])
@pytest.mark.parametrize("ports", [("auto", "auto"), ("n", "w"), ("vertex:0", "vertex:2")])
@pytest.mark.parametrize("engine", ["dot", "neato", "fdp", "sfdp", "twopi", "circo"])
def test_arrow_tips_touch_actual_icon_contours(routing, ports, engine):
    project = icon_project()
    edge = project.edges[0]
    edge.routing = routing
    edge.source_port, edge.target_port = ports
    project.diagram.layout_mode = "auto"
    project.diagram.layout_engine = engine
    layout = compute_layout(project)
    positions = {n["id"]: n for n in layout["nodes"]}
    points = [(p["x"], p["y"]) for p in layout["edges"][0]["points"]]
    assert len(points) >= 2
    assert contour_distance(points[0], outline_paths(project.nodes[0], positions["shield"])) < 1e-6
    assert contour_distance(points[-1], outline_paths(project.nodes[1], positions["server"])) < 1e-6
    if routing == "orthogonal":
        assert all(abs(a[0]-b[0]) < 1e-8 or abs(a[1]-b[1]) < 1e-8 for a, b in zip(points, points[1:]))
    for node, port, point in zip(project.nodes, ports, [points[0], points[-1]]):
        if port.startswith("vertex:"):
            x, y = vertices(node)[int(port.split(":")[1])]
            pos = positions[node.id]
            assert point == pytest.approx((pos["x"]+(x-.5)*pos["width"], pos["y"]+(y-.5)*pos["height"]))


def test_auto_attachment_uses_shortest_distance_to_contour():
    project = icon_project()
    pos = {"x": 0, "y": 0, "width": 1.1, "height": 1.1}
    toward = 4, 2
    point = attachment(project.nodes[0], pos, toward)
    assert math.dist(point, toward) == pytest.approx(contour_distance(toward, outline_paths(project.nodes[0], pos)))


@pytest.mark.parametrize("shape", ["box", "ellipse", "diamond", "hexagon", "cylinder", "cloud"])
def test_graphviz_arrow_base_is_extended_to_visible_shape(shape):
    project = icon_project()
    for node in project.nodes:
        node.icon = None
        node.shape = shape
    project.diagram.layout_mode = "auto"
    layout = compute_layout(project)
    by_id = {n["id"]: n for n in layout["nodes"]}
    edge = layout["edges"][0]
    for node, point in zip(project.nodes, [edge["points"][0], edge["points"][-1]]):
        assert contour_distance((point["x"], point["y"]), outline_paths(node, by_id[node.id])) < 1e-6


def test_waypoints_and_figure_roundtrip_dot_json_and_versions(tmp_path, monkeypatch):
    project = icon_project()
    data = project.model_dump()
    data["edges"][0].update(source_port="vertex:0", target_port="n", routing="orthogonal", waypoints=[{"x": 2, "y": 3}, {"x": 3, "y": 3}])
    project = DiagramProject.model_validate(data)
    candidate, changes = apply_dot(project, to_dot(project))
    assert candidate == project
    assert not any(changes.values())
    layout = compute_layout(project)
    points = [(p["x"], p["y"]) for p in layout["edges"][0]["points"]]
    assert (2, 3) in points and (3, 3) in points
    store = ProjectStore(tmp_path, ROOT / "examples/starter.json")
    monkeypatch.setattr(api, "STORE", store)
    monkeypatch.setattr(api, "CONTROLLER", api.ApplicationController(store))
    with TestClient(api.app) as client:
        original = client.get("/api/diagram").json()
        saved = client.put("/api/diagram", headers={"If-Match": original["revision"]}, json=project.model_dump(mode="json"))
        assert saved.status_code == 200, saved.text
        version = client.get("/api/versions").json()["versions"][0]
        changed = project.model_copy(deep=True)
        changed.edges[0].waypoints = []
        changed.nodes[0].icon = "tabler-icons/outline/cloud.svg"
        changed.edges[0].source_port = "auto"
        modified = client.put("/api/diagram", headers={"If-Match": saved.json()["revision"]}, json=changed.model_dump(mode="json"))
        assert modified.status_code == 200, modified.text
        restored = client.post(f"/api/versions/{version['id']}/restore", headers={"If-Match": modified.json()["revision"]})
        assert restored.status_code == 200, restored.text
        assert DiagramProject.model_validate(restored.json()["diagram"]) == project


def test_svg_and_png_include_collection_vectors_and_night_theme():
    project = icon_project()
    project.presentation.theme = "dark"
    svg, _ = render_svg(project)
    root = ElementTree.fromstring(svg)
    icons = [element for element in root.iter() if element.get("data-icon")]
    assert len(icons) == 2
    assert len([e for e in icons[0] if e.tag.endswith("path")]) == len(icon_library()[project.nodes[0].icon]["paths"])
    assert '#21172F' in svg and 'fill="#FFFFFF"' in svg
    assert "<image" not in svg  # self-contained SVG, no file paths or external URLs
    if shutil.which("rsvg-convert"):
        png, _ = render_png(project, background="transparent")
        assert png[:8] == b"\x89PNG\r\n\x1a\n" and png[25] == 6


def test_night_svg_uses_the_same_purple_canvas_as_appkit():
    project = icon_project()
    project.presentation.theme = "dark"
    project.presentation.background = "#F5F7FA"
    svg, _ = render_svg(project)
    assert '<rect width="100%" height="100%" fill="#21172F"/>' in svg


@pytest.mark.parametrize("theme", ["light", "dark"])
def test_explicit_figure_label_color_is_preserved_in_export(theme):
    project = icon_project()
    project.presentation.theme = theme
    project.nodes[0].style.text = "#FF9933"
    root = ElementTree.fromstring(render_svg(project)[0])
    group = next(e for e in root.iter() if e.get("data-node") == "shield")
    text = next(e for e in group if e.tag.endswith("text"))
    assert text.get("fill") == "#FF9933"


@pytest.mark.parametrize("routing", ["straight", "angled", "orthogonal"])
def test_connection_label_tracks_the_middle_of_the_actual_route(routing):
    from graphischema.geometry import route_midpoint
    project = icon_project()
    project.edges[0].routing = routing
    project.edges[0].label = "HTTPS"
    geometry = compute_layout(project)["edges"][0]
    points = [(p["x"], p["y"]) for p in geometry["points"]]
    middle = route_midpoint(points)
    assert geometry["labelX"] == pytest.approx(middle[0])
    assert geometry["labelY"] == pytest.approx(middle[1]+.15)


@pytest.mark.parametrize("value", ["../secret.svg", "https://host/icon.svg", "missing.svg"])
def test_figure_reference_cannot_read_arbitrary_files(value):
    data = icon_project().model_dump()
    data["nodes"][0]["icon"] = value
    with pytest.raises(ValidationError):
        DiagramProject.model_validate(data)


@pytest.mark.parametrize("port", ["vertex:999", "vertex:-1", "center", "north"])
def test_invalid_attachments_are_rejected_atomically(port):
    project = icon_project()
    data = project.model_dump()
    data["edges"][0]["source_port"] = port
    with pytest.raises(ValidationError):
        DiagramProject.model_validate(data)
    assert project.edges[0].source_port == "auto"


def test_self_loop_and_parallel_edges_keep_stable_ids():
    data = icon_project().model_dump()
    data["edges"].extend([{ "id": "parallel", "source": "shield", "target": "server", "source_port": "e"},
                           {"id": "self_loop", "source": "shield", "target": "shield"}])
    layout = compute_layout(DiagramProject.model_validate(data))
    assert {e["id"] for e in layout["edges"]} == {"link", "parallel", "self_loop"}
    assert len(next(e for e in layout["edges"] if e["id"] == "self_loop")["points"]) >= 4


def test_conflicting_dot_ports_are_not_silently_ignored():
    project = icon_project()
    project.edges[0].source_port = "vertex:0"
    source = to_dot(project).replace('gs_source_port="vertex:0"', 'gs_source_port="vertex:0", tailport="e"')
    with pytest.raises(DOTEditError, match="одну привязку"):
        apply_dot(project, source)
