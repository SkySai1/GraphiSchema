"""Graphviz adapter and deterministic SVG fallback for local previews."""

from __future__ import annotations

import html
import re
import shutil
import subprocess
from collections import defaultdict, deque

from .dot import to_dot
from .models import DiagramNode, DiagramProject


class LayoutError(RuntimeError):
    pass


def render_svg(project: DiagramProject, timeout: float = 8.0) -> tuple[str, str]:
    """Return (svg, engine). Graphviz is preferred; fallback is local and deterministic."""
    engine = "neato" if project.diagram.layout_mode == "manual" else project.diagram.layout_engine
    binary = shutil.which(engine)
    if binary:
        command = [binary]
        if project.diagram.layout_mode == "manual":
            command.append("-n2")
        command.append("-Tsvg")
        try:
            result = subprocess.run(
                command, input=to_dot(project), text=True,
                capture_output=True, check=False, timeout=timeout,
            )
        except subprocess.TimeoutExpired as exc:
            raise LayoutError("Graphviz превысил время ожидания.") from exc
        if result.returncode != 0:
            detail = result.stderr.strip()[-1000:]
            raise LayoutError(f"Graphviz не смог построить диаграмму: {detail}")
        return result.stdout, engine
    return render_fallback_svg(project), "fallback"


def render_png(project: DiagramProject, scale: float = 1.0, background: str = "#FFFFFF", timeout: float = 20.0) -> tuple[bytes, str]:
    """Render a PNG through Graphviz using a caller-selected resolution and background."""
    if not 0.5 <= scale <= 4:
        raise LayoutError("Масштаб PNG должен быть от 0.5 до 4.")
    if background != "transparent" and not re.fullmatch(r"#[0-9a-fA-F]{6}", background):
        raise LayoutError("Фон PNG должен быть transparent или цветом #RRGGBB.")
    engine = "neato" if project.diagram.layout_mode == "manual" else project.diagram.layout_engine
    binary = shutil.which(engine)
    if not binary:
        raise LayoutError("Для экспорта PNG требуется установленный Graphviz.")

    command = [binary]
    if project.diagram.layout_mode == "manual":
        command.append("-n2")
    command.extend([f"-Gdpi={96 * scale:g}", f"-Gbgcolor={background}", "-Tpng"])
    try:
        result = subprocess.run(
            command,
            input=to_dot(project).encode("utf-8"),
            capture_output=True,
            check=False,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        raise LayoutError("Graphviz превысил время ожидания экспорта PNG.") from exc
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()[-1000:]
        raise LayoutError(f"Graphviz не смог экспортировать PNG: {detail}")
    return result.stdout, engine


def _ranks(project: DiagramProject) -> dict[str, int]:
    """Stable longest-path ranks; cycles are placed in a final stable rank."""
    order = {node.id: index for index, node in enumerate(project.nodes)}
    incoming: dict[str, int] = {node.id: 0 for node in project.nodes}
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
    return ranks


def render_fallback_svg(project: DiagramProject) -> str:
    """Render a readable small diagram without external binaries or network access."""
    nodes = project.nodes
    by_id = {node.id: node for node in nodes}
    rank = _ranks(project)
    rankdir = project.diagram.direction
    horizontal = rankdir in {"LR", "RL"}
    reverse_rank = rankdir in {"RL", "BT"}
    max_rank = max(rank.values(), default=0)
    buckets: dict[int, list[DiagramNode]] = defaultdict(list)
    for node in nodes:
        buckets[rank[node.id]].append(node)
    positions: dict[str, tuple[float, float]] = {}
    card_sizes = {
        node.id: (
            (node.width / 2.5 * 190.0) if node.width is not None else 190.0,
            (node.height / 0.62 * 84.0) if node.height is not None else 84.0,
        )
        for node in nodes
    }
    margin = 44.0
    rank_widths = {key: max((card_sizes[node.id][0] for node in items), default=190.0) for key, items in buckets.items()}
    rank_heights = {key: max((card_sizes[node.id][1] for node in items), default=84.0) for key, items in buckets.items()}
    rank_offsets: dict[int, float] = {}
    cursor = margin
    for rank_value in range(max_rank + 1):
        rank_offsets[rank_value] = cursor
        cursor += (rank_widths.get(rank_value, 190.0) if horizontal else rank_heights.get(rank_value, 84.0)) + 46.0
    for rank_value in sorted(buckets):
        column = sorted(buckets[rank_value], key=lambda node: nodes.index(node))
        rank_slot = max_rank - rank_value if reverse_rank else rank_value
        stack_offset = margin
        for node in column:
            card_w, card_h = card_sizes[node.id]
            if horizontal:
                positions[node.id] = (rank_offsets[rank_slot], stack_offset)
                stack_offset += card_h + 46.0
            else:
                positions[node.id] = (stack_offset, rank_offsets[max_rank - rank_slot])
                stack_offset += card_w + 46.0

    if positions:
        max_x = max(x + card_sizes[node_id][0] for node_id, (x, _) in positions.items()) + margin
        max_y = max(y + card_sizes[node_id][1] for node_id, (_, y) in positions.items()) + margin
    else:
        max_x, max_y = 480.0, 250.0

    background = project.presentation.background
    text_muted = "#94A3B8" if project.presentation.theme == "dark" else "#64748B"
    output = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {max_x:.0f} {max_y:.0f}" role="img" aria-label="{html.escape(project.project.title, quote=True)}">',
        '<defs>',
        *[
            f'<marker id="arrow-{edge.id}" markerWidth="9" markerHeight="9" refX="8" refY="4.5" orient="auto"><path d="M0,0 L9,4.5 L0,9 z" fill="{edge.style.color}"/></marker>'
            for edge in project.edges
        ],
        '</defs>',
        f'<rect width="100%" height="100%" fill="{background}"/>',
    ]

    descendants: dict[str, set[str]] = {container.id: set() for container in project.containers}
    for node in nodes:
        current = node.container_id
        while current:
            descendants[current].add(node.id)
            parent = next((item.parent_id for item in project.containers if item.id == current), None)
            current = parent
    container_depth = {container.id: _container_depth(container.id, project) for container in project.containers}
    for container in sorted(project.containers, key=lambda item: container_depth[item.id]):
        contained = [positions[node_id] for node_id in descendants[container.id] if node_id in positions]
        if not contained:
            continue
        left = min(x for x, _ in contained) - 22
        top = min(y for _, y in contained) - 34
        right = max(positions[node_id][0] + card_sizes[node_id][0] for node_id in descendants[container.id] if node_id in positions) + 22
        bottom = max(positions[node_id][1] + card_sizes[node_id][1] for node_id in descendants[container.id] if node_id in positions) + 22
        style = container.style
        output.append(f'<rect x="{left:.1f}" y="{top:.1f}" width="{right-left:.1f}" height="{bottom-top:.1f}" rx="12" fill="{style.fill}" stroke="{style.stroke}" stroke-width="1.5"/>')
        output.append(f'<text x="{left+12:.1f}" y="{top+21:.1f}" fill="{style.text}" font-family="Arial,sans-serif" font-size="13" font-weight="700">{html.escape(container.label)}</text>')

    for edge in project.edges:
        source = by_id[edge.source]
        target = by_id[edge.target]
        sx, sy = positions[source.id]
        tx, ty = positions[target.id]
        source_w, source_h = card_sizes[source.id]
        target_w, target_h = card_sizes[target.id]
        sx += source_w / 2
        sy += source_h / 2
        tx += target_w / 2
        ty += target_h / 2
        color = edge.style.color
        dash = {"dashed": "8 6", "dotted": "2 6", "solid": "", "bold": ""}[edge.style.line_style]
        dash_attr = f' stroke-dasharray="{dash}"' if dash else ""
        marker_id = f"arrow-{edge.id}"
        marker = f' marker-end="url(#{marker_id})"' if edge.direction in {"forward", "both"} and edge.style.arrowhead != "none" else ""
        start = f' marker-start="url(#{marker_id})"' if edge.direction == "both" and edge.style.arrowtail != "none" else ""
        output.append(f'<path d="M {sx:.1f} {sy:.1f} L {tx:.1f} {ty:.1f}" fill="none" stroke="{color}" stroke-width="{edge.style.penwidth:.1f}"{dash_attr}{start}{marker}/>')
        if edge.label:
            mx, my = (sx + tx) / 2, (sy + ty) / 2 - 7
            output.append(f'<text x="{mx:.1f}" y="{my:.1f}" text-anchor="middle" fill="{text_muted}" font-family="Arial,sans-serif" font-size="11">{html.escape(edge.label)}</text>')

    for node in nodes:
        x, y = positions[node.id]
        card_w, card_h = card_sizes[node.id]
        style = node.style
        common = f'fill="{style.fill}" stroke="{style.stroke}" stroke-width="{style.penwidth:.1f}"'
        if node.shape == "ellipse":
            output.append(f'<ellipse cx="{x+card_w/2:.1f}" cy="{y+card_h/2:.1f}" rx="{card_w/2:.1f}" ry="{card_h/2:.1f}" {common}/>')
        elif node.shape == "diamond":
            points = f'{x+card_w/2:.1f},{y:.1f} {x+card_w:.1f},{y+card_h/2:.1f} {x+card_w/2:.1f},{y+card_h:.1f} {x:.1f},{y+card_h/2:.1f}'
            output.append(f'<polygon points="{points}" {common}/>')
        elif node.shape == "hexagon":
            points = f'{x+22:.1f},{y:.1f} {x+card_w-22:.1f},{y:.1f} {x+card_w:.1f},{y+card_h/2:.1f} {x+card_w-22:.1f},{y+card_h:.1f} {x+22:.1f},{y+card_h:.1f} {x:.1f},{y+card_h/2:.1f}'
            output.append(f'<polygon points="{points}" {common}/>')
        elif node.shape == "cylinder":
            output.append(f'<path d="M{x:.1f} {y+10:.1f} C{x:.1f} {y-4:.1f}, {x+card_w:.1f} {y-4:.1f}, {x+card_w:.1f} {y+10:.1f} L{x+card_w:.1f} {y+card_h-10:.1f} C{x+card_w:.1f} {y+card_h+4:.1f}, {x:.1f} {y+card_h+4:.1f}, {x:.1f} {y+card_h-10:.1f} Z" {common}/>')
            output.append(f'<path d="M{x:.1f} {y+10:.1f} C{x:.1f} {y+24:.1f}, {x+card_w:.1f} {y+24:.1f}, {x+card_w:.1f} {y+10:.1f}" fill="none" stroke="{style.stroke}" stroke-width="{style.penwidth:.1f}"/>')
        elif node.shape == "cloud":
            sx, sy = card_w / 190.0, card_h / 84.0
            output.append(f'<path d="M{x+30*sx:.1f} {y+67*sy:.1f} C{x+8*sx:.1f} {y+67*sy:.1f}, {x+8*sx:.1f} {y+42*sy:.1f}, {x+26*sx:.1f} {y+37*sy:.1f} C{x+25*sx:.1f} {y+13*sy:.1f}, {x+57*sx:.1f} {y+6*sy:.1f}, {x+73*sx:.1f} {y+23*sy:.1f} C{x+91*sx:.1f} {y+2*sy:.1f}, {x+132*sx:.1f} {y+11*sy:.1f}, {x+134*sx:.1f} {y+34*sy:.1f} C{x+165*sx:.1f} {y+27*sy:.1f}, {x+183*sx:.1f} {y+48*sy:.1f}, {x+162*sx:.1f} {y+67*sy:.1f} Z" {common}/>')
        else:
            output.append(f'<rect x="{x:.1f}" y="{y:.1f}" width="{card_w:.1f}" height="{card_h:.1f}" rx="10" {common}/>')
        output.append(f'<text x="{x+14:.1f}" y="{y+31:.1f}" fill="{style.text}" font-family="Arial,sans-serif" font-size="14" font-weight="700">{html.escape(node.label)}</text>')
        output.append(f'<text x="{x+14:.1f}" y="{y+55:.1f}" fill="{text_muted}" font-family="Arial,sans-serif" font-size="11">{html.escape(node.kind)}</text>')
    output.append("</svg>")
    return "\n".join(output)


def _container_depth(container_id: str, project: DiagramProject) -> int:
    containers = {item.id: item for item in project.containers}
    depth = 0
    current = containers[container_id].parent_id
    while current is not None:
        depth += 1
        current = containers[current].parent_id
    return depth
