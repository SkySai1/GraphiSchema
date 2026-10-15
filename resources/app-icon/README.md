# Иконка GraphiSchema

`GraphiSchema.png` — общий полноцветный исходник с прозрачностью. Он используется в шапке каждого рабочего окна и для значка приложения в Dock. Скрипт `scripts/build_app_icon.sh` формирует из него `.icns` с десятью изображениями стандартных и Retina-размеров, от 16 до 1024 px. Основной скрипт сборки устанавливает PNG и ICNS в `Contents/Resources` и прописывает `CFBundleIconFile`.

Изображение создано 15 октября 2026 года встроенным инструментом `image_gen` (навык imagegen, режим built-in). Преобразование размеров и упаковка в ICNS выполняются локально средствами `sips` и `iconutil`; генерация изображения при сборке не требуется.

## Промпт

```text
Use case: logo-brand. Asset type: one production macOS application icon for GraphiSchema, a native architectural diagram editor, also displayed as the identical 38 px mark in the application's header. Generate a single square 1024x1024 icon, not a mockup or a sheet. Subject: a bold, memorable architecture diagram emblem: three or four generously sized rounded rectangular nodes arranged in a balanced branching composition, joined by thick clean orthogonal connectors with one clearly integrated arrowhead. Clear silhouette and strong legibility at 32 px. Style: refined macOS app icon, precise geometric forms, very restrained soft dimensionality, crisp smooth edges. Backplate: one deep midnight violet rounded square / squircle, matching interface tones #251D32 and #292135, with subtle blue-violet shading; foreground nodes porcelain white and pale lavender, connectors vivid blue matching #3867E8. Keep the diagram emblem comfortably inset and centered. The squircle fills about 86 percent of the square canvas with balanced transparent margin. Outside the icon's squircle must be genuinely transparent, preserve alpha, no opaque surrounding rectangle. No text, no letters, no watermark, no border frame, no tiny circuitry, no extra symbols, no large drop shadow, no desktop scene. Deliver just the finished icon.
```
