#!/usr/bin/env bash
set -u

APP_DIR="${LWCOMPAT_APP_DIR:-$HOME/.local/share/lwcompat}"
LOG_DIR="$APP_DIR/logs"
LOG="$LOG_DIR/lwcompat.log"
LOCK="$APP_DIR/lwcompat.lock"

mkdir -p "$LOG_DIR"

exec 9>"$LOCK"
if ! flock -n 9; then
    notify-send "LWCompat" "Last War is already running." 2>/dev/null || true
    exit 0
fi

{
    echo
    echo "=================================================="
    echo "LWCompat launch: $(date --iso-8601=seconds 2>/dev/null || date)"
    echo "=================================================="
} >> "$LOG"

"$APP_DIR/lwcompat.sh" >> "$LOG" 2>&1
EXIT_CODE=$?

echo "LWCompat exit code: $EXIT_CODE" >> "$LOG"
exit "$EXIT_CODE"
