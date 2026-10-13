#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Ошибка: нативный AppKit smoke test поддерживается только на macOS." >&2
  exit 1
fi

BUILD_CACHE="${GRAPHI_SCHEMA_BUILD_CACHE:-${TMPDIR:-/tmp}/graphischema-build-cache}"
mkdir -p "$BUILD_CACHE/clang" "$BUILD_CACHE/swift" "$BUILD_CACHE/spm"
export MODULE_CACHE_DIR="$BUILD_CACHE/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_CACHE/swift"

swift build --package-path "$ROOT/native" --configuration debug \
  --scratch-path "$BUILD_CACHE/ui-test-scratch" --cache-path "$BUILD_CACHE/spm" --disable-sandbox
BIN_PATH="$(swift build --package-path "$ROOT/native" --configuration debug \
  --scratch-path "$BUILD_CACHE/ui-test-scratch" --cache-path "$BUILD_CACHE/spm" --disable-sandbox --show-bin-path)"
"$BIN_PATH/GraphiSchema" --ui-smoke-test
