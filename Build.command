#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
source script/build_common.sh

case "${1:-}" in
  ""|--build-only) ;;
  *) echo "Использование: $0 [--build-only]" >&2; exit 2 ;;
esac

select_xcode
prepare_build_cache
if ! /usr/bin/xcrun --sdk macosx --find xctest >/dev/null 2>&1; then
  echo "XCTest не найден. Откройте Xcode, завершите установку компонентов и повторите сборку." >&2
  exit 1
fi

echo "Используется Xcode: $DEVELOPER_DIR"
echo "Шаг 1/3. Проверяю логику календаря…"
if ! calendarbar_swift test; then
  echo "Проверки не пройдены. Сборка остановлена до обновления приложения." >&2
  exit 1
fi
echo "Шаг 2/3. Собираю CalendarBar для этого Mac…"
calendarbar_swift build --configuration release
BIN_DIR="$(calendarbar_swift build --configuration release --show-bin-path)"
echo "Шаг 3/3. Создаю CalendarBar.app…"
APP_PATH="$PWD/dist/CalendarBar.app"
package_calendarbar "$BIN_DIR/CalendarBar" "$APP_PATH" "${CALENDARBAR_SIGNING_IDENTITY:--}" release
echo "Готово: $APP_PATH"
if [ "${1:-}" != "--build-only" ]; then
  echo "Перенесите CalendarBar.app в Программы. Затем запустите его из Программ."
  /usr/bin/open -R "$APP_PATH"
fi
