"""Deterministic label line breaking, shared with the native DiagramTextLayout."""

from functools import lru_cache
import unicodedata


def _clusters(text: str) -> list[str]:
    result: list[str] = []
    for char in text:
        value = ord(char)
        combining = unicodedata.category(char).startswith("M") or 0x1F3FB <= value <= 0x1F3FF
        flag_pair = (result and len(result[-1]) == 1 and 0x1F1E6 <= ord(result[-1]) <= 0x1F1FF
                     and 0x1F1E6 <= value <= 0x1F1FF)
        if result and (combining or char == "\u200d" or result[-1].endswith("\u200d") or flag_pair):
            result[-1] += char
        else:
            result.append(char)
    return result


def _units(cluster: str) -> float:
    char = cluster[0]
    if char.isspace():
        return .35
    if ord(char) >= 0x2E80:
        return 1.1
    if char in "mwMW@#%&ÆæЖШЩЮЫжшщюы":
        return 1.05
    if char in "ilIjtf.,:;!'|`":
        return .4
    if char in "r()[]{}":
        return .45
    return .78 if char.isupper() else .63


@lru_cache(maxsize=4096)
def estimated_text_width(text: str, font_size: float) -> float:
    """Conservative text advance for renderer backgrounds without font dependencies."""
    return sum(_units(cluster) for cluster in _clusters(text)) * font_size


def elide_text(text: str, width: float, font_size: float) -> str:
    """Fit one line without reducing its font or splitting grapheme clusters."""
    text = " ".join(text.splitlines())
    if estimated_text_width(text, font_size) <= width:
        return text
    if estimated_text_width("…", font_size) > width:
        return ""
    clusters = _clusters(text)
    low, high = 0, len(clusters)
    while low < high:
        middle = (low+high+1)//2
        if estimated_text_width("".join(clusters[:middle])+"…", font_size) <= width:
            low = middle
        else:
            high = middle-1
    return "".join(clusters[:low])+"…"


@lru_cache(maxsize=4096)
def label_lines(text: str, width: float, font_size: float, wrap: bool) -> tuple[str, ...]:
    paragraphs = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    if not wrap:
        return tuple(paragraphs)
    limit = max(.01, width / max(1, font_size))

    def fits(value: str) -> bool:
        return sum(_units(cluster) for cluster in _clusters(value)) <= limit + 1e-8

    lines: list[str] = []
    for paragraph in paragraphs:
        current = ""
        words = paragraph.split()
        if not words:
            lines.append("")
            continue
        for word in words:
            candidate = current + " " + word if current else word
            if fits(candidate):
                current = candidate
                continue
            if current:
                lines.append(current)
                current = ""
            for cluster in _clusters(word):
                if current and not fits(current + cluster):
                    lines.append(current)
                    current = ""
                current += cluster
        lines.append(current)
    return tuple(lines)
