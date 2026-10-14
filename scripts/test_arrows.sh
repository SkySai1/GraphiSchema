#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
ARTIFACTS="${GRAPHI_SCHEMA_ARROW_OUTPUT:-$ROOT/dist/arrow-debug/current}"
BUILD_CACHE="${GRAPHI_SCHEMA_BUILD_CACHE:-${TMPDIR:-/tmp}/graphischema-build-cache}"
mkdir -p "$ARTIFACTS/native" "$BUILD_CACHE/clang" "$BUILD_CACHE/swift" "$BUILD_CACHE/spm"
export MODULE_CACHE_DIR="$BUILD_CACHE/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_CACHE/swift"

uv run python scripts/diagnose_arrows.py --output "$ARTIFACTS"
uv run pytest tests/test_arrow_rendering.py tests/test_canvas_geometry.py
swift build --package-path "$ROOT/native" --configuration debug \
  --scratch-path "$BUILD_CACHE/ui-test-scratch" --cache-path "$BUILD_CACHE/spm" --disable-sandbox
BIN_PATH="$(swift build --package-path "$ROOT/native" --configuration debug \
  --scratch-path "$BUILD_CACHE/ui-test-scratch" --cache-path "$BUILD_CACHE/spm" --disable-sandbox --show-bin-path)"
GRAPHI_SCHEMA_ARROW_FIXTURES="$ARTIFACTS/native-fixtures.json" \
GRAPHI_SCHEMA_ARROW_ARTIFACT_DIR="$ARTIFACTS/native" \
"$BIN_PATH/GraphiSchema" --arrow-regression-test
