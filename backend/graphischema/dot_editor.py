"""Parse the supported, model-preserving subset of Graphviz DOT."""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass, field

from pydantic import ValidationError

from .models import DiagramProject
from .container_layout import FONT_SIZE as CONTAINER_FONT_SIZE


MAX_DOT_BYTES = 512 * 1024
_IDENTIFIER = re.compile(r"^[A-Za-z][A-Za-z0-9_-]{0,63}$")


class DOTEditError(ValueError):
    """DOT is invalid or contains data the canonical model cannot preserve."""


@dataclass(frozen=True)
class Token:
    value: str
    offset: int
    quoted: bool = False


@dataclass
class NodeStatement:
    parent_id: str | None
    attrs: dict[str, str] = field(default_factory=dict)


@dataclass
class ContainerStatement:
    parent_id: str | None
    attrs: dict[str, str] = field(default_factory=dict)


@dataclass
class EdgeStatement:
    source: str
    target: str
    attrs: dict[str, str]


class _Parser:
    def __init__(self, source: str):
        if len(source.encode("utf-8")) > MAX_DOT_BYTES:
            raise DOTEditError("DOT ограничен размером 512 КиБ.")
        self.source = source
        self.tokens = _tokenize(source)
        self.index = 0
        self.graph_attrs: dict[str, str] = {}
        self.node_defaults: dict[str, str] = {}
        self.edge_defaults: dict[str, str] = {}
        self.nodes: dict[str, NodeStatement] = {}
        self.containers: dict[str, ContainerStatement] = {}
        self.edges: list[EdgeStatement] = []

    def parse(self) -> tuple[dict[str, NodeStatement], dict[str, ContainerStatement], list[EdgeStatement]]:
        if self._peek_value("strict"):
            self._take()
            raise self._error("strict digraph не поддерживается: он меняет семантику параллельных связей")
        if not self._peek_value("digraph"):
            raise self._error("Ожидается digraph; неориентированный graph не поддерживается")
        self._take()
        if not self._peek_value("{"):
            self._take()  # optional graph name
        self._expect("{")
        self._statements(parent_id=None)
        if self.index != len(self.tokens):
            raise self._error("Лишний текст после закрывающей скобки графа")
        _check_attrs(self.node_defaults, {"fontname", "fontsize", "margin", "label", "shape", "style", "fillcolor", "color", "fontcolor", "penwidth", "tooltip", "pos"}, "узлов по умолчанию")
        _check_attrs(self.edge_defaults, {"fontname", "fontsize", "label", "color", "fontcolor", "style", "penwidth", "arrowhead", "arrowtail", "dir", "constraint", "weight", "minlen", "gs_label_background_transparent"}, "связей по умолчанию")
        return self.nodes, self.containers, self.edges

    def _statements(self, parent_id: str | None) -> None:
        while self.index < len(self.tokens) and not self._peek_value("}"):
            if self._peek_value(";") or self._peek_value(","):
                self._take()
                continue
            if self._peek_value("subgraph") and not self.tokens[self.index].quoted:
                self._subgraph(parent_id)
                continue
            first = self._take()
            if not first.quoted and first.value in {"graph", "node", "edge"} and self._peek_value("["):
                attrs = self._attributes()
                if first.value == "graph":
                    if parent_id is None:
                        self._merge_attrs(self.graph_attrs, attrs, "атрибуты графа")
                    else:
                        self._merge_attrs(self.containers[parent_id].attrs, attrs, f"атрибуты контейнера {parent_id}")
                elif parent_id is not None:
                    raise self._error("node[...] и edge[...] внутри контейнеров не поддерживаются")
                elif first.value == "node":
                    self._merge_attrs(self.node_defaults, attrs, "атрибуты узлов по умолчанию")
                else:
                    self._merge_attrs(self.edge_defaults, attrs, "атрибуты связей по умолчанию")
                self._optional_separator()
                continue
            if self._peek_value("="):
                self._take()
                value = self._take().value
                if parent_id is not None:
                    raise self._error("Присваивания атрибутов внутри контейнеров не поддерживаются")
                self._merge_attrs(self.graph_attrs, {first.value: value}, "атрибуты графа")
                self._optional_separator()
                continue
            if self._peek_value("->"):
                chain = [first.value]
                while self._peek_value("->"):
                    self._take()
                    chain.append(self._take().value)
                attrs = dict(self.edge_defaults)
                if self._peek_value("["):
                    attrs.update(self._attributes())
                for source, target in zip(chain, chain[1:]):
                    _check_identifier(source, "узла")
                    _check_identifier(target, "узла")
                    self.edges.append(EdgeStatement(source, target, attrs.copy()))
                self._optional_separator()
                continue
            _check_identifier(first.value, "узла")
            attrs = self._attributes() if self._peek_value("[") else {}
            attrs = {**self.node_defaults, **attrs}
            previous = self.nodes.get(first.value)
            if previous is None:
                self.nodes[first.value] = NodeStatement(parent_id, attrs)
            else:
                if previous.parent_id != parent_id:
                    raise self._error(f"Узел {first.value} объявлен в нескольких контейнерах")
                previous.attrs.update(attrs)
            self._optional_separator()
        self._expect("}")

    def _subgraph(self, parent_id: str | None) -> None:
        self._expect("subgraph")
        if self._peek_value("{"):
            raise self._error("Анонимные subgraph не поддерживаются; задайте имя cluster_<id>")
        name = self._take().value
        if not name.startswith("cluster_"):
            raise self._error(f"Поддерживаются только контейнеры cluster_<id>, получено {name!r}")
        container_id = name[len("cluster_"):]
        _check_identifier(container_id, "контейнера")
        if container_id in self.containers:
            raise self._error(f"Контейнер {container_id} объявлен повторно")
        self.containers[container_id] = ContainerStatement(parent_id)
        self._expect("{")
        self._statements(parent_id=container_id)

    def _attributes(self) -> dict[str, str]:
        attrs: dict[str, str] = {}
        self._expect("[")
        while self.index < len(self.tokens) and not self._peek_value("]"):
            if self._peek_value(",") or self._peek_value(";"):
                self._take()
                continue
            key = self._take().value
            self._expect("=")
            attrs[key] = self._take().value
        self._expect("]")
        return attrs

    def _merge_attrs(self, target: dict[str, str], attrs: dict[str, str], where: str) -> None:
        target.update(attrs)

    def _optional_separator(self) -> None:
        if self._peek_value(";") or self._peek_value(","):
            self._take()

    def _peek_value(self, value: str) -> bool:
        return self.index < len(self.tokens) and self.tokens[self.index].value == value

    def _take(self) -> Token:
        if self.index >= len(self.tokens):
            raise self._error("Неожиданный конец DOT")
        result = self.tokens[self.index]
        self.index += 1
        return result

    def _expect(self, value: str) -> Token:
        token = self._take()
        if token.value != value:
            raise self._error(f"Ожидалось {value!r}, получено {token.value!r}", token)
        return token

    def _error(self, message: str, token: Token | None = None) -> DOTEditError:
        token = token or (self.tokens[self.index] if self.index < len(self.tokens) else None)
        offset = token.offset if token else len(self.source)
        line = self.source.count("\n", 0, offset) + 1
        column = offset - self.source.rfind("\n", 0, offset)
        return DOTEditError(f"{message} (строка {line}, столбец {column}).")


def apply_dot(project: DiagramProject, source: str) -> tuple[DiagramProject, dict[str, list[str]]]:
    """Convert supported DOT into a new canonical project without mutating input."""
    parser = _Parser(source)
    node_statements, container_statements, edge_statements = parser.parse()
    graph_attrs = parser.graph_attrs
    _check_attrs(graph_attrs, {"rankdir", "splines", "bgcolor", "nodesep", "ranksep", "compound", "pad", "notranslate"}, "графа")
    if graph_attrs.get("compound", "true").lower() != "true":
        raise DOTEditError("compound=false нельзя сохранить в канонической модели")
    if graph_attrs.get("pad", "0.25") != "0.25":
        raise DOTEditError("Изменение graph.pad пока не поддерживается канонической моделью")

    existing_nodes = {item.id: item for item in project.nodes}
    existing_containers = {item.id: item for item in project.containers}
    from .dot import to_dot

    try:
        generated_nodes, generated_containers, _ = _Parser(to_dot(project)).parse()
    except DOTEditError:
        generated_nodes, generated_containers = {}, {}
    containers = []
    for container_id, statement in container_statements.items():
        attrs = statement.attrs
        _check_attrs(attrs, {"label", "style", "color", "fillcolor", "fontcolor", "fontname", "fontsize", "labeljust", "penwidth", "margin", "gs_x", "gs_y", "gs_width", "gs_height"}, f"контейнера {container_id}")
        _require_value(attrs, "style", "rounded,filled", f"контейнера {container_id}")
        _require_value(attrs, "fontname", "Arial", f"контейнера {container_id}")
        _require_number(attrs, "fontsize", str(CONTAINER_FONT_SIZE), f"контейнера {container_id}")
        _require_value(attrs, "labeljust", "l", f"контейнера {container_id}")
        old = existing_containers.get(container_id)
        original_margin = generated_containers.get(container_id)
        padding = _container_padding(attrs, old.padding if old else None, container_id)
        if old and original_margin and attrs.get("margin") == original_margin.attrs.get("margin"):
            padding = old.padding
        containers.append({
            "id": container_id,
            "label": attrs.get("label", old.label if old else container_id),
            "parent_id": statement.parent_id,
            "padding": padding,
            "x": _number(attrs["gs_x"], f"gs_x контейнера {container_id}") if "gs_x" in attrs else old.x if old else None,
            "y": _number(attrs["gs_y"], f"gs_y контейнера {container_id}") if "gs_y" in attrs else old.y if old else None,
            "width": _number(attrs["gs_width"], f"gs_width контейнера {container_id}") if "gs_width" in attrs else old.width if old else 3,
            "height": _number(attrs["gs_height"], f"gs_height контейнера {container_id}") if "gs_height" in attrs else old.height if old else 2,
            "style": {
                "fill": attrs.get("fillcolor", old.style.fill if old else "#F1F5F9"),
                "stroke": attrs.get("color", old.style.stroke if old else "#94A3B8"),
                "text": attrs.get("fontcolor", old.style.text if old else "#334155"),
                "penwidth": _number(attrs.get("penwidth", str(old.style.penwidth if old else 1.2)), f"penwidth контейнера {container_id}"),
            },
        })

    nodes = []
    explicit_positions: set[str] = set()
    all_node_statements = dict(node_statements)
    for edge in edge_statements:
        for node_id in (edge.source, edge.target):
            if node_id not in all_node_statements:
                all_node_statements[node_id] = NodeStatement(None, {})
    for node_id, statement in all_node_statements.items():
        attrs = statement.attrs
        allowed = {"label", "shape", "style", "fillcolor", "color", "fontcolor", "penwidth", "tooltip", "pos", "fontname", "fontsize", "margin", "fixedsize", "width", "height", "gs_icon", "gs_label_alignment", "gs_label_vertical_alignment", "gs_label_wrap"}
        _check_attrs(attrs, allowed, f"узла {node_id}")
        old = existing_nodes.get(node_id)
        line_style = old.style.line_style if old else "solid"
        if "style" in attrs:
            styles = {value.strip() for value in attrs["style"].split(",")}
            line_styles = styles & {"solid", "dashed", "dotted"}
            if not {"filled", "rounded"}.issubset(styles) or styles - {"filled", "rounded", "solid", "dashed", "dotted"} or len(line_styles) > 1:
                raise DOTEditError(f"Стиль узла {node_id}: поддерживаются filled,rounded и один из solid, dashed, dotted.")
            line_style = next(iter(line_styles), "solid")
        _require_value(attrs, "fontname", "Arial", f"узла {node_id}")
        _require_value(attrs, "margin", "0.16,0.1", f"узла {node_id}")
        wrap_value = attrs.get("gs_label_wrap", "true" if old and old.label_wrap else "false")
        if wrap_value not in {"true", "false"}:
            raise DOTEditError(f"Для gs_label_wrap узла {node_id} допустимы true и false.")
        if "width" in attrs or "height" in attrs or "fixedsize" in attrs:
            _require_value(attrs, "fixedsize", "true", f"узла {node_id}")
            if "width" not in attrs or "height" not in attrs:
                raise DOTEditError(f"Для узла {node_id} задайте width и height вместе.")
        tooltip = attrs.get("tooltip", old.description or old.kind if old else "")
        description = old.description if old and tooltip == (old.description or old.kind) else tooltip
        position = _position(attrs["pos"], node_id) if "pos" in attrs else None
        if position:
            explicit_positions.add(node_id)
            original = generated_nodes.get(node_id)
            if old and original and attrs.get("pos") == original.attrs.get("pos"):
                # Rendering rounds point coordinates; unchanged DOT must retain exact JSON positions.
                position = (old.x, old.y)
        nodes.append({
            "id": node_id,
            "label": attrs.get("label", old.label if old else node_id),
            "description": description,
            "kind": old.kind if old else "service",
            "shape": attrs.get("shape", old.shape if old else "box"),
            "icon": attrs.get("gs_icon", old.icon if old else None),
            "label_alignment": attrs.get("gs_label_alignment", old.label_alignment if old else "center"),
            "label_vertical_alignment": attrs.get("gs_label_vertical_alignment", old.label_vertical_alignment if old else "middle"),
            "label_wrap": wrap_value == "true",
            "z_index": old.z_index if old else 0,
            "container_id": statement.parent_id,
            "style": {
                "fill": attrs.get("fillcolor", old.style.fill if old else "#FFFFFF"),
                "stroke": attrs.get("color", old.style.stroke if old else "#2563EB"),
                "text": attrs.get("fontcolor", old.style.text if old else "#0F172A"),
                "penwidth": _number(attrs.get("penwidth", str(old.style.penwidth if old else 1.5)), f"penwidth узла {node_id}"),
                "font_size": _number(attrs.get("fontsize", str(old.style.font_size if old else 10)), f"fontsize узла {node_id}"),
                "line_style": line_style,
            },
            "x": position[0] if position else old.x if old else None,
            "y": position[1] if position else old.y if old else None,
            "width": _number(attrs["width"], f"width узла {node_id}") if "width" in attrs else old.width if old else None,
            "height": _number(attrs["height"], f"height узла {node_id}") if "height" in attrs else old.height if old else None,
        })

    if explicit_positions:
        missing = [node["id"] for node in nodes if node["id"] not in explicit_positions and (node["x"] is None or node["y"] is None)]
        if missing:
            raise DOTEditError("Для ручной компоновки задайте pos всем новым узлам или включите ручной режим на холсте: " + ", ".join(missing))

    edges = _build_edges(project, edge_statements)
    unchanged_node_order = tuple(node_statements) == tuple(generated_nodes)
    unchanged_container_order = tuple(container_statements) == tuple(generated_containers)
    if unchanged_node_order:
        order = {node.id: index for index, node in enumerate(project.nodes)}
        nodes.sort(key=lambda node: (0, order[node["id"]]) if node["id"] in order else (1, node["id"]))
    if unchanged_container_order:
        order = {container.id: index for index, container in enumerate(project.containers)}
        containers.sort(key=lambda item: (0, order[item["id"]]) if item["id"] in order else (1, item["id"]))
    candidate_data = project.model_dump(mode="python")
    candidate_data["containers"] = containers
    candidate_data["nodes"] = nodes
    candidate_data["edges"] = edges
    direction = graph_attrs.get("rankdir", project.diagram.direction)
    if direction not in {"TB", "LR", "BT", "RL"}:
        raise DOTEditError(f"Неподдерживаемый rankdir: {direction!r}")
    candidate_data["diagram"]["direction"] = direction
    routing = graph_attrs.get("splines", {"straight": "line", "angled": "polyline", "orthogonal": "ortho", "curved": "curved"}[project.diagram.edge_routing])
    routing_by_dot = {"line": "straight", "false": "straight", "polyline": "angled", "ortho": "orthogonal", "curved": "curved"}
    if routing not in routing_by_dot:
        raise DOTEditError(f"Неподдерживаемый splines: {routing!r}. Используйте line, polyline, ortho или curved")
    candidate_data["diagram"]["edge_routing"] = routing_by_dot[routing]
    if "nodesep" in graph_attrs:
        candidate_data["diagram"]["node_spacing"] = _number(graph_attrs["nodesep"], "nodesep")
    if "ranksep" in graph_attrs:
        candidate_data["diagram"]["rank_spacing"] = _number(graph_attrs["ranksep"], "ranksep")
    candidate_data["presentation"]["background"] = graph_attrs.get("bgcolor", project.presentation.background)
    if explicit_positions:
        candidate_data["diagram"]["layout_mode"] = "manual"
    if graph_attrs.get("notranslate", "false").lower() == "true" and not explicit_positions:
        raise DOTEditError("notranslate=true требует координаты pos у всех узлов")

    try:
        candidate = DiagramProject.model_validate(candidate_data)
    except ValidationError as exc:
        raise DOTEditError("DOT нарушает ограничения канонической модели: " + _validation_message(exc)) from exc
    changes = describe_dot_changes(project, candidate)
    return candidate, changes


def _build_edges(project: DiagramProject, statements: list[EdgeStatement]) -> list[dict[str, object]]:
    old_by_pair: dict[tuple[str, str], list] = {}
    for edge in project.edges:
        old_by_pair.setdefault((edge.source, edge.target), []).append(edge)
    used: set[str] = set()
    result = []
    for index, statement in enumerate(statements):
        attrs = statement.attrs
        _check_attrs(attrs, {"label", "color", "fontcolor", "style", "penwidth", "arrowhead", "arrowtail", "dir", "constraint", "weight", "minlen", "fontname", "fontsize", "headport", "tailport", "gs_source_port", "gs_target_port", "gs_routing", "gs_waypoints", "gs_label_background_transparent"}, f"связи {statement.source} -> {statement.target}")
        _require_value(attrs, "fontname", "Arial", "связи")
        _require_value(attrs, "fontsize", "9", "связи")
        old_candidates = old_by_pair.get((statement.source, statement.target), [])
        label = attrs.get("label", "")
        old = next((item for item in old_candidates if item.id not in used and item.label == label), None)
        if old is None:
            old = next((item for item in old_candidates if item.id not in used), None)
        edge_id = old.id if old else _new_edge_id(statement.source, statement.target, index, used)
        used.add(edge_id)
        direction = attrs.get("dir", old.direction if old else "forward")
        if direction not in {"forward", "both", "none"}:
            raise DOTEditError(f"dir={direction!r} не поддерживается для связи {statement.source} -> {statement.target}")
        line_style = attrs.get("style", old.style.line_style if old else "solid")
        if line_style not in {"solid", "dashed", "dotted", "bold"}:
            raise DOTEditError(f"style={line_style!r} не поддерживается для связи {statement.source} -> {statement.target}")
        constraint = attrs.get("constraint", str(old.style.constraint if old else True)).lower()
        if constraint not in {"true", "false"}:
            raise DOTEditError(f"constraint должен быть true или false, получено {constraint!r}")
        label_background = attrs.get("gs_label_background_transparent", "true" if old and old.style.label_background_transparent else "false")
        if label_background not in {"true", "false"}:
            raise DOTEditError("gs_label_background_transparent должен быть true или false.")
        if ("headport" in attrs and "gs_target_port" in attrs) or ("tailport" in attrs and "gs_source_port" in attrs):
            raise DOTEditError("Укажите одну привязку на каждом конце связи: порт Graphviz либо вершину фигуры.")
        try:
            waypoints = json.loads(attrs["gs_waypoints"]) if "gs_waypoints" in attrs else [p.model_dump() for p in old.waypoints] if old else []
        except (ValueError, TypeError) as exc:
            raise DOTEditError("gs_waypoints должен быть JSON-массивом координат.") from exc
        result.append({
            "id": edge_id,
            "source": statement.source,
            "target": statement.target,
            "label": label,
            "direction": direction,
            "source_port": attrs.get("gs_source_port", attrs.get("tailport", old.source_port if old else "auto")),
            "target_port": attrs.get("gs_target_port", attrs.get("headport", old.target_port if old else "auto")),
            "routing": attrs.get("gs_routing", old.routing if old else None),
            "waypoints": waypoints,
            "style": {
                "line_style": line_style,
                "color": attrs.get("color", old.style.color if old else "#64748B"),
                "text": attrs.get("fontcolor", old.style.text if old else None),
                "label_background_transparent": label_background == "true",
                "penwidth": _number(attrs.get("penwidth", str(old.style.penwidth if old else 1.5)), "penwidth связи"),
                "arrowhead": attrs.get("arrowhead", old.style.arrowhead if old else "normal"),
                "arrowtail": attrs.get("arrowtail", old.style.arrowtail if old else "none"),
                "constraint": constraint == "true",
                "weight": _integer(attrs.get("weight", str(old.style.weight if old else 1)), "weight"),
                "minlen": _integer(attrs.get("minlen", str(old.style.minlen if old else 1)), "minlen"),
            },
        })
    return result


def _tokenize(source: str) -> list[Token]:
    tokens: list[Token] = []
    index = 0
    while index < len(source):
        char = source[index]
        if char.isspace():
            index += 1
            continue
        if source.startswith("//", index) or char == "#":
            newline = source.find("\n", index)
            index = len(source) if newline < 0 else newline + 1
            continue
        if source.startswith("/*", index):
            end = source.find("*/", index + 2)
            if end < 0:
                raise DOTEditError("Незакрытый комментарий DOT.")
            index = end + 2
            continue
        if char == '"':
            start = index
            index += 1
            value: list[str] = []
            while index < len(source):
                current = source[index]
                if current == '"':
                    index += 1
                    break
                if current == "\\":
                    index += 1
                    if index >= len(source):
                        raise DOTEditError("Незавершённое экранирование в строке DOT.")
                    escaped = source[index]
                    if escaped not in {'"', "\\", "n", "r", "t"}:
                        raise DOTEditError(f"DOT escape \\{escaped} нельзя представить в канонической модели (позиция {index - 1}).")
                    value.append({"n": "\n", "r": "\r", "t": "\t"}.get(escaped, escaped))
                    index += 1
                    continue
                value.append(current)
                index += 1
            else:
                raise DOTEditError("Незакрытая строка DOT.")
            tokens.append(Token("".join(value), start, quoted=True))
            continue
        if source.startswith("->", index):
            tokens.append(Token("->", index))
            index += 2
            continue
        if char in "{}[]=;,":
            tokens.append(Token(char, index))
            index += 1
            continue
        if char == "<":
            raise DOTEditError(f"HTML-подобные DOT-идентификаторы не поддерживаются (позиция {index}).")
        start = index
        while index < len(source) and not source[index].isspace() and source[index] not in "{}[]=;,\"<>" and not source.startswith("->", index) and not source.startswith("//", index) and not source.startswith("/*", index):
            index += 1
        if index == start:
            raise DOTEditError(f"Недопустимый символ {source[index]!r} в DOT (позиция {index}).")
        tokens.append(Token(source[start:index], start))
    return tokens


def _check_identifier(value: str, kind: str) -> None:
    if not _IDENTIFIER.fullmatch(value):
        raise DOTEditError(f"ID {kind} должен начинаться с латинской буквы и содержать только буквы, цифры, _ или -: {value!r}")


def _check_attrs(attrs: dict[str, str], allowed: set[str], where: str) -> None:
    unknown = sorted(set(attrs) - allowed)
    if unknown:
        raise DOTEditError(f"Неподдерживаемые атрибуты {where}: {', '.join(unknown)}")


def _require_value(attrs: dict[str, str], key: str, expected: str, where: str) -> None:
    if key in attrs and attrs[key] != expected:
        raise DOTEditError(f"Изменение {key}={attrs[key]!r} в {where} не поддерживается канонической моделью")


def _require_number(attrs: dict[str, str], key: str, expected: str, where: str) -> None:
    if key in attrs and _number(attrs[key], key) != float(expected):
        raise DOTEditError(f"Изменение {key}={attrs[key]!r} в {where} не поддерживается канонической моделью")


def _number(value: str, name: str) -> float:
    try:
        number = float(value)
    except ValueError as exc:
        raise DOTEditError(f"{name} должен быть числом, получено {value!r}") from exc
    if not (number == number and abs(number) != float("inf")):
        raise DOTEditError(f"{name} должен быть конечным числом")
    return number


def _integer(value: str, name: str) -> int:
    number = _number(value, name)
    if not number.is_integer():
        raise DOTEditError(f"{name} должен быть целым числом")
    return int(number)


def _position(value: str, node_id: str) -> tuple[float, float]:
    parts = value.rstrip("!").split(",")
    if len(parts) != 2:
        raise DOTEditError(f"pos узла {node_id} должен иметь вид x,y!")
    return _number(parts[0], f"pos.x узла {node_id}") / 72, _number(parts[1], f"pos.y узла {node_id}") / 72


def _container_padding(attrs: dict[str, str], existing: float | None, container_id: str) -> float:
    value = attrs.get("margin")
    if value is None:
        return existing if existing is not None else 16
    if existing is not None and value == _dot_margin(existing):
        return existing
    return round(_number(value, f"margin контейнера {container_id}") * 72, 8)


def _dot_margin(padding: float) -> str:
    return f"{padding / 72:.12f}"


def _new_edge_id(source: str, target: str, index: int, used: set[str]) -> str:
    digest = hashlib.sha1(f"{source}\0{target}\0{index}".encode()).hexdigest()[:8]
    candidate = f"edge_{digest}"
    suffix = 2
    while candidate in used:
        candidate = f"edge_{digest}_{suffix}"
        suffix += 1
    return candidate


def describe_dot_changes(before: DiagramProject, after: DiagramProject) -> dict[str, list[str]]:
    result: dict[str, list[str]] = {}
    for key in ("containers", "nodes", "edges"):
        old = {item.id: item.model_dump(mode="json") for item in getattr(before, key)}
        new = {item.id: item.model_dump(mode="json") for item in getattr(after, key)}
        result[key] = [
            *(f"+ {item_id}" for item_id in sorted(new.keys() - old.keys())),
            *(f"− {item_id}" for item_id in sorted(old.keys() - new.keys())),
            *(f"~ {item_id}" for item_id in sorted(old.keys() & new.keys()) if old[item_id] != new[item_id]),
        ]
    settings_changed = []
    if before.diagram != after.diagram:
        settings_changed.append("Настройки компоновки")
    if before.presentation != after.presentation:
        settings_changed.append("Оформление")
    result["settings"] = settings_changed
    return result


def _validation_message(exc: ValidationError) -> str:
    return "; ".join(f"{'.'.join(str(part) for part in item['loc'])}: {item['msg']}" for item in exc.errors())
