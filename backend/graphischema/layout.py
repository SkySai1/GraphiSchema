"""Graphviz geometry adapter for the native canvas."""

from __future__ import annotations

import shlex
import shutil
import subprocess
from collections import defaultdict, deque

from .models import DiagramProject
from .geometry import normalize_edges


class LayoutError(RuntimeError):
    pass


def compute_layout(project: DiagramProject, timeout: float = 8.0) -> dict[str, object]:
    """Return normalized node and edge geometry in Graphviz inches."""
    engine = "neato" if project.diagram.layout_mode == "manual" else project.diagram.layout_engine
    if not project.nodes:
        return normalize_edges(project, _fallback_layout(project, engine=engine))
    binary = shutil.which(engine)
    if not binary:
        return normalize_edges(project, _fallback_layout(project, engine="fallback"))

    command = [binary]
    if project.diagram.layout_mode == "manual":
        command.append("-n2")
    command.append("-Tplain")
    from .dot import to_dot

    try:
        result = subprocess.run(
            command,
            input=to_dot(project, include_metadata=False),
            text=True,
            capture_output=True,
            check=False,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        raise LayoutError("Graphviz превысил время ожидания компоновки.") from exc
    if result.returncode != 0:
        raise LayoutError(f"Graphviz не смог рассчитать геометрию: {result.stderr.strip()[-1000:]}")
    return normalize_edges(project, _parse_plain(project, result.stdout, engine))


def _parse_plain(project: DiagramProject, source: str, engine: str) -> dict[str, object]:
    width = height = 0.0
    nodes: list[dict[str, object]] = []
    edge_ids: dict[tuple[str, str], deque[str]] = defaultdict(deque)
    for edge in project.edges:
        edge_ids[(edge.source, edge.target)].append(edge.id)
    edges: list[dict[str, object]] = []

    for raw_line in source.splitlines():
        if not raw_line.strip():
            continue
        try:
            tokens = shlex.split(raw_line)
        except ValueError as exc:
            raise LayoutError(f"Graphviz вернул некорректную геометрию: {raw_line[:200]}") from exc
        if not tokens:
            continue
        if tokens[0] == "graph" and len(tokens) >= 4:
            width, height = float(tokens[2]), float(tokens[3])
        elif tokens[0] == "node" and len(tokens) >= 9:
            nodes.append({
                "id": tokens[1],
                "x": float(tokens[2]),
                "y": float(tokens[3]),
                "width": float(tokens[4]),
                "height": float(tokens[5]),
            })
        elif tokens[0] == "edge" and len(tokens) >= 7:
            source_id, target_id = tokens[1], tokens[2]
            point_count = int(tokens[3])
            coordinate_end = 4 + point_count * 2
            if len(tokens) < coordinate_end:
                raise LayoutError("Graphviz вернул неполный маршрут связи.")
            values = [float(value) for value in tokens[4:coordinate_end]]
            points = [
                {"x": values[index], "y": values[index + 1]}
                for index in range(0, len(values), 2)
            ]
            tail = tokens[coordinate_end:]
            label = ""
            label_x = label_y = None
            if len(tail) >= 5:
                label = tail[0]
                label_x, label_y = float(tail[1]), float(tail[2])
            edge_id_queue = edge_ids[(source_id, target_id)]
            edge_id = edge_id_queue.popleft() if edge_id_queue else f"{source_id}_{target_id}"
            edges.append({
                "id": edge_id,
                "source": source_id,
                "target": target_id,
                "points": points,
                "label": label,
                "labelX": label_x,
                "labelY": label_y,
            })

    if width <= 0 or height <= 0:
        raise LayoutError("Graphviz не вернул размеры холста.")
    min_x = min_y = 0.0
    if project.diagram.layout_mode == "manual":
        min_x = min([0.0, *(node["x"] - node["width"] / 2 for node in nodes),
                     *(point["x"] for edge in edges for point in edge["points"])])
        min_y = min([0.0, *(node["y"] - node["height"] / 2 for node in nodes),
                     *(point["y"] for edge in edges for point in edge["points"])])
        max_x = max([width, *(node["x"] + node["width"] / 2 for node in nodes),
                     *(point["x"] for edge in edges for point in edge["points"])])
        max_y = max([height, *(node["y"] + node["height"] / 2 for node in nodes),
                     *(point["y"] for edge in edges for point in edge["points"])])
        width, height = max_x - min_x, max_y - min_y
    return {"engine": engine, "edgeRouting": project.diagram.edge_routing,
            "width": width, "height": height, "minX": min_x, "minY": min_y,
            "nodes": nodes, "edges": edges}


def _fallback_layout(project: DiagramProject, engine: str) -> dict[str, object]:
    order = {node.id: index for index, node in enumerate(project.nodes)}
    incoming = {node.id: 0 for node in project.nodes}
    outgoing: dict[str, list[str]] = defaultdict(list)
    for edge in project.edges:
        if edge.direction == "none" or not edge.style.constraint:
            continue
        outgoing[edge.source].append(edge.target)
        incoming[edge.target] += 1
    ready = deque(sorted((node_id for node_id, degree in incoming.items() if degree == 0), key=order.get))
    ranks = {node_id: 0 for node_id in incoming}
    visited: set[str] = set()
    while ready:
        current = ready.popleft()
        visited.add(current)
        for target in sorted(outgoing[current], key=order.get):
            ranks[target] = max(ranks[target], ranks[current] + 1)
            incoming[target] -= 1
            if incoming[target] == 0:
                ready.append(target)
    if len(visited) != len(project.nodes):
        last_rank = max(ranks.values(), default=0) + 1
        for node in project.nodes:
            if node.id not in visited:
                ranks[node.id] = last_rank

    horizontal = project.diagram.direction in {"LR", "RL"}
    reverse = project.diagram.direction in {"RL", "BT"}
    buckets: dict[int, list] = defaultdict(list)
    for node in project.nodes:
        buckets[ranks[node.id]].append(node)
    max_rank = max(ranks.values(), default=0)
    node_widths = {
        node.id: node.width or min(10, max(0.85, min(2.5, 0.16 + len(node.label) * 0.085) * node.style.font_size / 10))
        for node in project.nodes
    }
    node_heights = {node.id: node.height or max(0.62, node.style.font_size / 72 * 1.6) for node in project.nodes}
    positions: dict[str, tuple[float, float]] = {}
    rank_widths = {rank: max((node_widths[node.id] for node in bucket), default=0.85) for rank, bucket in buckets.items()}
    rank_heights = {rank: max((node_heights[node.id] for node in bucket), default=0.62) for rank, bucket in buckets.items()}
    rank_offsets: dict[int, float] = {}
    cursor = 0.65
    for rank in range(max_rank + 1):
        rank_offsets[rank] = cursor
        cursor += (rank_widths.get(rank, 0.85) if horizontal else rank_heights.get(rank, 0.62)) + 0.8
    for rank, bucket in buckets.items():
        slot = max_rank - rank if reverse else rank
        stack_offset = 0.65
        for node in bucket:
            node_width = node_widths[node.id]
            node_height = node_heights[node.id]
            if horizontal:
                x = rank_offsets[slot] + node_width / 2
                y = stack_offset + node_height / 2
            else:
                x = stack_offset + node_width / 2
                y = rank_offsets[max_rank - slot] + node_height / 2
            if project.diagram.layout_mode == "manual" and node.x is not None and node.y is not None:
                x, y = node.x, node.y
            positions[node.id] = (x, y)
            stack_offset += (node_height if horizontal else node_width) + 0.55

    if positions:
        width = max(x + node_widths[node_id] / 2 for node_id, (x, _) in positions.items()) + 0.65
        height = max(y + node_heights[node_id] / 2 for node_id, (_, y) in positions.items()) + 0.65
    else:
        width, height = 4.0, 2.5
    nodes = [
        {"id": node.id, "x": positions[node.id][0], "y": positions[node.id][1],
         "width": node_widths[node.id], "height": node_heights[node.id]}
        for node in project.nodes
    ]
    by_id = {node["id"]: node for node in nodes}
    edges = []
    for edge in project.edges:
        source = positions[edge.source]
        target = positions[edge.target]
        start = _clip_to_node(source, target, by_id[edge.source]["width"], by_id[edge.source]["height"])
        end = _clip_to_node(target, source, by_id[edge.target]["width"], by_id[edge.target]["height"])
        points = route_edge_points(start, end, project.diagram.edge_routing, horizontal)
        edges.append({
            "id": edge.id,
            "source": edge.source,
            "target": edge.target,
            "points": [{"x": x, "y": y} for x, y in points],
            "label": edge.label,
            "labelX": (start[0] + end[0]) / 2,
            "labelY": (start[1] + end[1]) / 2 + 0.18,
        })
    min_x = min([0.0, *(node["x"] - node["width"] / 2 for node in nodes),
                 *(point["x"] for edge in edges for point in edge["points"])])
    min_y = min([0.0, *(node["y"] - node["height"] / 2 for node in nodes),
                 *(point["y"] for edge in edges for point in edge["points"])])
    max_x = max([width, *(node["x"] + node["width"] / 2 for node in nodes),
                 *(point["x"] for edge in edges for point in edge["points"])])
    max_y = max([height, *(node["y"] + node["height"] / 2 for node in nodes),
                 *(point["y"] for edge in edges for point in edge["points"])])
    width, height = max_x - min_x, max_y - min_y
    return {"engine": engine, "edgeRouting": project.diagram.edge_routing,
            "width": width, "height": height, "minX": min_x, "minY": min_y,
            "nodes": nodes, "edges": edges}


def route_edge_points(
    start: tuple[float, float], end: tuple[float, float], routing: str, horizontal: bool
) -> list[tuple[float, float]]:
    """Route a provisional/fallback edge in the same coordinate space as its endpoints."""
    sx, sy = start
    tx, ty = end
    if routing == "orthogonal":
        if horizontal:
            bend = (sx + tx) / 2
            return [start, (bend, sy), (bend, ty), end]
        bend = (sy + ty) / 2
        return [start, (sx, bend), (tx, bend), end]
    if routing == "angled":
        bend = ((sx + tx) / 2, sy) if horizontal else (sx, (sy + ty) / 2)
        return [start, bend, end]
    return [start, end]


def _clip_to_node(center: tuple[float, float], other: tuple[float, float], width: float, height: float) -> tuple[float, float]:
    dx, dy = other[0] - center[0], other[1] - center[1]
    if dx == 0 and dy == 0:
        return center
    factor = min((width / 2) / abs(dx) if dx else float("inf"), (height / 2) / abs(dy) if dy else float("inf"))
    return center[0] + dx * factor, center[1] + dy * factor
