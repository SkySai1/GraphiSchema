"""Canonical JSON model for GraphiSchema projects."""

from __future__ import annotations

import re
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


Color = str
ColorMode = Literal["custom", "theme", "inverse"]
_COLOR_RE = re.compile(r"^#[0-9a-fA-F]{6}(?:[0-9a-fA-F]{2})?$")
_ID_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_-]{0,63}$")


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


def _validate_color(value: str) -> str:
    if not _COLOR_RE.fullmatch(value):
        raise ValueError("Color must use #RRGGBB or #RRGGBBAA format")
    return value.upper()


class ProjectInfo(StrictModel):
    id: str = "project_local"
    title: str = Field(default="Новая архитектура", min_length=1, max_length=160)

    @field_validator("id")
    @classmethod
    def valid_id(cls, value: str) -> str:
        if not _ID_RE.fullmatch(value):
            raise ValueError("ID must start with a letter and contain only letters, digits, _ or -")
        return value


class DiagramSettings(StrictModel):
    type: str = "architecture"
    layout_engine: Literal["dot", "neato", "fdp", "sfdp", "twopi", "circo"] = "dot"
    direction: Literal["TB", "LR", "BT", "RL"] = "LR"
    edge_routing: Literal["straight", "angled", "orthogonal", "curved"] = "angled"
    layout_mode: Literal["auto", "manual"] = "auto"
    node_spacing: float = Field(default=0.55, ge=0.1, le=5)
    rank_spacing: float = Field(default=0.8, ge=0.1, le=5)


class ContainerStyle(StrictModel):
    fill_mode: ColorMode = "custom"
    stroke_mode: ColorMode = "custom"
    text_mode: ColorMode = "custom"
    fill: Color = "#F1F5F9"
    stroke: Color = "#94A3B8"
    text: Color = "#334155"
    penwidth: float = Field(default=1.2, ge=0.5, le=10, allow_inf_nan=False)

    @field_validator("fill", "stroke", "text")
    @classmethod
    def valid_color(cls, value: str) -> str:
        return _validate_color(value)


class DiagramContainer(StrictModel):
    id: str
    label: str = Field(default="", max_length=120)
    parent_id: str | None = None
    style: ContainerStyle = Field(default_factory=lambda: ContainerStyle(fill_mode="theme", stroke_mode="theme", text_mode="theme"))
    padding: float = Field(default=16, ge=4, le=48)
    x: float | None = Field(default=None, ge=-1000, le=1000, allow_inf_nan=False)
    y: float | None = Field(default=None, ge=-1000, le=1000, allow_inf_nan=False)
    width: float = Field(default=3, ge=1, le=20)
    height: float = Field(default=2, ge=1, le=20)

    @field_validator("id", "parent_id")
    @classmethod
    def valid_ids(cls, value: str | None) -> str | None:
        if value is not None and not _ID_RE.fullmatch(value):
            raise ValueError("ID must start with a letter and contain only letters, digits, _ or -")
        return value


class NodeStyle(StrictModel):
    fill_mode: ColorMode = "custom"
    stroke_mode: ColorMode = "custom"
    text_mode: ColorMode = "custom"
    fill: Color = "#FFFFFF"
    stroke: Color = "#2563EB"
    text: Color = "#0F172A"
    penwidth: float = Field(default=1.5, ge=0.5, le=10)
    font_size: float = Field(default=10.0, ge=1, le=144, allow_inf_nan=False)
    line_style: Literal["solid", "dashed", "dotted"] = "solid"

    @field_validator("fill", "stroke", "text")
    @classmethod
    def valid_color(cls, value: str) -> str:
        return _validate_color(value)


class DiagramNode(StrictModel):
    id: str
    label: str = Field(default="", max_length=160)
    description: str = Field(default="", max_length=1000)
    kind: str = Field(default="service", min_length=1, max_length=48)
    shape: Literal["box", "ellipse", "cylinder", "diamond", "hexagon", "cloud"] = "box"
    icon: str | None = None
    container_id: str | None = None
    style: NodeStyle = Field(default_factory=lambda: NodeStyle(fill_mode="theme", stroke_mode="theme", text_mode="theme"))
    x: float | None = None
    y: float | None = None
    width: float | None = Field(default=None, ge=0.5, le=10)
    height: float | None = Field(default=None, ge=0.5, le=10)
    # App-layer paint order. Graphviz's `z` is a geometric coordinate, not a
    # reliable SVG/native stacking order, so the renderer consumes this field.
    z_index: int = Field(default=0, ge=-1_000_000, le=1_000_000)
    rotation: float = Field(default=0, ge=-360000, le=360000, allow_inf_nan=False)
    label_alignment: Literal["left", "center", "right"] = "center"
    label_vertical_alignment: Literal["top", "middle", "bottom"] = "middle"
    label_wrap: bool = False

    @field_validator("rotation")
    @classmethod
    def normalized_rotation(cls, value: float) -> float:
        return (value + 180) % 360 - 180

    @field_validator("icon")
    @classmethod
    def valid_icon(cls, value: str | None) -> str | None:
        from .geometry import icon_library
        if value is not None and value not in icon_library():
            raise ValueError("Icon must refer to a bundled collection figure")
        return value

    @model_validator(mode="after")
    def validate_size(self) -> DiagramNode:
        if (self.width is None) != (self.height is None):
            raise ValueError("Node width and height must be set together")
        if self.icon and self.width is None:
            from .geometry import icon_size
            self.width, self.height = icon_size(self.icon)
        elif self.label_wrap and self.width is None:
            # Automatic label sizing would widen the figure instead of wrapping.
            self.width, self.height = 1.6, 0.62
        return self

    @field_validator("id", "container_id")
    @classmethod
    def valid_ids(cls, value: str | None) -> str | None:
        if value is not None and not _ID_RE.fullmatch(value):
            raise ValueError("ID must start with a letter and contain only letters, digits, _ or -")
        return value


class EdgeStyle(StrictModel):
    color_mode: ColorMode = "custom"
    text_mode: ColorMode = "custom"
    line_style: Literal["solid", "dashed", "dotted", "bold"] = "solid"
    color: Color = "#64748B"
    text: Color | None = None
    # Legacy files defaulted to an opaque label. New edges inherit the project's
    # preference in the editor, DOT conversion and modern canonical documents.
    label_background_transparent: bool = False
    penwidth: float = Field(default=1.5, ge=0.5, le=10)
    font_size: float = Field(default=9.0, ge=1, le=144, allow_inf_nan=False)
    arrowhead: Literal["normal", "vee", "none", "diamond", "dot", "box", "crow", "tee"] = "normal"
    arrowtail: Literal["normal", "vee", "none", "diamond", "dot", "box", "crow", "tee"] = "none"
    constraint: bool = True
    weight: int = Field(default=1, ge=0, le=100)
    minlen: int = Field(default=1, ge=1, le=20)

    @field_validator("color", "text")
    @classmethod
    def valid_color(cls, value: str | None) -> str | None:
        return _validate_color(value) if value is not None else None


class RoutePoint(StrictModel):
    x: float = Field(ge=-1000, le=1000, allow_inf_nan=False)
    y: float = Field(ge=-1000, le=1000, allow_inf_nan=False)


class EdgeTypeDefinition(StrictModel):
    id: str
    name: str = Field(min_length=1, max_length=120)
    description: str = Field(default="", max_length=2000)
    style: EdgeStyle = Field(default_factory=EdgeStyle)
    direction: Literal["forward", "both", "none"] = "forward"
    routing: Literal["straight", "angled", "orthogonal", "curved"] | None = None

    @field_validator("id")
    @classmethod
    def valid_id(cls, value: str) -> str:
        if not _ID_RE.fullmatch(value):
            raise ValueError("Invalid edge type ID")
        return value


class LegendEntry(StrictModel):
    id: str
    kind: Literal["node", "edge_type"]
    node_id: str | None = None
    edge_type_id: str | None = None
    icon: str | None = None
    shape: Literal["box", "ellipse", "cylinder", "diamond", "hexagon", "cloud"] = "box"
    # None uses the referenced object/type description; "" is an explicit override.
    description: str | None = Field(default=None, max_length=2000)

    @field_validator("id", "node_id", "edge_type_id")
    @classmethod
    def valid_id(cls, value: str | None) -> str | None:
        if value is not None and not _ID_RE.fullmatch(value):
            raise ValueError("Invalid legend reference ID")
        return value

    @field_validator("icon")
    @classmethod
    def valid_icon(cls, value: str | None) -> str | None:
        return DiagramNode.valid_icon(value)


class ObjectGroup(StrictModel):
    id: str
    label: str = Field(default="Группа", max_length=120)
    node_ids: list[str] = Field(min_length=2, max_length=10000)

    @field_validator("id")
    @classmethod
    def valid_id(cls, value: str) -> str:
        if not _ID_RE.fullmatch(value):
            raise ValueError("Invalid group ID")
        return value


class DiagramEdge(StrictModel):
    id: str
    source: str
    target: str
    label: str = Field(default="", max_length=160)
    direction: Literal["forward", "both", "none"] = "forward"
    style: EdgeStyle = Field(default_factory=lambda: EdgeStyle(color_mode="theme", text_mode="theme"))
    source_port: str = "auto"
    target_port: str = "auto"
    routing: Literal["straight", "angled", "orthogonal", "curved"] | None = None
    waypoints: list[RoutePoint] = Field(default_factory=list, max_length=32)
    z_index: int = Field(default=0, ge=-1_000_000, le=1_000_000)
    type_id: str | None = None

    @field_validator("source_port", "target_port")
    @classmethod
    def valid_port(cls, value: str) -> str:
        if value not in {"auto", "n", "ne", "e", "se", "s", "sw", "w", "nw"} and not re.fullmatch(r"vertex:(0|[1-9][0-9]{0,2})", value):
            raise ValueError("Attachment must be auto, a compass side, or vertex:<index>")
        return value

    @field_validator("id", "source", "target")
    @classmethod
    def valid_ids(cls, value: str) -> str:
        if not _ID_RE.fullmatch(value):
            raise ValueError("ID must start with a letter and contain only letters, digits, _ or -")
        return value


class PresentationSettings(StrictModel):
    saved_colors: list[Color] = Field(default_factory=list, max_length=64)
    default_edge_label_background_transparent: bool = True
    label_new_elements: bool = True
    legend_mode: Literal["auto", "manual"] = "auto"
    legend_entries: list[LegendEntry] = Field(default_factory=list, max_length=500)

    @field_validator("saved_colors")
    @classmethod
    def valid_saved_colors(cls, values):
        return list(dict.fromkeys(_validate_color(value) for value in values))

    theme: Literal["light", "dark"] = "light"
    background: Color = "#FFFFFF"

    @field_validator("background")
    @classmethod
    def valid_color(cls, value: str) -> str:
        return _validate_color(value)


class DiagramProject(StrictModel):
    schema_version: Literal["1.0"] = "1.0"
    project: ProjectInfo = Field(default_factory=ProjectInfo)
    diagram: DiagramSettings = Field(default_factory=DiagramSettings)
    containers: list[DiagramContainer] = Field(default_factory=list)
    nodes: list[DiagramNode] = Field(default_factory=list)
    edges: list[DiagramEdge] = Field(default_factory=list)
    presentation: PresentationSettings = Field(default_factory=PresentationSettings)
    edge_types: list[EdgeTypeDefinition] = Field(default_factory=list, max_length=256)
    groups: list[ObjectGroup] = Field(default_factory=list)

    @model_validator(mode="after")
    def validate_graph(self) -> DiagramProject:
        types = {item.id: item for item in self.edge_types}
        if len(types) != len(self.edge_types):
            raise ValueError("Edge type IDs must be unique")
        for edge in self.edges:
            if edge.type_id is not None:
                if edge.type_id not in types:
                    raise ValueError(f"Edge '{edge.id}' references missing type '{edge.type_id}'")
                definition = types[edge.type_id]
                edge.style = definition.style.model_copy(deep=True)
                edge.direction, edge.routing = definition.direction, definition.routing
        # Modern documents inherit the project preference only for omitted edge
        # values. Legacy snapshots without this preference keep their old opaque
        # labels; serialization then records that value explicitly.
        if "default_edge_label_background_transparent" in self.presentation.model_fields_set:
            for edge in self.edges:
                if "label_background_transparent" not in edge.style.model_fields_set:
                    edge.style.label_background_transparent = self.presentation.default_edge_label_background_transparent
        all_items = [*self.containers, *self.nodes, *self.edges, *self.groups]
        ids = [item.id for item in all_items]
        if len(ids) != len(set(ids)):
            raise ValueError("IDs must be unique across containers, nodes, edges and groups")

        containers = {item.id: item for item in self.containers}
        nodes = {item.id: item for item in self.nodes}
        grouped: set[str] = set()
        for group in self.groups:
            if len(set(group.node_ids)) != len(group.node_ids) or any(key not in nodes or key in grouped for key in group.node_ids):
                raise ValueError("Group members must exist, be unique and belong to only one group")
            if len({nodes[key].container_id for key in group.node_ids}) != 1:
                raise ValueError("Group members must belong to the same container")
            grouped.update(group.node_ids)
        legend_ids = [item.id for item in self.presentation.legend_entries]
        if len(legend_ids) != len(set(legend_ids)):
            raise ValueError("Legend row IDs must be unique")
        for entry in self.presentation.legend_entries:
            if entry.kind == "edge_type":
                if entry.edge_type_id not in types or entry.node_id is not None or entry.icon is not None:
                    raise ValueError("Legend must reference an existing edge type")
            elif entry.edge_type_id is not None or (entry.node_id is not None and entry.node_id not in nodes):
                raise ValueError("Legend must reference an existing object or a collection figure")
        for container in self.containers:
            if container.parent_id and container.parent_id not in containers:
                raise ValueError(f"Container '{container.id}' references missing parent '{container.parent_id}'")
        for node in self.nodes:
            if node.container_id and node.container_id not in containers:
                raise ValueError(f"Node '{node.id}' references missing container '{node.container_id}'")
        for edge in self.edges:
            if edge.source not in nodes and edge.source not in containers:
                raise ValueError(f"Edge '{edge.id}' references missing source '{edge.source}'")
            if edge.target not in nodes and edge.target not in containers:
                raise ValueError(f"Edge '{edge.id}' references missing target '{edge.target}'")
            from .geometry import vertices
            for node_id, port in ((edge.source, edge.source_port), (edge.target, edge.target_port)):
                count = len(vertices(nodes[node_id])) if node_id in nodes else 4
                if port.startswith("vertex:") and int(port.split(":")[1]) >= count:
                    raise ValueError(f"Edge '{edge.id}' references a missing figure vertex")

        for container in self.containers:
            visited: set[str] = set()
            current: str | None = container.id
            while current is not None:
                if current in visited:
                    raise ValueError(f"Container nesting contains a cycle at '{current}'")
                visited.add(current)
                parent = containers.get(current)
                current = parent.parent_id if parent else None
        return self
