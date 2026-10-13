"""Application-level validation helpers for canonical diagrams."""

from dataclasses import dataclass

from .models import DiagramProject


@dataclass(frozen=True)
class ValidationIssue:
    code: str
    severity: str
    message: str
    element_ids: tuple[str, ...] = ()


def validate_diagram(project: DiagramProject) -> list[ValidationIssue]:
    """Return non-fatal quality findings after schema validation succeeds."""
    issues: list[ValidationIssue] = []
    node_ids = {node.id for node in project.nodes}
    connected = {edge.source for edge in project.edges} | {edge.target for edge in project.edges}
    for node in project.nodes:
        if node.id not in connected and len(project.nodes) > 1:
            issues.append(ValidationIssue(
                code="NODE_UNCONNECTED",
                severity="warning",
                message=f"Объект «{node.label}» не связан с другими объектами.",
                element_ids=(node.id,),
            ))
    for edge in project.edges:
        if edge.source == edge.target:
            issues.append(ValidationIssue(
                code="EDGE_SELF_REFERENCE",
                severity="warning",
                message=f"Связь «{edge.id}» соединяет объект с самим собой.",
                element_ids=(edge.id, edge.source),
            ))
    if not project.nodes:
        issues.append(ValidationIssue(
            code="DIAGRAM_EMPTY",
            severity="information",
            message="Добавьте первый объект, чтобы начать диаграмму.",
        ))
    return issues
