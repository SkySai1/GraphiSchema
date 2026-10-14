"""Stable conversion from the canonical model to Graphviz DOT."""

from __future__ import annotations
import json

from .models import DiagramContainer, DiagramNode, DiagramProject
from .container_layout import FONT_SIZE as CONTAINER_FONT_SIZE


def quote(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
    return f'"{escaped}"'


def _node_statement(node: DiagramNode, manual_layout: bool) -> str:
    attrs = {
        "label": quote(node.label),
        "shape": quote(node.shape),
        "style": quote("filled,rounded" + ("," + node.style.line_style if node.style.line_style != "solid" else "")),
        "fillcolor": quote(node.style.fill),
        "color": quote(node.style.stroke),
        "fontcolor": quote(node.style.text),
        "fontsize": str(node.style.font_size),
        "penwidth": str(node.style.penwidth),
        "tooltip": quote(node.description or node.kind),
        "gs_label_alignment": quote(node.label_alignment),
        "gs_label_vertical_alignment": quote(node.label_vertical_alignment),
        "gs_label_wrap": "true" if node.label_wrap else "false",
    }
    if node.icon:
        attrs["gs_icon"] = quote(node.icon)
    if node.width is not None and node.height is not None:
        attrs["fixedsize"] = "true"
        attrs["width"] = str(node.width)
        attrs["height"] = str(node.height)
    if manual_layout and node.x is not None and node.y is not None:
        attrs["pos"] = quote(f"{node.x * 72:.4f},{node.y * 72:.4f}!")
    rendered = ", ".join(f"{key}={value}" for key, value in attrs.items())
    return f"    {quote(node.id)} [{rendered}];"


def _container_open(container: DiagramContainer, depth: int) -> list[str]:
    indent = "    " * depth
    attrs = {
        "label": quote(container.label),
        "style": quote("rounded,filled"),
        "color": quote(container.style.stroke),
        "fillcolor": quote(container.style.fill),
        "fontcolor": quote(container.style.text),
        "fontname": quote("Arial"),
        "fontsize": str(CONTAINER_FONT_SIZE),
        "labeljust": quote("l"),
        "penwidth": str(container.style.penwidth),
        # Graphviz expresses cluster margins in inches while the model stores points.
        "margin": f"{container.padding / 72:.12f}",
    }
    if container.x is not None and container.y is not None:
        attrs.update({"gs_x": str(container.x), "gs_y": str(container.y),
                      "gs_width": str(container.width), "gs_height": str(container.height)})
    rendered = ", ".join(f"{key}={value}" for key, value in attrs.items())
    return [f"{indent}subgraph {quote('cluster_' + container.id)} {{", f"{indent}    graph [{rendered}];"]


def to_dot(project: DiagramProject) -> str:
    """Generate valid, deterministic DOT from a validated project."""
    graph_name = "GraphiSchema"
    lines = [f"digraph {graph_name} {{"]
    graph_attrs = [
        f"rankdir={quote(project.diagram.direction)}",
        f"splines={quote({'straight': 'line', 'angled': 'polyline', 'orthogonal': 'ortho', 'curved': 'curved'}[project.diagram.edge_routing])}",
        f"bgcolor={quote(project.presentation.background)}",
        f"nodesep={project.diagram.node_spacing}",
        f"ranksep={project.diagram.rank_spacing}",
        "compound=true",
        "pad=0.25",
    ]
    if project.diagram.layout_mode == "manual":
        graph_attrs.append("notranslate=true")
    lines.append("    graph [" + ", ".join(graph_attrs) + "];")
    lines.append('    node [fontname="Arial", fontsize=10, margin="0.16,0.1"];')
    lines.append('    edge [fontname="Arial", fontsize=9];')
    manual_layout = project.diagram.layout_mode == "manual"

    nodes_by_container: dict[str | None, list[DiagramNode]] = {}
    for node in project.nodes:
        nodes_by_container.setdefault(node.container_id, []).append(node)
    containers_by_parent: dict[str | None, list[DiagramContainer]] = {}
    for container in project.containers:
        containers_by_parent.setdefault(container.parent_id, []).append(container)

    def emit_contents(parent_id: str | None, depth: int) -> None:
        for node in nodes_by_container.get(parent_id, []):
            lines.append("    " * depth + _node_statement(node, manual_layout).strip())
        for container in containers_by_parent.get(parent_id, []):
            lines.extend(_container_open(container, depth))
            emit_contents(container.id, depth + 1)
            lines.append("    " * depth + "}")

    emit_contents(None, 1)
    for edge in project.edges:
        style = edge.style
        direction = {"forward": "forward", "both": "both", "none": "none"}[edge.direction]
        attrs = {
            "label": quote(edge.label),
            "color": quote(style.color),
            "style": quote(style.line_style),
            "penwidth": str(style.penwidth),
            "arrowhead": quote(style.arrowhead),
            "arrowtail": quote(style.arrowtail),
            "dir": quote(direction),
            "constraint": "true" if style.constraint else "false",
            "weight": str(style.weight),
            "minlen": str(style.minlen),
            "gs_label_background_transparent": "true" if style.label_background_transparent else "false",
        }
        for key, port in (("tailport", edge.source_port), ("headport", edge.target_port)):
            if port in {"n", "ne", "e", "se", "s", "sw", "w", "nw"}:
                attrs[key] = quote(port)
        if style.text is not None:
            attrs["fontcolor"] = quote(style.text)
        if edge.source_port.startswith("vertex:"):
            attrs["gs_source_port"] = quote(edge.source_port)
        if edge.target_port.startswith("vertex:"):
            attrs["gs_target_port"] = quote(edge.target_port)
        if edge.routing:
            attrs["gs_routing"] = quote(edge.routing)
        if edge.waypoints:
            attrs["gs_waypoints"] = quote(json.dumps([p.model_dump() for p in edge.waypoints], separators=(",", ":")))
        rendered = ", ".join(f"{key}={value}" for key, value in attrs.items())
        lines.append(f"    {quote(edge.source)} -> {quote(edge.target)} [{rendered}];")
    lines.append("}")
    return "\n".join(lines) + "\n"
