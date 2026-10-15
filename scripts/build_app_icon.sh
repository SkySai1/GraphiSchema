#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/resources/app-icon/GraphiSchema.png"
OUTPUT="${1:-$ROOT/dist/GraphiSchema.icns}"

for tool in sips iconutil; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Ошибка: для сборки иконки требуется macOS-утилита '$tool'." >&2
    exit 1
  fi
done
if [[ ! -f "$SOURCE" ]]; then
  echo "Ошибка: отсутствует исходник иконки: $SOURCE" >&2
  exit 1
fi

ICON_WORK="$(mktemp -d "${TMPDIR:-/tmp}/graphischema-app-icon.XXXXXX")"
trap 'rm -rf "$ICON_WORK"' EXIT
ICONSET="$ICON_WORK/GraphiSchema.iconset"
mkdir -p "$ICONSET" "$(dirname "$OUTPUT")"

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  retina=$((size * 2))
  sips -z "$retina" "$retina" "$SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$OUTPUT"
echo "Иконка: $OUTPUT"
