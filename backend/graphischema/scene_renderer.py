"""SVG scene built from the same normalized geometry and icon vectors as AppKit."""
import html

from .geometry import icon_library, normalized_paths
from .arrows import arrow_drawing
from .text_layout import elide_text, estimated_text_width, label_lines
from .container_layout import FONT_SIZE, LABEL_HEIGHT, LABEL_INSET_X, LABEL_INSET_TOP, container_rects


def _node_border_dash(style):
    # Match NodeStyle.borderDashPattern in AppKit. Keep the old 1.5 pt appearance;
    # scaling the gaps too prevents round caps from joining at large pen widths.
    base = {"dashed": (6, 4), "dotted": (1.5, 3)}.get(style.line_style)
    if base is None:
        return ""
    lengths = " ".join(f"{length*style.penwidth/1.5:.12g}" for length in base)
    return f' stroke-dasharray="{lengths}"'


def render_scene(project, layout, background=None):
    from .colors import resolved_project
    project = resolved_project(project)
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
    default_canvas = "#21172F" if dark and project.presentation.background.upper() == "#FFFFFF" else project.presentation.background
    canvas = background or default_canvas
    if background and background != "transparent":
        red, green, blue = (int(background[i:i+2], 16)/255 for i in (1, 3, 5))
        dark = .2126*red+.7152*green+.0722*blue < .5
    text = "#FFFFFF" if dark else "#172238"
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width:.4f}pt" height="{height:.4f}pt" viewBox="0 0 {width:.4f} {height:.4f}">']
    if canvas != "transparent":
        canvas_color, canvas_alpha = color(canvas)
        out.append(f'<rect width="100%" height="100%" fill="{canvas_color}" fill-opacity="{canvas_alpha:.4f}"/>')
    positions = {n["id"]: n for n in layout["nodes"]}
    containers = {c.id: c for c in project.containers}
    container_bounds = container_rects(project, layout)
    def depth(container):
        current, result = container.parent_id, 0
        while current:
            result += 1
            current = containers[current].parent_id
        return result
    for c in sorted(project.containers, key=depth):
        left, bottom, right, top = container_bounds[c.id]
        x, y = point(left, top)
        fill, fill_alpha = color(c.style.fill); stroke, stroke_alpha = color(c.style.stroke); caption, text_alpha = color(c.style.text)
        out.append(f'<rect x="{x:.4f}" y="{y:.4f}" width="{(right-left)*72:.4f}" height="{(top-bottom)*72:.4f}" rx="11" fill="{fill}" fill-opacity="{.42*fill_alpha:.4f}" stroke="{stroke}" stroke-opacity="{stroke_alpha:.4f}" stroke-width="{c.style.penwidth}"/>')
        label_width = max(0, (right-left)*72-2*LABEL_INSET_X)
        clip_id = f"container_label_clip_{c.id}"
        out.append(f'<clipPath id="{clip_id}"><rect x="{x+LABEL_INSET_X:.4f}" y="{y+LABEL_INSET_TOP:.4f}" width="{label_width:.4f}" height="{LABEL_HEIGHT}"/></clipPath>')
        caption_text = elide_text(c.label, label_width, FONT_SIZE*1.08)
        out.append(f'<text data-container-label="{c.id}" clip-path="url(#{clip_id})" x="{x+LABEL_INSET_X:.4f}" y="{y+LABEL_INSET_TOP+FONT_SIZE:.4f}" fill="{caption}" fill-opacity="{text_alpha:.4f}" font-family="Arial,sans-serif" font-size="{FONT_SIZE}" font-weight="700"><title>{html.escape(c.label)}</title>{html.escape(caption_text)}</text>')
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
            label_color, label_alpha = color(edge.style.text or text)
            font_size = style.font_size
            if not style.label_background_transparent:
                label_width = estimated_text_width(edge.label, font_size) + 10
                label_height = max(16, font_size*1.25+4)
                label_background = "#352C43" if dark else "#FFFFFF"
                out.append(f'<rect data-edge-label-background="{edge.id}" x="{x-label_width/2:.4f}" y="{y-label_height/2:.4f}" width="{label_width:.4f}" height="{label_height:g}" rx="6" fill="{label_background}"/>')
            out.append(f'<text data-edge-label="{edge.id}" x="{x:.4f}" y="{y+font_size/3:.4f}" text-anchor="middle" fill="{label_color}" fill-opacity="{label_alpha:.4f}" font-family="Arial,sans-serif" font-size="{font_size:g}" font-weight="500">{html.escape(edge.label)}</text>')
    # Keep equal-depth objects in their project order, while honoring the
    # editor's explicit paint order in both SVG and the native canvas.
    ordered_nodes = sorted(enumerate(project.nodes), key=lambda pair: (pair[1].z_index, pair[0]))
    for _, node in ordered_nodes:
        n = positions[node.id]
        paths = normalized_paths(node)
        closed = icon_library()[node.icon]["closed"] if node.icon else [True]+[False]*(len(paths)-1)
        out.append(f'<g data-node="{node.id}"' + (f' data-icon="{node.icon}"' if node.icon else "") + ">")
        fill, fill_alpha = color(node.style.fill); stroke, stroke_alpha = color(node.style.stroke)
        fills = icon_library()[node.icon].get("fill_paths", []) if node.icon else [paths[0]]
        # A compound nonzero path paints overlapping bodies only once, preserving alpha.
        fill_data = " ".join(data([point(n["x"]+(x-.5)*n["width"], n["y"]+(y-.5)*n["height"]) for x,y in path], True) for path in fills)
        if fill_data:
            out.append(f'<path data-node-fill="{node.id}" d="{fill_data}" fill="{fill}" fill-opacity="{fill_alpha:.4f}" fill-rule="nonzero" stroke="none"/>')
        dash = _node_border_dash(node.style)
        for path, close in zip(paths, closed):
            points = [point(n["x"]+(x-.5)*n["width"], n["y"]+(y-.5)*n["height"]) for x, y in path]
            out.append(f'<path data-node-stroke="{node.id}" d="{data(points, close)}" fill="none" stroke="{stroke}" stroke-opacity="{stroke_alpha:.4f}" stroke-width="{node.style.penwidth}" stroke-linecap="round" stroke-linejoin="round"{dash}/>')
        left_x = point(n["x"]-n["width"]/2, n["y"])[0]
        center_x, center_y = point(n["x"], n["y"])
        right_x = point(n["x"]+n["width"]/2, n["y"])[0]
        top_y = point(n["x"], n["y"]+n["height"]/2)[1]
        bottom_y = point(n["x"], n["y"]-n["height"]/2)[1]
        horizontal_alignment = node.label_alignment
        vertical_alignment = node.label_vertical_alignment
        x = {"left": left_x+7, "center": center_x, "right": right_x-7}[horizontal_alignment]
        font_size = node.style.font_size
        y = {"top": top_y+6+font_size*.8, "middle": center_y+font_size*.3, "bottom": bottom_y-6-font_size*.2}[vertical_alignment]
        text_anchor = {"left": "start", "center": "middle", "right": "end"}[horizontal_alignment]
        label_color = node.style.text
        label_color, label_alpha = color(label_color)
        if node.label_wrap or "\n" in node.label or "\r" in node.label:
            inset_x = min(8, n["width"]*72*.08)
            inset_y = min(6, n["height"]*72*.08)
            label_width = max(.01, n["width"]*72-inset_x*2)
            label_height = max(.01, n["height"]*72-inset_y*2)
            lines = label_lines(node.label, label_width, font_size, node.label_wrap)
            line_height = font_size*1.25
            block_height = len(lines)*line_height
            block_top = {"top": top_y+inset_y, "middle": center_y-block_height/2,
                         "bottom": bottom_y-inset_y-block_height}[vertical_alignment]
            x = {"left": left_x+inset_x, "center": center_x, "right": right_x-inset_x}[horizontal_alignment]
            clip_id = f"label_clip_{node.id}"
            out.append(f'<clipPath id="{clip_id}"><rect x="{left_x+inset_x:.4f}" y="{top_y+inset_y:.4f}" width="{label_width:.4f}" height="{label_height:.4f}"/></clipPath>')
            out.append(f'<text clip-path="url(#{clip_id})" text-anchor="{text_anchor}" fill="{label_color}" fill-opacity="{label_alpha:.4f}" font-family="Arial,sans-serif" font-size="{font_size:g}" font-weight="600">')
            for index, line in enumerate(lines):
                out.append(f'<tspan x="{x:.4f}" y="{block_top+font_size*.95+index*line_height:.4f}">{html.escape(line)}</tspan>')
            out.append('</text></g>')
        else:
            out.append(f'<text x="{x:.4f}" y="{y:.4f}" text-anchor="{text_anchor}" fill="{label_color}" fill-opacity="{label_alpha:.4f}" font-family="Arial,sans-serif" font-size="{font_size:g}" font-weight="600">{html.escape(node.label)}</text></g>')
    out.extend(arrow_elements)
    out.append("</svg>")
    return "\n".join(out)


def _area(path):
    return abs(sum(a[0]*b[1]-b[0]*a[1] for a, b in zip(path, path[1:]+path[:1])))/2
