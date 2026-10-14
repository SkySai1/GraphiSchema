"""Shared icon outlines, attachment points and renderer-owned edge routing."""
from __future__ import annotations

import json
import math
from functools import lru_cache
from pathlib import Path


@lru_cache(maxsize=1)
def icon_library() -> dict:
    return json.loads((Path(__file__).parent / "resources/icon_geometry.json").read_text())


def icon_size(icon: str, extent: float = 1.1) -> tuple[float, float]:
    aspect = icon_library()[icon]["aspect_ratio"]
    width, height = (extent, extent/aspect) if aspect >= 1 else (extent*aspect, extent)
    factor = max(1, .5/min(width, height))
    return width*factor, height*factor


def normalized_paths(node) -> list[list[tuple[float, float]]]:
    if node.icon:
        return icon_library()[node.icon]["paths"]
    if node.shape in {"ellipse", "cloud"}:
        return [[(.5+.5*math.cos(i*math.tau/64), .5+.5*math.sin(i*math.tau/64)) for i in range(65)]]
    if node.shape == "cylinder":
        top = [(.5+.5*math.cos(i*math.pi/32), .88+.12*math.sin(i*math.pi/32)) for i in range(33)]
        bottom = [(.5+.5*math.cos(math.pi+i*math.pi/32), .12+.12*math.sin(math.pi+i*math.pi/32)) for i in range(33)]
        return [top+bottom+top[:1], [(.5+.5*math.cos(i*math.tau/64), .88+.12*math.sin(i*math.tau/64)) for i in range(65)]]
    vertices = {
        "diamond": [(0, .5), (.5, 0), (1, .5), (.5, 1)],
        "hexagon": [(0, .5), (.16, 0), (.84, 0), (1, .5), (.84, 1), (.16, 1)],
    }.get(node.shape, [(0, 0), (1, 0), (1, 1), (0, 1)])
    return [vertices + vertices[:1]]


def outline_paths(node, position) -> list[list[tuple[float, float]]]:
    return [[(position["x"]+(x-.5)*position["width"], position["y"]+(y-.5)*position["height"])
             for x, y in path] for path in normalized_paths(node)]


def vertices(node) -> list:
    if node.icon:
        return icon_library()[node.icon]["vertices"]
    path = normalized_paths(node)[0]
    return path[:-1] if node.shape not in {"ellipse", "cloud", "cylinder"} else [path[int(i*(len(path)-1)/8)] for i in range(8)]


def _nearest(point, a, b):
    dx, dy = b[0]-a[0], b[1]-a[1]
    length = dx*dx+dy*dy
    t = max(0, min(1, ((point[0]-a[0])*dx+(point[1]-a[1])*dy)/length)) if length else 0
    return a[0]+t*dx, a[1]+t*dy


def attachment(node, position, toward, port="auto") -> tuple[float, float]:
    paths = outline_paths(node, position)
    center = position["x"], position["y"]
    if port.startswith("vertex:"):
        x, y = vertices(node)[int(port.split(":")[1])]
        return center[0]+(x-.5)*position["width"], center[1]+(y-.5)*position["height"]
    directions = {"n": (0, 1), "ne": (1, 1), "e": (1, 0), "se": (1, -1),
                  "s": (0, -1), "sw": (-1, -1), "w": (-1, 0), "nw": (-1, 1)}
    if port in directions:
        dx, dy = directions[port]
        intersections = []
        for path in paths:
            for a, b in zip(path, path[1:]):
                sx, sy = b[0]-a[0], b[1]-a[1]
                denominator = dx*sy-dy*sx
                if abs(denominator) < 1e-10:
                    continue
                ax, ay = a[0]-center[0], a[1]-center[1]
                t, u = (ax*sy-ay*sx)/denominator, (ax*dy-ay*dx)/denominator
                if t >= 0 and 0 <= u <= 1:
                    intersections.append((t, (center[0]+t*dx, center[1]+t*dy)))
        if intersections:
            return max(intersections)[1]
        toward = center[0]+dx*position["width"]*2, center[1]+dy*position["height"]*2
    candidates = [_nearest(toward, a, b) for path in paths for a, b in zip(path, path[1:])]
    return min(candidates, key=lambda p: math.dist(p, toward)) if candidates else center


def route(start, end, routing, horizontal):
    if routing == "orthogonal":
        if horizontal:
            middle = (start[0]+end[0])/2
            return [start, (middle, start[1]), (middle, end[1]), end]
        middle = (start[1]+end[1])/2
        return [start, (start[0], middle), (end[0], middle), end]
    if routing == "angled":
        return [start, ((start[0]+end[0])/2, start[1]) if horizontal else (start[0], (start[1]+end[1])/2), end]
    if routing == "curved":
        dx, dy = end[0]-start[0], end[1]-start[1]
        offset = min(.55, max(.12, math.hypot(dx, dy)*.12))
        if horizontal:
            controls = (start, (start[0]+dx/3, start[1]+offset), (start[0]+2*dx/3, end[1]+offset), end)
        else:
            controls = (start, (start[0]+offset, start[1]+dy/3), (end[0]+offset, start[1]+2*dy/3), end)
        return sample_cubic(controls)
    return [start, end]


def sample_cubic(points, segments=24):
    p0, p1, p2, p3 = points
    return [
        ((1-t)**3*p0[0] + 3*(1-t)**2*t*p1[0] + 3*(1-t)*t*t*p2[0] + t**3*p3[0],
         (1-t)**3*p0[1] + 3*(1-t)**2*t*p1[1] + 3*(1-t)*t*t*p2[1] + t**3*p3[1])
        for t in (i/segments for i in range(segments+1))
    ]


def route_midpoint(points):
    lengths = [math.dist(a, b) for a, b in zip(points, points[1:])]
    remaining = sum(lengths)/2
    for index, length in enumerate(lengths):
        if remaining <= length and length > 0:
            a, b, t = points[index], points[index+1], remaining/length
            return a[0]+(b[0]-a[0])*t, a[1]+(b[1]-a[1])*t
        remaining -= length
    return points[0]


def normalize_edges(project, layout):
    """Place arrow tips on visible contours, including icon strokes and explicit ports.

    Graphviz plain ends at the arrow base. Never treat that base as the actual tip.
    Renderer routing also handles ports with ortho, which Graphviz itself ignores.
    """
    nodes = {n.id: n for n in project.nodes}
    positions = {n["id"]: n for n in layout["nodes"]}
    model_edges = {e.id: e for e in project.edges}
    horizontal = project.diagram.direction in {"LR", "RL"}
    for geometry in layout["edges"]:
        edge = model_edges[geometry["id"]]
        source, target = positions[edge.source], positions[edge.target]
        waypoints = [(p.x, p.y) for p in edge.waypoints]
        start = attachment(nodes[edge.source], source, waypoints[0] if waypoints else (target["x"], target["y"]), edge.source_port)
        end = attachment(nodes[edge.target], target, waypoints[-1] if waypoints else (source["x"], source["y"]), edge.target_port)
        routing = edge.routing or project.diagram.edge_routing
        if edge.source == edge.target and not waypoints:
            x, y, w, h = source["x"], source["y"], source["width"], source["height"]
            start = attachment(nodes[edge.source], source, (x+w, y), edge.source_port if edge.source_port != "auto" else "e")
            end = attachment(nodes[edge.target], target, (x, y+h), edge.target_port if edge.target_port != "auto" else "n")
            waypoints = [(x+w, y), (x+w, y+h), (x, y+h)]
        if waypoints:
            anchors = [start, *waypoints, end]
            points = [anchors[0]]
            for a, b in zip(anchors, anchors[1:]):
                points.extend(route(a, b, "orthogonal", horizontal)[1:] if routing == "orthogonal" else [b])
        elif routing == "curved" and edge.source_port == edge.target_port == "auto" and len(geometry["points"]) >= 4:
            old = [(p["x"], p["y"]) for p in geometry["points"]]
            start = attachment(nodes[edge.source], source, old[1])
            end = attachment(nodes[edge.target], target, old[-2])
            points = sample_cubic((start, old[1], old[-2], end))
        elif routing == "angled" and edge.routing is None and edge.source_port == edge.target_port == "auto":
            old = [(p["x"], p["y"]) for p in geometry["points"]]
            # Preserve Graphviz obstacle avoidance. Extend from the last control point to the contour.
            start = attachment(nodes[edge.source], source, old[1] if len(old) > 2 else (target["x"], target["y"]))
            end = attachment(nodes[edge.target], target, old[-2] if len(old) > 2 else (source["x"], source["y"]))
            points = [start, *old[1:-1], end]
        else:
            points = route(start, end, routing, horizontal)
        deduplicated = [points[0]]
        for point in points[1:]:
            if math.dist(point, deduplicated[-1]) > 1e-7:
                deduplicated.append(point)
        geometry["points"] = [{"x": x, "y": y} for x, y in deduplicated]
        middle = route_midpoint(deduplicated)
        if edge.waypoints or edge.routing or nodes[edge.source].icon or nodes[edge.target].icon or edge.source_port != "auto" or edge.target_port != "auto":
            geometry["labelX"], geometry["labelY"] = middle[0], middle[1]+.15
    all_points = [(p["x"], p["y"]) for e in layout["edges"] for p in e["points"]]
    if all_points:
        max_x = max(layout["minX"]+layout["width"], *(p[0] for p in all_points))
        max_y = max(layout["minY"]+layout["height"], *(p[1] for p in all_points))
        layout["minX"] = min(layout["minX"], *(p[0] for p in all_points))
        layout["minY"] = min(layout["minY"], *(p[1] for p in all_points))
        layout["width"], layout["height"] = max_x-layout["minX"], max_y-layout["minY"]
    containers = {item.id: item for item in project.containers}
    member_ids = {item.id: set() for item in project.containers}
    for node in project.nodes:
        parent = node.container_id
        while parent:
            member_ids[parent].add(node.id)
            parent = containers[parent].parent_id
    empty_bounds = []
    for container in project.containers:
        if member_ids[container.id]:
            continue
        cx = container.x if container.x is not None else layout["minX"] + 1.6
        cy = container.y if container.y is not None else layout["minY"] + 1.2
        empty_bounds.append((cx-container.width/2, cy-container.height/2, cx+container.width/2, cy+container.height/2))
    if empty_bounds:
        left = min(layout["minX"], *(box[0] for box in empty_bounds))
        bottom = min(layout["minY"], *(box[1] for box in empty_bounds))
        right = max(layout["minX"]+layout["width"], *(box[2] for box in empty_bounds))
        top = max(layout["minY"]+layout["height"], *(box[3] for box in empty_bounds))
        layout["minX"], layout["minY"] = left, bottom
        layout["width"], layout["height"] = right-left, top-bottom
    return layout
