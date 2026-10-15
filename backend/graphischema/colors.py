"""Theme-aware monochrome colors; explicit colors from older files stay custom."""

def resolve_color(value, mode, theme, *, fill=False):
    if mode not in {"theme", "inverse"}:
        return value
    white = (theme == "light") if fill else (theme == "dark")
    if mode == "inverse": white = not white
    return "#FFFFFF" if white else "#000000"


def resolved_project(project):
    """Return a rendering copy. Export and preview never mutate the document."""
    copy = project.model_copy(deep=True)
    theme = project.presentation.theme
    for item in [*copy.nodes, *copy.containers]:
        for parameter in ("fill", "stroke", "text"):
            setattr(item.style, parameter, resolve_color(getattr(item.style, parameter), getattr(item.style, parameter+"_mode"), theme, fill=parameter == "fill"))
    for edge in copy.edges:
        edge.style.color = resolve_color(edge.style.color, edge.style.color_mode, theme)
        edge.style.text = resolve_color(edge.style.text, edge.style.text_mode, theme)
    return copy
