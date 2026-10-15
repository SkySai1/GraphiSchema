"""Regression checks inspect actual SVG commands, independently of angle helpers."""
from copy import deepcopy
import importlib.util
import json
import math
from pathlib import Path
from xml.etree import ElementTree as ET

import pytest

from graphischema.arrows import arrow_drawing
from graphischema.geometry import normalize_edges
from graphischema.layout import compute_layout
from graphischema.scene_renderer import render_scene

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("arrow_observer", ROOT / "scripts/diagnose_arrows.py")
observer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(observer)
cases, observe, path_points, project = observer.cases, observer.observe, observer.path_points, observer.project
KNOWN = json.loads((ROOT / "native/Tests/GraphiSchemaTests/Fixtures/arrow_geometry.json").read_text())


@pytest.mark.parametrize("case", KNOWN, ids=lambda value: value["name"])
def test_known_coordinates_of_shaft_tip_and_rear(case):
    drawing = arrow_drawing(case["points"], case["head"], case["tail"], case["line_width"])
    assert drawing.shaft[0] == pytest.approx(case["expected_start"])
    assert drawing.shaft[-1] == pytest.approx(case["expected_end"])
    if case["expected_tip"] is None:
        assert drawing.head is None
    else:
        assert drawing.head.tip == pytest.approx(case["expected_tip"])


@pytest.mark.parametrize("name,value", list(cases()), ids=lambda value: value if isinstance(value, str) else None)
def test_graphviz_svg_shaft_joins_marker_rear_for_all_modes(name, value):
    layout = compute_layout(value)
    rows = observe(render_scene(value, layout), name)
    assert len(rows) == 2
    for row in rows:
        assert row["join_error_pt"] < .001, row
        assert row["join_angle_deg"] < .1, row
        assert row["rear_crossing_error_pt"] is not None, row
        assert row["rear_crossing_error_pt"] < .001, row
    assert all(edge["normalized"] for edge in layout["edges"])
    assert normalize_edges(value, deepcopy(layout)) == layout


@pytest.mark.parametrize("kind", ["normal", "diamond", "box", "dot", "tee", "vee", "crow", "none"])
@pytest.mark.parametrize("line_style", ["solid", "dashed", "dotted"])
def test_svg_actual_marker_shapes_and_dash_join(kind, line_style):
    value = project("curved")
    value.edges[0].style.arrowhead = value.edges[0].style.arrowtail = kind
    value.edges[0].style.line_style = line_style
    root = ET.fromstring(render_scene(value, compute_layout(value)))
    shaft = path_points(next(e for e in root if e.get("data-edge") == "link"))
    markers = [e for e in root if e.get("data-arrow")]
    joins = [e for e in root if e.get("data-arrow-join")]
    assert len(markers) == (0 if kind == "none" else 2)
    assert len(joins) == (len(markers) if line_style != "solid" else 0)
    for marker in markers:
        end = shaft[-1] if marker.get("data-arrow").endswith(":target") else shaft[0]
        join = next((e for e in joins if e.get("data-arrow-join") == marker.get("data-arrow")), None)
        if join is not None:
            assert path_points(join)[0] == pytest.approx(end, abs=.001)
            end = path_points(join)[-1]
            assert join.get("stroke-dasharray") is None
        if kind == "dot":
            centre = float(marker.get("cx")), float(marker.get("cy"))
            assert math.dist(end, centre) == pytest.approx(float(marker.get("r")), abs=.001)
        else:
            polygon = path_points(marker)
            if kind == "normal":
                rear = tuple((polygon[1][i]+polygon[2][i])/2 for i in (0, 1))
            elif kind == "diamond":
                rear = polygon[2]
            elif kind == "box":
                rear = tuple((polygon[1][i]+polygon[2][i])/2 for i in (0, 1))
            elif kind == "tee":
                rear = tuple((polygon[0][i]+polygon[1][i])/2 for i in (0, 1))
            else:
                rear = tuple((polygon[0][i]+polygon[2][i])/2 for i in (0, 1))
                stem = next(e for e in root if e.get("data-arrow-stem") == marker.get("data-arrow"))
                assert path_points(stem)[0] == pytest.approx(rear, abs=.001)
                assert path_points(stem)[-1] == pytest.approx(polygon[1], abs=.001)
            assert end == pytest.approx(rear, abs=.001)
    # Tips are painted after filled nodes, so outlines cannot hide them.
    if markers:
        assert list(root).index(markers[0]) > max(i for i, e in enumerate(root) if e.get("data-node"))


def test_observer_rejects_the_original_side_entry_regression():
    broken = '<svg><path data-edge="link" d="M 0 0 L 98 0 L 98 2 L 100 2"/><path fill="#FF0000" d="M 100 2 L 92 6 L 92 -2 Z"/></svg>'
    row = observe(broken, "original-short-elbow")[0]
    assert row["join_error_pt"] == 8
    assert row["rear_crossing_error_pt"] == 2


def test_multisegment_graphviz_curve_preserves_its_middle_joint():
    value = project("curved", source=(0, 0), target=(4, 0))
    layout = {"engine": "dot", "edgeRouting": "curved", "width": 5, "height": 3, "minX": -1, "minY": -1,
              "nodes": [{"id": node.id, "x": node.x, "y": node.y, "width": 1.4, "height": 1.2} for node in value.nodes],
              "edges": [{"id": "link", "source": "source", "target": "target", "label": "",
                         "points": [{"x": x, "y": y} for x, y in [(.7, 0), (1, 1), (1, 2), (2, 2), (3, 2), (3, 1), (3.3, 0)]]}]}
    geometry = normalize_edges(value, layout)["edges"][0]
    assert len(geometry["points"]) == 49
    assert geometry["points"][24] == {"x": 2, "y": 2}


@pytest.mark.parametrize("routing", ["straight", "angled", "orthogonal", "curved"])
@pytest.mark.parametrize("ports", [("n", "w"), ("e", "n"), ("s", "e"), ("w", "s")])
def test_fixed_ports_keep_exact_attachments_without_mandatory_quarter_inch_stubs(routing, ports):
    value = project(routing)
    value.edges[0].source_port, value.edges[0].target_port = ports
    layout = compute_layout(value)
    points = [(p["x"], p["y"]) for p in layout["edges"][0]["points"]]
    directions = {"n": (0, 1), "e": (1, 0), "s": (0, -1), "w": (-1, 0)}
    for node, port, tip in [(value.nodes[0], ports[0], points[0]), (value.nodes[1], ports[1], points[-1])]:
        dx, dy = directions[port]
        assert tip == pytest.approx((node.x+dx*.7, node.y+dy*.6))
    if routing == "straight":
        assert len(points) == 2  # The requested straight path starts at the port itself.
    elif routing == "angled":
        assert len(points) == 3
        assert points[1] == pytest.approx(((points[0][0]+points[-1][0])/2, points[0][1]))
    elif routing == "orthogonal":
        assert all(abs(a[0]-b[0])<1e-8 or abs(a[1]-b[1])<1e-8 for a,b in zip(points,points[1:]))
    for port, tip, outside in [(ports[0], points[0], points[1]), (ports[1], points[-1], points[-2])]:
        dx, dy = directions[port]
        if routing == "curved":
            vector = (outside[0]-tip[0], outside[1]-tip[1])
            length = math.hypot(*vector)
            assert length > 0
            assert (vector[0]*dx+vector[1]*dy)/length > .998
            assert length < .25 # Curvature starts at the port, without a rigid stub.
        elif routing == "orthogonal":
            assert (outside[0]-tip[0])*dx+(outside[1]-tip[1])*dy > 0
            # A complete Manhattan leg, rather than a fixed .25" inserted stub.
            assert math.dist(outside,tip) != pytest.approx(.25)


@pytest.mark.parametrize("routing", ["straight", "angled", "orthogonal", "curved"])
def test_fixed_ports_use_a_narrow_gap_without_reversing_the_shaft(routing):
    value = project(routing, source=(1, 2), target=(2.45, 2))
    value.edges[0].source_port, value.edges[0].target_port = "e", "w"
    geometry = compute_layout(value)["edges"][0]
    points = [(p["x"], p["y"]) for p in geometry["points"]]
    assert points[0] == pytest.approx((1.7,2))
    assert points[-1] == pytest.approx((1.75,2))
    assert all(1.7-1e-8<=x<=1.75+1e-8 and abs(y-2)<1e-8 for x,y in points)
    assert all(a[0]<b[0] for a,b in zip(points,points[1:]))
    drawing = arrow_drawing([(x*72, y*72) for x, y in points], "normal", "normal")
    assert drawing.tail.base[0] < drawing.head.base[0]
