"""Canonical JSON model for GraphiSchema projects."""

from __future__ import annotations

import re
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


Color = str
_COLOR_RE = re.compile(r"^#[0-9a-fA-F]{6}$")
_ID_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_-]{0,63}$")


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


def _validate_color(value: str) -> str:
    if not _COLOR_RE.fullmatch(value):
        raise ValueError("Color must use the #RRGGBB format")
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
    edge_routing: Literal["straight", "angled", "orthogonal"] = "angled"
    layout_mode: Literal["auto", "manual"] = "auto"
    node_spacing: float = Field(default=0.55, ge=0.1, le=5)
    rank_spacing: float = Field(default=0.8, ge=0.1, le=5)


class ContainerStyle(StrictModel):
    fill: Color = "#F1F5F9"
    stroke: Color = "#94A3B8"
    text: Color = "#334155"

    @field_validator("fill", "stroke", "text")
    @classmethod
    def valid_color(cls, value: str) -> str:
        return _validate_color(value)


class DiagramContainer(StrictModel):
    id: str
    label: str = Field(min_length=1, max_length=120)
    parent_id: str | None = None
    style: ContainerStyle = Field(default_factory=ContainerStyle)
    padding: float = Field(default=16, ge=4, le=48)

    @field_validator("id", "parent_id")
    @classmethod
    def valid_ids(cls, value: str | None) -> str | None:
        if value is not None and not _ID_RE.fullmatch(value):
            raise ValueError("ID must start with a letter and contain only letters, digits, _ or -")
        return value


class NodeStyle(StrictModel):
    fill: Color = "#FFFFFF"
    stroke: Color = "#2563EB"
    text: Color = "#0F172A"
    penwidth: float = Field(default=1.5, ge=0.5, le=10)

    @field_validator("fill", "stroke", "text")
    @classmethod
    def valid_color(cls, value: str) -> str:
        return _validate_color(value)


class DiagramNode(StrictModel):
    id: str
    label: str = Field(min_length=1, max_length=160)
    description: str = Field(default="", max_length=1000)
    kind: str = Field(default="service", min_length=1, max_length=48)
    shape: Literal["box", "ellipse", "cylinder", "diamond", "hexagon", "cloud"] = "box"
    container_id: str | None = None
    style: NodeStyle = Field(default_factory=NodeStyle)
    x: float | None = None
    y: float | None = None
    width: float | None = Field(default=None, ge=0.5, le=10)
    height: float | None = Field(default=None, ge=0.5, le=10)

    @model_validator(mode="after")
    def validate_size(self) -> DiagramNode:
        if (self.width is None) != (self.height is None):
            raise ValueError("Node width and height must be set together")
        return self

    @field_validator("id", "container_id")
    @classmethod
    def valid_ids(cls, value: str | None) -> str | None:
        if value is not None and not _ID_RE.fullmatch(value):
            raise ValueError("ID must start with a letter and contain only letters, digits, _ or -")
        return value


class EdgeStyle(StrictModel):
    line_style: Literal["solid", "dashed", "dotted", "bold"] = "solid"
    color: Color = "#64748B"
    penwidth: float = Field(default=1.5, ge=0.5, le=10)
    arrowhead: Literal["normal", "vee", "none", "diamond", "dot", "box", "crow", "tee"] = "normal"
    arrowtail: Literal["normal", "vee", "none", "diamond", "dot", "box", "crow", "tee"] = "none"
    constraint: bool = True
    weight: int = Field(default=1, ge=0, le=100)
    minlen: int = Field(default=1, ge=1, le=20)

    @field_validator("color")
    @classmethod
    def valid_color(cls, value: str) -> str:
        return _validate_color(value)


class DiagramEdge(StrictModel):
    id: str
    source: str
    target: str
    label: str = Field(default="", max_length=160)
    direction: Literal["forward", "both", "none"] = "forward"
    style: EdgeStyle = Field(default_factory=EdgeStyle)

    @field_validator("id", "source", "target")
    @classmethod
    def valid_ids(cls, value: str) -> str:
        if not _ID_RE.fullmatch(value):
            raise ValueError("ID must start with a letter and contain only letters, digits, _ or -")
        return value


class PresentationSettings(StrictModel):
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

    @model_validator(mode="after")
    def validate_graph(self) -> DiagramProject:
        all_items = [*self.containers, *self.nodes, *self.edges]
        ids = [item.id for item in all_items]
        if len(ids) != len(set(ids)):
            raise ValueError("IDs must be unique across containers, nodes and edges")

        containers = {item.id: item for item in self.containers}
        nodes = {item.id: item for item in self.nodes}
        for container in self.containers:
            if container.parent_id and container.parent_id not in containers:
                raise ValueError(f"Container '{container.id}' references missing parent '{container.parent_id}'")
        for node in self.nodes:
            if node.container_id and node.container_id not in containers:
                raise ValueError(f"Node '{node.id}' references missing container '{node.container_id}'")
        for edge in self.edges:
            if edge.source not in nodes:
                raise ValueError(f"Edge '{edge.id}' references missing source '{edge.source}'")
            if edge.target not in nodes:
                raise ValueError(f"Edge '{edge.id}' references missing target '{edge.target}'")

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
