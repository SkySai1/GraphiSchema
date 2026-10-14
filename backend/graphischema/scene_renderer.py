"""SVG scene built from the same normalized geometry and icon vectors as AppKit."""
import html

from .geometry import icon_library, normalized_paths
from .arrows import arrow_drawing


def render_scene(project, layout, background=None):
    pad = 28
    width, height = max(1, layout["width"]*72+pad*2), max(1, layout["height"]*72+pad*2+20)
    def point(x, y):
        return (x-layout["minX"])*72+pad, (layout["minY"]+layout["height"]-y)*72+pad
    def data(points, closed=False):
        return "M " + " L ".join(f"{x:.4f} {y:.4f}" for x, y in points) + (" Z" if closed else "")
    def color(value):
        value = value.upper()
        return (value[:7], int(value[7:9], 16)/255) if len(value) == 9 else (value, 1.0)
    dark = project.presentation.theme == "dark"
    canvas = background or ("#21172F" if dark else project.presentation.background)
    if background and background != "transparent":
        red, green, blue = (int(background[i:i+2], 16)/255 for i in (1, 3, 5))
        dark = .2126*red+.7152*green+.0722*blue < .5
    text = "#FFFFFF" if dark else "#172238"
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width:.4f}pt" height="{height:.4f}pt" viewBox="0 0 {width:.4f} {height:.4f}">']
    if canvas != "transparent":
        out.append(f'<rect width="100%" height="100%" fill="{canvas}"/>')
    positions = {n["id"]: n for n in layout["nodes"]}
    containers = {c.id: c for c in project.containers}
    members = {c.id: [] for c in project.containers}
    for node in project.nodes:
        current = node.container_id
        while current:
            members[current].append(positions[node.id])
            current = containers[current].parent_id
    def depth(container):
        current, result = container.parent_id, 0
        while current:
            result += 1
            current = containers[current].parent_id
        return result
    for c in sorted(project.containers, key=depth):
        group = members[c.id]
        if group:
            left = min(n["x"]-n["width"]/2 for n in group)-c.padding/72
            right = max(n["x"]+n["width"]/2 for n in group)+c.padding/72
            bottom = min(n["y"]-n["height"]/2 for n in group)-c.padding/72
            top = max(n["y"]+n["height"]/2 for n in group)+c.padding/72
        else:
            cx, cy = c.x if c.x is not None else layout["minX"]+1.6, c.y if c.y is not None else layout["minY"]+1.2
            left, right = cx-c.width/2, cx+c.width/2
            bottom, top = cy-c.height/2, cy+c.height/2
        x, y = point(left, top)
        fill, fill_alpha = color(c.style.fill); stroke, stroke_alpha = color(c.style.stroke); caption, text_alpha = color(c.style.text)
        out.append(f'<rect x="{x:.4f}" y="{y:.4f}" width="{(right-left)*72:.4f}" height="{(top-bottom)*72:.4f}" rx="11" fill="{fill}" fill-opacity="{.42*fill_alpha:.4f}" stroke="{stroke}" stroke-opacity="{stroke_alpha:.4f}" stroke-width="1.2"/>')
        out.append(f'<text x="{x+10:.4f}" y="{y+17:.4f}" fill="{caption}" fill-opacity="{text_alpha:.4f}" font-family="Arial,sans-serif" font-size="11">{html.escape(c.label)}</text>')
    edges = {e.id: e for e in project.edges}
    arrow_elements = []
    for g in layout["edges"]:
        edge = edges[g["id"]]
        points = [point(p["x"], p["y"]) for p in g["points"]]
        if len(points) < 2:
            continue
        style = edge.style
        drawing = arrow_drawing(points, style.arrowhead if edge.direction in {"forward", "both"} else "none",
                                style.arrowtail if edge.direction == "both" else "none", style.penwidth)
        dash = {"dashed": ' stroke-dasharray="6 4"', "dotted": ' stroke-dasharray="1.5 3"'}.get(style.line_style, "")
        edge_color, edge_alpha = color(style.color)
        shaft = drawing.shaft
        if dash:
            shaft = shaft[(1 if drawing.tail else 0):(-1 if drawing.head else None)]
        out.append(f'<path data-edge="{edge.id}" d="{data(shaft)}" fill="none" stroke="{edge_color}" stroke-opacity="{edge_alpha:.4f}" stroke-width="{style.penwidth}" stroke-linecap="round" stroke-linejoin="round"{dash}/>')
        for endpoint, marker in (("target", drawing.head), ("source", drawing.tail)):
            if marker is None:
                continue
            # A solid lead prevents dash phase from leaving a gap at the rear.
            if dash:
                out.append(f'<path data-arrow-join="{edge.id}:{endpoint}" d="{data([marker.guide, marker.base])}" fill="none" stroke="{edge_color}" stroke-opacity="{edge_alpha:.4f}" stroke-width="{style.penwidth}"/>')
            kind = marker.kind
            if kind == "dot":
                x, y = marker.point(3)
                arrow_elements.append(f'<circle data-arrow="{edge.id}:{endpoint}" cx="{x:.4f}" cy="{y:.4f}" r="{3*marker.scale:.4f}" fill="{edge_color}" fill-opacity="{edge_alpha:.4f}"/>')
            else:
                if kind in {"vee", "crow"}:
                    arrow_elements.append(f'<path data-arrow-stem="{edge.id}:{endpoint}" d="{data([marker.base, marker.tip])}" fill="none" stroke="{edge_color}" stroke-opacity="{edge_alpha:.4f}" stroke-width="{style.penwidth}"/>')
                closed = kind not in {"tee", "vee", "crow"}
                arrow_elements.append(f'<path data-arrow="{edge.id}:{endpoint}" d="{data(marker.polygon, closed)}" fill="{edge_color if closed else "none"}" fill-opacity="{edge_alpha:.4f}" stroke="{edge_color}" stroke-opacity="{edge_alpha:.4f}" stroke-width="{1.5*marker.scale:.4f}"/>')
        if edge.label:
            x, y = point(g["labelX"] or 0, g["labelY"] or 0)
            label_color, label_alpha = color(text)
            out.append(f'<text x="{x:.4f}" y="{y:.4f}" text-anchor="middle" fill="{label_color}" fill-opacity="{label_alpha:.4f}" font-family="Arial,sans-serif" font-size="10">{html.escape(edge.label)}</text>')
    # Keep equal-depth objects in their project order, while honoring the
    # editor's explicit paint order in both SVG and the native canvas.
    ordered_nodes = sorted(enumerate(project.nodes), key=lambda pair: (pair[1].z_index, pair[0]))
    for _, node in ordered_nodes:
        n = positions[node.id]
        paths = normalized_paths(node)
        closed = icon_library()[node.icon]["closed"] if node.icon else [True]+[False]*(len(paths)-1)
        out.append(f'<g data-node="{node.id}"' + (f' data-icon="{node.icon}"' if node.icon else "") + ">")
        fill, fill_alpha = color(node.style.fill); stroke, stroke_alpha = color(node.style.stroke)
        closed_indices = [i for i, value in enumerate(closed) if value]
        base_index = max(closed_indices, key=lambda i: _area(paths[i])) if closed_indices else None
        for path_index, (path, close) in enumerate(zip(paths, closed)):
            points = [point(n["x"]+(x-.5)*n["width"], n["y"]+(y-.5)*n["height"]) for x, y in path]
            fill_value = fill if close and path_index == base_index else "none"
            out.append(f'<path d="{data(points, close)}" fill="{fill_value}" fill-opacity="{fill_alpha:.4f}" stroke="{stroke}" stroke-opacity="{stroke_alpha:.4f}" stroke-width="{node.style.penwidth}" stroke-linecap="round" stroke-linejoin="round"/>')
        left_x = point(n["x"]-n["width"]/2, n["y"])[0]
        center_x, center_y = point(n["x"], n["y"])
        right_x = point(n["x"]+n["width"]/2, n["y"])[0]
        top_y = point(n["x"], n["y"]+n["height"]/2)[1]
        bottom_y = point(n["x"], n["y"]-n["height"]/2)[1]
        horizontal_alignment = node.label_alignment
        vertical_alignment = node.label_vertical_alignment
        x = {"left": left_x+7, "center": center_x, "right": right_x-7}[horizontal_alignment]
        y = {"top": top_y+13, "middle": center_y+4, "bottom": bottom_y-4}[vertical_alignment]
        text_anchor = {"left": "start", "center": "middle", "right": "end"}[horizontal_alignment]
        label_color = "#FFFFFF" if node.icon and dark and node.style.text[:7].upper() in {"#172238", "#0F172A"} else node.style.text
        label_color, label_alpha = color(label_color)
        out.append(f'<text x="{x:.4f}" y="{y:.4f}" text-anchor="{text_anchor}" fill="{label_color}" fill-opacity="{label_alpha:.4f}" font-family="Arial,sans-serif" font-size="11" font-weight="600">{html.escape(node.label)}</text></g>')
    out.extend(arrow_elements)
    out.append("</svg>")
    return "\n".join(out)


def _area(path):
    return abs(sum(a[0]*b[1]-b[0]*a[1] for a, b in zip(path, path[1:]+path[:1])))/2
