#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="GraphiSchema"
BUILD_MODE="${1:-local}"
case "$BUILD_MODE" in
  local|distribution) ;;
  *) echo "Использование: $0 [local|distribution]" >&2; exit 2 ;;
esac

APP_BUNDLE_NAME="$APP_NAME"
SIGN_IDENTITY="${GRAPHI_SCHEMA_SIGN_IDENTITY:-}"
if [[ "$BUILD_MODE" == "distribution" ]]; then
  if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "Для distribution-сборки задайте GRAPHI_SCHEMA_SIGN_IDENTITY (Developer ID Application)." >&2
    exit 2
  fi
  APP_BUNDLE_NAME="$APP_NAME-Distribution"
fi

BUILD_CACHE="${GRAPHI_SCHEMA_BUILD_CACHE:-${TMPDIR:-/tmp}/graphischema-build-cache}"
mkdir -p "$BUILD_CACHE/clang" "$BUILD_CACHE/swift" "$BUILD_CACHE/spm" "$BUILD_CACHE/uv"
export MODULE_CACHE_DIR="$BUILD_CACHE/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_CACHE/swift"
export UV_CACHE_DIR="${UV_CACHE_DIR:-$BUILD_CACHE/uv}"

APP_PATH="$ROOT/dist/$APP_BUNDLE_NAME.app"
CONTENTS="$APP_PATH/Contents"
RESOURCES="$CONTENTS/Resources"
BUNDLED_PROJECT="$RESOURCES/GraphiSchema"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Ошибка: сборка GraphiSchema.app поддерживается только на macOS." >&2
  exit 1
fi

for tool in swift uv; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Ошибка: не найден обязательный инструмент '$tool'." >&2
    exit 1
  fi
done

echo "GraphiSchema: сборка нативного macOS release target…"
swift build --package-path "$ROOT/native" --configuration release \
  --scratch-path "$BUILD_CACHE/scratch" --cache-path "$BUILD_CACHE/spm" --disable-sandbox \
  -debug-info-format none
BIN_PATH="$(swift build --package-path "$ROOT/native" --configuration release \
  --scratch-path "$BUILD_CACHE/scratch" --cache-path "$BUILD_CACHE/spm" --disable-sandbox \
  -debug-info-format none --show-bin-path)"

echo "GraphiSchema: упаковка локального Python backend…"
rm -rf "$APP_PATH"
mkdir -p "$CONTENTS/MacOS" "$BUNDLED_PROJECT/backend" "$BUNDLED_PROJECT/examples" "$BUNDLED_PROJECT/resources"
cp "$BIN_PATH/GraphiSchema" "$CONTENTS/MacOS/GraphiSchema"
cp -R "$ROOT/backend/graphischema" "$BUNDLED_PROJECT/backend/graphischema"
find "$BUNDLED_PROJECT/backend/graphischema" -type d -name __pycache__ -prune -exec rm -rf {} +
find "$BUNDLED_PROJECT/backend/graphischema" -type f -name '*.py[co]' -delete
cp "$ROOT/examples/starter.json" "$BUNDLED_PROJECT/examples/starter.json"
cp -R "$ROOT/resources/object-library" "$BUNDLED_PROJECT/resources/object-library"
cp "$ROOT/pyproject.toml" "$ROOT/uv.lock" "$ROOT/README.md" "$ROOT/requirements.txt" "$BUNDLED_PROJECT/"
cp "$ROOT/TODO.md" "$BUNDLED_PROJECT/"
cp -R "$ROOT/docs" "$BUNDLED_PROJECT/docs"
cp "$ROOT/LICENSE" "$RESOURCES/LICENSE"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>GraphiSchema</string>
  <key>CFBundleDisplayName</key><string>GraphiSchema</string>
  <key>CFBundleIdentifier</key><string>local.graphischema.app</string>
  <key>CFBundleVersion</key><string>0.1.0</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleExecutable</key><string>GraphiSchema</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
printf 'APPL????' > "$CONTENTS/PkgInfo"

if command -v dot >/dev/null 2>&1; then
  dot -V
else
  echo "Предупреждение: Graphviz dot не найден; backend использует локальный SVG fallback."
fi

if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "Предупреждение: для PNG-экспорта установите librsvg: brew install librsvg."
fi

APP_SUPPORT="${GRAPHI_SCHEMA_APP_SUPPORT:-$HOME/Library/Application Support/GraphiSchema}"
mkdir -p "$APP_SUPPORT"
echo "GraphiSchema: установка Python-зависимостей в Application Support…"
UV_PROJECT_ENVIRONMENT="$APP_SUPPORT/backend-venv" \
  uv sync --project "$BUNDLED_PROJECT" --no-dev --no-install-project

if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "GraphiSchema: подпись code signing identity '$SIGN_IDENTITY'…"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" --identifier "local.graphischema.app" "$APP_PATH"
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
else
  echo "GraphiSchema: ad hoc-подпись локального приложения…"
  codesign --force --sign - --identifier "local.graphischema.app" "$APP_PATH"
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
fi

if [[ "$BUILD_MODE" == "distribution" ]]; then
  ARCHIVE_PATH="$ROOT/dist/$APP_NAME-Distribution.zip"
  ditto -c -k --keepParent "$APP_PATH" "$ARCHIVE_PATH"
  echo "Архив для распространения: $ARCHIVE_PATH"
fi

echo "Готово: $APP_PATH"
echo "Запуск: open \"$APP_PATH\""
