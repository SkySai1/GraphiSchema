"""Local Jinja substitutions for user-editable system prompts."""
from pathlib import Path
import re

from jinja2 import StrictUndefined, TemplateError, nodes
from jinja2.sandbox import SandboxedEnvironment
from pydantic import BaseModel, ConfigDict, Field, field_validator

DEFAULT_VARIABLES = {"graphviz_attributes": (Path(__file__).parent / "resources/graphviz_attributes.txt").read_text()}


class PromptTemplateError(ValueError):
    pass


class PromptPreviewRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    system_prompt: str = Field(max_length=12000)
    variables: dict[str, str] = Field(default_factory=dict)

    @field_validator("variables")
    @classmethod
    def validate_variables(cls, values: dict[str, str]) -> dict[str, str]:
        if len(values) > 128 or sum(len(v) for v in values.values()) > 128000:
            raise ValueError("Слишком большой набор переменных промпта")
        for key, value in values.items():
            if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]{0,63}", key) or len(value) > 32000:
                raise ValueError("Имя переменной: латинские буквы, цифры, _; значение: до 32000 символов")
        return values


def render_system_prompt(source: str, variables: dict[str, str]) -> str:
    request = PromptPreviewRequest(system_prompt=source, variables=variables)
    environment = SandboxedEnvironment(undefined=StrictUndefined, autoescape=False)
    environment.globals.clear()
    # This editor supports substitutions and filters, not executable template programs.
    # Blocking loops/calls prevents runaway CPU and recursive templates before rendering.
    def bounded_filter(original):
        def apply(*args, **kwargs):
            if original.__name__ == "do_replace" and len(args) >= 4:
                value, old, new = map(str, args[1:4])
                count = args[4] if len(args) > 4 else kwargs.get("count")
                replacements = value.count(old)
                if count is not None and count >= 0:
                    replacements = min(replacements, count)
                if len(value)+replacements*(len(new)-len(old)) > 64000:
                    raise PromptTemplateError("Результат фильтра превышает 64000 символов.")
            result = original(*args, **kwargs)
            if len(str(result)) > 64000:
                raise PromptTemplateError("Результат фильтра превышает 64000 символов.")
            return result
        # Preserve Jinja's environment/evaluation context calling convention.
        if hasattr(original, "jinja_pass_arg"):
            apply.jinja_pass_arg = original.jinja_pass_arg
        return apply
    environment.filters = {name: bounded_filter(environment.filters[name]) for name in ("trim", "upper", "lower", "default", "replace")}
    try:
        tree = environment.parse(request.system_prompt)
        forbidden = (nodes.For, nodes.Macro, nodes.Call, nodes.Getattr, nodes.Getitem,
                     nodes.Include, nodes.Import, nodes.FromImport, nodes.Extends,
                     nodes.Assign, nodes.Block, nodes.BinExpr, nodes.Concat)
        if any(tree.find_all(forbidden)):
            raise PromptTemplateError("Допустимы подстановки {{ имя }}, условия и текстовые фильтры; циклы, вызовы и доступ к объектам запрещены.")
        chunks, size = [], 0
        for chunk in environment.from_string(request.system_prompt).generate({**DEFAULT_VARIABLES, **request.variables}):
            size += len(chunk)
            if size > 64000:
                raise PromptTemplateError("Промпт после подстановки превышает 64000 символов.")
            chunks.append(chunk)
        result = "".join(chunks)
    except (TemplateError, TypeError) as exc:
        raise PromptTemplateError(f"Ошибка шаблона Jinja: {exc}") from exc
    if len(result) > 64000:
        raise PromptTemplateError("Промпт после подстановки превышает 64000 символов.")
    return result
