#!/bin/bash
set -euo pipefail

TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$TASK_ROOT"
BUILD_CACHE="${GRAPHI_SCHEMA_BUILD_CACHE:-${TMPDIR:-/tmp}/graphischema-build-cache}"
mkdir -p "$BUILD_CACHE/clang" "$BUILD_CACHE/swift" "$BUILD_CACHE/spm"
export MODULE_CACHE_DIR="$BUILD_CACHE/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_CACHE/swift"
swift build --package-path "$TASK_ROOT/native" --configuration debug \
  --scratch-path "$BUILD_CACHE/ui-test-scratch" --cache-path "$BUILD_CACHE/spm" --disable-sandbox
BIN_PATH="$(swift build --package-path "$TASK_ROOT/native" --configuration debug \
  --scratch-path "$BUILD_CACHE/ui-test-scratch" --cache-path "$BUILD_CACHE/spm" --disable-sandbox --show-bin-path)"
"$BIN_PATH/GraphiSchema" --interaction-regression-test
