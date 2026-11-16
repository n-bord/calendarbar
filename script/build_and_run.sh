#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
source script/build_common.sh

MODE=run
VARIANT=dev
for option in "$@"; do
  case "$option" in
    --demo) VARIANT=demo ;;
    --build-only|--verify|--logs|--telemetry|--debug)
      if [ "$MODE" != "run" ]; then
        echo "Выберите один режим запуска." >&2
        exit 2
      fi
      MODE="$option"
      ;;
    *) echo "Использование: $0 [--demo] [--build-only|--verify|--logs|--telemetry|--debug]" >&2; exit 2 ;;
  esac
done

APP_NAME="CalendarBar Dev"
PROCESS_NAME=CalendarBarDev
if [ "$VARIANT" = demo ]; then
  APP_NAME="CalendarBar Demo"
  PROCESS_NAME=CalendarBarDemo
fi
APP_PATH="$PWD/dist/$APP_NAME.app"
BUNDLE_ID="com.nbord.CalendarBar.$VARIANT"

# Match only this user’s developer executable. The installed CalendarBar has
# a different executable and bundle identifier and can keep running.
dev_pid() {
  /usr/bin/pgrep -n -u "$(id -u)" -x "$PROCESS_NAME"
}

stop_dev() {
  local pid status=0
  pid="$(dev_pid)" || status=$?
  if [ "$status" -eq 1 ]; then return 0; fi
  if [ "$status" -ne 0 ]; then return "$status"; fi
  kill "$pid"
  for attempt in {1..30}; do
    if ! kill -0 "$pid" 2>/dev/null; then return 0; fi
    sleep 0.1
  done
  echo "$APP_NAME ещё завершается. Повторите запуск." >&2
  return 1
}

select_xcode
prepare_build_cache
calendarbar_swift build --configuration debug
BIN_DIR="$(calendarbar_swift build --configuration debug --show-bin-path)"
if [ "$MODE" != "--build-only" ]; then stop_dev; fi
package_calendarbar "$BIN_DIR/CalendarBar" "$APP_PATH" - "$VARIANT"
echo "Готово: $APP_PATH"
if [ "$MODE" = "--build-only" ]; then exit 0; fi

/usr/bin/open -n "$APP_PATH"

case "$MODE" in
  --verify|--debug)
    for attempt in {1..30}; do
      if PID="$(dev_pid)"; then
        if [ "$MODE" = "--debug" ]; then exec /usr/bin/xcrun lldb --attach-pid "$PID"; fi
        echo "$APP_NAME запущен."
        exit 0
      fi
      sleep 0.1
    done
    echo "$APP_NAME не появился в списке запущенных процессов." >&2
    exit 1
    ;;
  --logs) exec /usr/bin/log stream --info --style compact --predicate "process == '$PROCESS_NAME'" ;;
  --telemetry) exec /usr/bin/log stream --info --style compact --predicate "subsystem == '$BUNDLE_ID'" ;;
esac
