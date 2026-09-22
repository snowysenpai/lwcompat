#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$HOME/.local/share/lwcompat"
APPS_DIR="$HOME/.local/share/applications"
ICONS_DIR="$HOME/.local/share/icons"
BIN_DIR="$HOME/.local/bin"

FAST_CACHE_DIR="$APP_DIR/fast-cache"
FAST_CACHE_IMAGE="$FAST_CACHE_DIR/assetbundles.ext4"

SERVICE_NAME="lwcompat-fast-asset-cache.service"
SYSTEM_SERVICE="/etc/systemd/system/$SERVICE_NAME"
SYSTEM_HELPER="/usr/local/libexec/lwcompat-fast-asset-cache"
SYSTEM_CONFIG="/etc/lwcompat/fast-asset-cache.conf"
SYSTEM_CONFIG_DIR="/etc/lwcompat"

PURGE_FAST_CACHE=0

say() {
    printf '[LWCompat uninstaller] %s\n' "$*"
}

fail() {
    printf '[LWCompat uninstaller] ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<EOF2
Usage:
  ./uninstall.sh
      Remove LWCompat but preserve the Fast Asset Cache image.

  ./uninstall.sh --purge-fast-cache
      Remove LWCompat and permanently delete the Fast Asset Cache image.

  ./uninstall.sh --keep-fast-cache
      Explicitly preserve the Fast Asset Cache image.
EOF2
}

case "${1:-}" in
    "")
        ;;
    --purge-fast-cache)
        PURGE_FAST_CACHE=1
        ;;
    --keep-fast-cache)
        PURGE_FAST_CACHE=0
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

if pgrep -f '[L]astWar\.exe|[L]astWarLauncher\.exe' >/dev/null 2>&1; then
    fail "Last War is running. Close the game and launcher before uninstalling LWCompat."
fi

#
# Restore official launcher manifest endpoints.
#
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

fd, temp_name = tempfile.mkstemp(
    prefix="manifest.lwcompat.uninstall.",
    suffix=".tmp",
    dir=str(path.parent),
)

try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(
            data,
            handle,
            ensure_ascii=False,
            separators=(",", ":"),
        )
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

#
# Stop native proxy if it is still running.
#
if [[ -f "$APP_DIR/proxy.pid" ]]; then
    PID="$(cat "$APP_DIR/proxy.pid" 2>/dev/null || true)"

    if [[ -n "${PID:-}" ]]; then
        kill "$PID" 2>/dev/null || true
    fi
fi

pkill -f "$APP_DIR/bundle_proxy.py" 2>/dev/null || true

#
# Disable and remove Fast Asset Cache system integration.
#
FAST_CACHE_SYSTEM_INSTALLED=0

if [[ -e "$SYSTEM_SERVICE" ||
      -e "$SYSTEM_HELPER" ||
      -e "$SYSTEM_CONFIG" ]]; then
    FAST_CACHE_SYSTEM_INSTALLED=1
fi

if (( FAST_CACHE_SYSTEM_INSTALLED == 1 )); then
    say "Removing Fast Asset Cache system integration..."

    sudo -v

    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        say "Stopping Fast Asset Cache..."
        sudo systemctl stop "$SERVICE_NAME"

        if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
            fail "Fast Asset Cache could not be stopped safely."
        fi
    fi

    sudo systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true

    sudo rm -f "$SYSTEM_SERVICE"
    sudo rm -f "$SYSTEM_HELPER"
    sudo rm -f "$SYSTEM_CONFIG"

    if [[ -d "$SYSTEM_CONFIG_DIR" ]]; then
        sudo rmdir "$SYSTEM_CONFIG_DIR" 2>/dev/null || true
    fi

    sudo systemctl daemon-reload
    sudo systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true

    say "Fast Asset Cache system integration removed."
fi

#
# Desktop integration.
#
rm -f "$APPS_DIR/lwcompat.desktop"
rm -f "$ICONS_DIR/lastwar-lwcompat.png"
rm -f "$BIN_DIR/lwcompat"
rm -f "$BIN_DIR/lwcompat-fast-cache"

#
# Application files.
#
if (( PURGE_FAST_CACHE == 1 )); then
    if [[ -e "$FAST_CACHE_IMAGE" ]]; then
        say "Deleting Fast Asset Cache image..."
    fi

    rm -rf "$APP_DIR"

    say "Fast Asset Cache removed."
else
    if [[ -d "$APP_DIR" ]]; then
        find "$APP_DIR" \
            -mindepth 1 \
            -maxdepth 1 \
            ! -name fast-cache \
            -exec rm -rf -- {} +

        rmdir "$APP_DIR" 2>/dev/null || true
    fi

    if [[ -f "$FAST_CACHE_IMAGE" ]]; then
        say "Fast Asset Cache preserved:"
        say "  $FAST_CACHE_IMAGE"
    fi
fi

#
# Refresh desktop application database.
#
if command -v kbuildsycoca6 >/dev/null 2>&1; then
    kbuildsycoca6 >/dev/null 2>&1 || true
elif command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
fi

say "LWCompat was removed."

if (( PURGE_FAST_CACHE == 0 )) && [[ -f "$FAST_CACHE_IMAGE" ]]; then
    say "The preserved Fast Asset Cache can be reused automatically on a future installation."
fi
