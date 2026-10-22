#!/usr/bin/env bash
set -u

APP_DIR="${LWCOMPAT_APP_DIR:-$HOME/.local/share/lwcompat}"
LOG_DIR="$APP_DIR/logs"
SESSION_DIR="$LOG_DIR/sessions"
LOG="$LOG_DIR/lwcompat.log"
LOCK="$APP_DIR/lwcompat.lock"
KEEP_SESSIONS="${LWCOMPAT_KEEP_LOGS:-10}"

mkdir -p "$SESSION_DIR"

exec 9>"$LOCK"
if ! flock -n 9; then
    notify-send "LWCompat" "Last War is already running." 2>/dev/null || true
    exit 0
fi

# One log file per session; lwcompat.log always points at the newest one
# (the GUI reads that path). The old single growing log is archived once.
if [[ -f "$LOG" && ! -L "$LOG" ]]; then
    mv -f "$LOG" "$SESSION_DIR/lwcompat-legacy.log"
    gzip -f "$SESSION_DIR/lwcompat-legacy.log" 2>/dev/null || true
fi

SESSION_LOG="$SESSION_DIR/lwcompat-$(date +%Y%m%d-%H%M%S).log"
: > "$SESSION_LOG"
ln -sfn "sessions/${SESSION_LOG##*/}" "$LOG"

if [[ "$KEEP_SESSIONS" =~ ^[0-9]+$ ]] && (( KEEP_SESSIONS > 0 )); then
    find "$SESSION_DIR" -maxdepth 1 -name 'lwcompat-2*.log' -printf '%f\n' |
        sort -r |
        tail -n +"$((KEEP_SESSIONS + 1))" |
        while IFS= read -r old; do
            rm -f -- "$SESSION_DIR/$old"
        done
fi

{
    echo "=================================================="
    echo "LWCompat launch: $(date --iso-8601=seconds 2>/dev/null || date)"
    echo "=================================================="
} >> "$SESSION_LOG"

"$APP_DIR/lwcompat.sh" >> "$SESSION_LOG" 2>&1
EXIT_CODE=$?

echo "LWCompat exit code: $EXIT_CODE" >> "$SESSION_LOG"
exit "$EXIT_CODE"
