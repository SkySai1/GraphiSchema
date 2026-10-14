#!/usr/bin/env python3
"""Observe exported path commands without calling arrow construction helpers.

The report records the actual shaft endpoint, the tip and the midpoint of the
marker's rear edge. It also saves real Graphviz layouts for native raster tests.
Run with: uv run python scripts/diagnose_arrows.py --output dist/arrow-debug/before
"""
from __future__ import annotations

import argparse
import csv
import json
import math
from pathlib import Path
import re
from xml.etree import ElementTree as ET

from graphischema.layout import compute_layout
from graphischema.models import DiagramProject, RoutePoint
from graphischema.scene_renderer import render_scene


def cases():
    relations = {
        "LR": (3, 0), "RL": (-3, 0), "up": (0, 3), "down": (0, -3),
        "NE": (3, 2), "NW": (-3, 2), "SE": (3, -2), "SW": (-3, -2),
    }
    shapes = ["box", "ellipse", "diamond", "hexagon"]
    for index, (relation, (dx, dy)) in enumerate(relations.items()):
        for routing in ("straight", "angled", "orthogonal", "curved"):
            yield f"manual-{relation}-{routing}", project(
                routing, "manual", "neato", "LR" if dx >= 0 else "RL",
                (4, 4), (4+dx, 4+dy), shapes[index % len(shapes)],
            )
    for engine in ("dot", "neato", "fdp", "sfdp", "twopi", "circo"):
        for direction in ("LR", "RL", "TB", "BT"):
            for routing in ("straight", "angled", "orthogonal", "curved"):
                yield f"auto-{engine}-{direction}-{routing}", project(routing, "auto", engine, direction)
    for routing in ("straight", "angled", "orthogonal", "curved"):
        value = project(routing, source=(1, 2), target=(4, 2))
        value.edges[0].waypoints = [RoutePoint(x=3.28, y=2.5), RoutePoint(x=3.28, y=2.04)]
        yield f"short-elbow-{routing}", value
        yield f"short-gap-{routing}", project(routing, source=(1, 2), target=(2.45, 2))
        value = project(routing)
        value.edges[0].source_port, value.edges[0].target_port = "n", "w"
        yield f"fixed-ports-{routing}", value
        value = project(routing, source=(1, 2), target=(2.45, 2))
        value.edges[0].source_port, value.edges[0].target_port = "e", "w"
        yield f"close-fixed-ports-{routing}", value
        value = project(routing, shape="diamond")
        value.edges[0].source_port, value.edges[0].target_port = "vertex:0", "vertex:2"
        yield f"vertices-{routing}", value
        value = project(routing)
        value.nodes[1].icon = "tabler-icons/outline/shield.svg"
        yield f"icon-{routing}", value
        value = project(routing)
        value.edges[0].target = value.edges[0].source
        yield f"self-loop-{routing}", value


def project(routing, mode="manual", engine="neato", direction="LR", source=(1, 2), target=(4, 3), shape="box"):
    return DiagramProject.model_validate({
        "diagram": {"layout_mode": mode, "layout_engine": engine, "direction": direction, "edge_routing": routing},
        "presentation": {"background": "#FFFFFF", "theme": "light"},
        "nodes": [
            {"id": ident, "label": ident, "x": x, "y": y, "shape": shape, "width": 1.4, "height": 1.2,
             "style": {"fill": "#FFFFFF", "stroke": "#00AA00", "penwidth": 1}}
            for ident, (x, y) in zip(("source", "target"), (source, target))
        ],
        "edges": [{"id": "link", "source": "source", "target": "target", "direction": "both",
                   "style": {"color": "#FF0000", "penwidth": 2, "arrowhead": "normal", "arrowtail": "normal"}}],
    })


def path_points(element):
    numbers = [float(v) for v in re.findall(r"[-+]?(?:\d*\.\d+|\d+)(?:[eE][-+]?\d+)?", element.get("d", ""))]
    return list(zip(numbers[::2], numbers[1::2]))


def observe(svg, case_name):
    root = ET.fromstring(svg)
    shaft = next(e for e in root.iter() if e.get("data-edge") == "link")
    points = path_points(shaft)
    markers = [e for e in root if e.tag.endswith("path") and e.get("fill") == "#FF0000"]
    rows = []
    for endpoint, marker in zip(("target", "source"), markers):
        polygon = path_points(marker)
        tip = polygon[0]
        rear = tuple((polygon[1][i]+polygon[2][i])/2 for i in (0, 1))
        approach = points if endpoint == "target" else points[::-1]
        join = next((e for e in root if e.get("data-arrow-join") == f"link:{endpoint}"), None)
        if join is not None:
            approach = [*approach, path_points(join)[-1]]
        end, previous = approach[-1], approach[-2]
        axis = (tip[0]-rear[0], tip[1]-rear[1])
        tangent = (end[0]-previous[0], end[1]-previous[1])
        norm = math.hypot(*axis)*math.hypot(*tangent)
        angle = math.degrees(math.acos(max(-1, min(1, sum(a*b for a, b in zip(axis, tangent))/norm)))) if norm > 1e-10 else 180
        length = math.hypot(*axis)
        unit = (axis[0]/length, axis[1]/length)
        crossing_error = None
        for a, b in zip(approach[::-1][1:], approach[::-1]):
            da = sum((a[i]-rear[i])*unit[i] for i in (0, 1))
            db = sum((b[i]-rear[i])*unit[i] for i in (0, 1))
            # SVG commands are rounded to four decimal places; retain their
            # known quantization error when intersecting the rear plane.
            if da <= .0002 and db >= -.0002 and db-da > 1e-9:
                t = max(0, min(1, -da/(db-da)))
                crossing = tuple(a[i]+t*(b[i]-a[i]) for i in (0, 1))
                crossing_error = math.dist(crossing, rear)
                break
        rows.append({"case": case_name, "endpoint": endpoint,
                     "shaft_x": end[0], "shaft_y": end[1], "tip_x": tip[0], "tip_y": tip[1],
                     "rear_x": rear[0], "rear_y": rear[1], "join_error_pt": math.dist(end, rear),
                     "join_angle_deg": angle, "rear_crossing_error_pt": crossing_error})
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("dist/arrow-debug/current"))
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    rows, fixtures, tiles = [], [], []
    for name, value in cases():
        layout = compute_layout(value)
        svg = render_scene(value, layout)
        measurements = observe(svg, name)
        rows.extend(measurements)
        fixtures.append({"name": name, "project": value.model_dump(mode="json"), "layout": layout,
                         "svg_measurements": measurements})
        (args.output / f"{name}.svg").write_text(svg)
        root = ET.fromstring(svg)
        width, height = (float(root.get(key).removesuffix("pt")) for key in ("width", "height"))
        tiles.append((name, width, height, "".join(ET.tostring(e, encoding="unicode") for e in root)))
    (args.output / "native-fixtures.json").write_text(json.dumps(fixtures, indent=2, ensure_ascii=False))
    with (args.output / "measurements.csv").open("w") as stream:
        writer = csv.DictWriter(stream, fieldnames=rows[0].keys())
        writer.writeheader()
        writer.writerows(rows)
    summary = {"cases": len(fixtures), "markers": len(rows),
               "engines": sorted({f["layout"]["engine"] for f in fixtures}),
               "modes": sorted({f["project"]["diagram"]["layout_mode"] for f in fixtures}),
               "max_join_error_pt": max(r["join_error_pt"] for r in rows),
               "max_join_angle_deg": max(r["join_angle_deg"] for r in rows),
               "failed_joins": sum(r["join_error_pt"] > .01 or r["join_angle_deg"] > .1 for r in rows),
               "side_entries": sum(r["rear_crossing_error_pt"] is not None and r["rear_crossing_error_pt"] > .1 for r in rows),
               "unreachable_rears": sum(r["rear_crossing_error_pt"] is None for r in rows),
               "max_rear_crossing_error_pt": max((r["rear_crossing_error_pt"] or 0) for r in rows)}
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2))
    # A contact sheet is produced from the actual SVG, rather than a simulated head.
    tile_width, tile_height, columns = 330, 250, 4
    board = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{tile_width*columns}" height="{tile_height*math.ceil(len(tiles)/columns)}">']
    for index, (name, width, height, content) in enumerate(tiles):
        x, y = (index % columns)*tile_width, (index // columns)*tile_height
        factor = min((tile_width-16)/width, (tile_height-35)/height)
        board.append(f'<g transform="translate({x+8},{y+8})"><text font-size="11" y="11">{name}</text><g transform="translate(0,22) scale({factor})">{content}</g></g>')
    (args.output / "overview.svg").write_text("\n".join(board+["</svg>"]))
    print(json.dumps(summary, ensure_ascii=False))


if __name__ == "__main__":
    main()
