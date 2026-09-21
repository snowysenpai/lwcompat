#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$HOME/.local/share/lwcompat"
APPS_DIR="$HOME/.local/share/applications"
ICONS_DIR="$HOME/.local/share/icons"
BIN_DIR="$HOME/.local/bin"

say() { printf '[LWCompat uninstaller] %s\n' "$*"; }

if [[ -f "$APP_DIR/config.sh" ]]; then
    # shellcheck disable=SC1090
    source "$APP_DIR/config.sh"

    MANIFEST="${LWCOMPAT_GAME_DIR:-}/manifest.json"
    if [[ -f "$MANIFEST" ]]; then
        python3 - "$MANIFEST" <<'PY'
import json
import os
import sys
import tempfile
from pathlib import Path

path = Path(sys.argv[1])
try:
    data = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(0)

data["bundle_url"] = "https://lastwar-cdn.akamaized.net/hotupdate/"
data["bundle_ver_url"] = "https://lastwar-serverlist-cf.lastwarapp.net"

fd, temp_name = tempfile.mkstemp(prefix="manifest.lwcompat.uninstall.", suffix=".tmp", dir=str(path.parent))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, separators=(",", ":"))
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temp_name, path)
finally:
    try:
        os.unlink(temp_name)
    except FileNotFoundError:
        pass
PY
        say "Restored official manifest endpoints."
    fi
fi

if [[ -f "$APP_DIR/proxy.pid" ]]; then
    PID="$(cat "$APP_DIR/proxy.pid" 2>/dev/null || true)"
    [[ -z "${PID:-}" ]] || kill "$PID" 2>/dev/null || true
fi

pkill -f "$APP_DIR/bundle_proxy.py" 2>/dev/null || true
rm -f "$APPS_DIR/lwcompat.desktop"
rm -f "$ICONS_DIR/lastwar-lwcompat.png"
rm -f "$BIN_DIR/lwcompat"
rm -rf "$APP_DIR"

if command -v kbuildsycoca6 >/dev/null 2>&1; then
    kbuildsycoca6 >/dev/null 2>&1 || true
elif command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
fi

say "LWCompat was removed."
