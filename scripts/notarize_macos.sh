#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$ROOT/dist/GraphiSchema-Distribution.app"
ARCHIVE_PATH="$ROOT/dist/GraphiSchema-Distribution.zip"
NOTARY_PROFILE="${GRAPHI_SCHEMA_NOTARY_PROFILE:-}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Ошибка: notarization поддерживается только на macOS." >&2
  exit 1
fi
if [[ -z "$NOTARY_PROFILE" ]]; then
  echo "Для notarization задайте GRAPHI_SCHEMA_NOTARY_PROFILE с профилем xcrun notarytool." >&2
  exit 2
fi
if [[ ! -d "$APP_PATH" ]]; then
  echo "Не найдено приложение: $APP_PATH. Сначала выполните build_macos.sh distribution." >&2
  exit 2
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ARCHIVE_PATH"
echo "GraphiSchema: отправка архива в Apple notarization service…"
xcrun notarytool submit "$ARCHIVE_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ARCHIVE_PATH"
echo "Подписанный и notarized архив: $ARCHIVE_PATH"
