#!/usr/bin/env bash
set -uo pipefail

APP_DIR="${LWCOMPAT_APP_DIR:-$HOME/.local/share/lwcompat}"
CONFIG="$APP_DIR/config.sh"
LOG_DIR="$APP_DIR/logs"
PROXY="$APP_DIR/bundle_proxy.py"
PROXY_LOG="$LOG_DIR/proxy.log"
PROXY_PID_FILE="$APP_DIR/proxy.pid"

CDN_LOCAL="http://127.0.0.1:18080/"
API_LOCAL="http://127.0.0.1:18081"

mkdir -p "$LOG_DIR"

log() {
    printf '[LWCompat] %s\n' "$*"
}

die() {
    printf '[LWCompat] ERROR: %s\n' "$*" >&2
    exit 1
}

[[ -f "$CONFIG" ]] || die "Missing config: $CONFIG. Re-run install.sh."
# shellcheck disable=SC1090
source "$CONFIG"

GAME_DIR="${LWCOMPAT_GAME_DIR:-}"
PREFIX="${LWCOMPAT_PREFIX:-}"
UMU="${LWCOMPAT_UMU:-}"
PROTON="${LWCOMPAT_PROTON:-}"

EXE="$GAME_DIR/LastWarLauncher.exe"
MANIFEST="$GAME_DIR/manifest.json"

stop_proxy() {
    if [[ -f "$PROXY_PID_FILE" ]]; then
        OLD_PID="$(cat "$PROXY_PID_FILE" 2>/dev/null || true)"
        if [[ -n "${OLD_PID:-}" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
            log "Stopping previous bridge (PID $OLD_PID)..."
            kill "$OLD_PID" 2>/dev/null || true
            for _ in {1..20}; do
                kill -0 "$OLD_PID" 2>/dev/null || break
                sleep 0.1
            done
            kill -9 "$OLD_PID" 2>/dev/null || true
        fi
        rm -f "$PROXY_PID_FILE"
    fi

    pkill -f "$APP_DIR/bundle_proxy.py" 2>/dev/null || true
    sleep 0.3
}

cleanup() {
    if [[ -f "$PROXY_PID_FILE" ]]; then
        PID="$(cat "$PROXY_PID_FILE" 2>/dev/null || true)"
        if [[ -n "${PID:-}" ]]; then
            kill "$PID" 2>/dev/null || true
        fi
        rm -f "$PROXY_PID_FILE"
    fi
}

trap cleanup EXIT INT TERM

[[ -d "$PREFIX" ]] || die "Wine prefix not found: $PREFIX"
[[ -f "$EXE" ]] || die "LastWarLauncher.exe not found: $EXE"
[[ -f "$MANIFEST" ]] || die "manifest.json not found: $MANIFEST"
[[ -f "$PROXY" ]] || die "bundle_proxy.py not found: $PROXY"
[[ -f "$UMU" ]] || die "umu-run not found: $UMU"
[[ -d "$PROTON" ]] || die "Proton runtime not found: $PROTON"
command -v python3 >/dev/null 2>&1 || die "python3 is required."

log "LWCompat v0.1.0 starting..."
stop_proxy

log "Patching launcher manifest..."
python3 - "$MANIFEST" "$CDN_LOCAL" "$API_LOCAL" <<'PY'
import json
import os
import sys
import tempfile
from pathlib import Path

manifest = Path(sys.argv[1])
cdn_local = sys.argv[2]
api_local = sys.argv[3]

try:
    data = json.loads(manifest.read_text(encoding="utf-8"))
except Exception as exc:
    raise SystemExit(f"[LWCompat] Failed to read manifest: {exc}")

old_cdn = data.get("bundle_url")
old_api = data.get("bundle_ver_url")

data["bundle_url"] = cdn_local
data["bundle_ver_url"] = api_local

fd, temp_name = tempfile.mkstemp(
    prefix="manifest.lwcompat.",
    suffix=".tmp",
    dir=str(manifest.parent),
)

try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, separators=(",", ":"))
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temp_name, manifest)
finally:
    try:
        os.unlink(temp_name)
    except FileNotFoundError:
        pass

print(f"[LWCompat] bundle_url     : {old_cdn} -> {cdn_local}")
print(f"[LWCompat] bundle_ver_url : {old_api} -> {api_local}")
PY

[[ $? -eq 0 ]] || die "Manifest patch failed."

log "Starting dual native bridge..."
: > "$PROXY_LOG"
python3 "$PROXY" >>"$PROXY_LOG" 2>&1 &
PROXY_PID=$!
echo "$PROXY_PID" > "$PROXY_PID_FILE"

sleep 0.2
kill -0 "$PROXY_PID" 2>/dev/null || die "Bridge failed to start. See: $PROXY_LOG"

log "Checking bridge ports..."
python3 <<'PY'
import socket
import sys
import time

for port in (18080, 18081):
    for _ in range(50):
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                break
        except OSError:
            time.sleep(0.1)
    else:
        print(f"[LWCompat] Port check failed: 127.0.0.1:{port}", file=sys.stderr)
        sys.exit(1)

print("[LWCompat] CDN bridge : 127.0.0.1:18080 OK")
print("[LWCompat] API bridge : 127.0.0.1:18081 OK")
PY

[[ $? -eq 0 ]] || {
    tail -n 50 "$PROXY_LOG" 2>/dev/null || true
    die "Bridge health check failed."
}

export WINEPREFIX="$PREFIX"
export PROTONPATH="$PROTON"
export GAMEID="umu-default"
export PROTONFIXES_DISABLE=1
export PROTON_VERB="waitforexitandrun"

# ------------------------------------------------------------
# Performance / cache tuning
# ------------------------------------------------------------

CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/lwcompat"
DXVK_CACHE="$CACHE_ROOT/dxvk"
NVIDIA_CACHE="$CACHE_ROOT/nvidia"
MESA_CACHE="$CACHE_ROOT/mesa"

mkdir -p "$DXVK_CACHE" "$NVIDIA_CACHE" "$MESA_CACHE"

# Keep DXVK pipeline/state cache in one persistent location.
export DXVK_STATE_CACHE_PATH="$DXVK_CACHE"
export DXVK_SHADER_CACHE_PATH="$DXVK_CACHE"

# Do not check/update Steam Runtime on every game launch.
# Runtime updates can still be performed manually when desired.
export UMU_RUNTIME_UPDATE=0

# Avoid unnecessary DXVK log files during normal gameplay.
export DXVK_LOG_LEVEL="${DXVK_LOG_LEVEL:-none}"

# NVIDIA shader cache.
# Ignored on systems that do not use the NVIDIA driver.
export __GL_SHADER_DISK_CACHE=1
export __GL_SHADER_DISK_CACHE_PATH="$NVIDIA_CACHE"

# Mesa shader cache.
# Ignored by NVIDIA's proprietary driver.
export MESA_SHADER_CACHE_DISABLE=false
export MESA_SHADER_CACHE_DIR="$MESA_CACHE"


# --- LWCompat overlay settings ---
SETTINGS_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/lwcompat/settings.conf"

LWCOMPAT_FPS=0
LWCOMPAT_HUD=0

if [[ -r "$SETTINGS_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$SETTINGS_FILE"
fi

[[ "$LWCOMPAT_FPS" == "1" ]] || LWCOMPAT_FPS=0
[[ "$LWCOMPAT_HUD" == "1" ]] || LWCOMPAT_HUD=0

if [[ "${LWCOMPAT_DEVELOPER:-0}" == "1" ]]; then
    # Developer builds intentionally expose maximum DXVK diagnostics.
    export DXVK_HUD="full"
    export DXVK_LOG_LEVEL="info"

    echo "[LWCompat] Developer mode : ACTIVE"
    echo "[LWCompat] DXVK HUD       : FULL"
else
    DXVK_HUD_ITEMS=()

    if [[ "$LWCOMPAT_FPS" == "1" ]]; then
        DXVK_HUD_ITEMS+=("fps")
    fi

    if [[ "$LWCOMPAT_HUD" == "1" ]]; then
        DXVK_HUD_ITEMS+=(
            "devinfo"
            "frametimes"
            "gpuload"
            "memory"
            "pipelines"
            "compiler"
        )
    fi

    if (( ${#DXVK_HUD_ITEMS[@]} > 0 )); then
        DXVK_HUD="$(
            IFS=,
            echo "${DXVK_HUD_ITEMS[*]}"
        )"

        export DXVK_HUD
    else
        unset DXVK_HUD
    fi

    echo "[LWCompat] FPS overlay    : $([[ "$LWCOMPAT_FPS" == "1" ]] && echo ON || echo OFF)"
    echo "[LWCompat] DXVK HUD       : $([[ "$LWCOMPAT_HUD" == "1" ]] && echo ON || echo OFF)"
fi
# --- end LWCompat overlay settings ---

# --- LWCompat Fast Asset Cache status ---
FAST_CACHE_TARGET="$PREFIX/drive_c/FunFly/Last War-Survival Game/Cache/AssetBundles"
FAST_CACHE_FSTYPE="$(findmnt -n -o FSTYPE -T "$FAST_CACHE_TARGET" 2>/dev/null || true)"
FAST_CACHE_SOURCE="$(findmnt -n -o SOURCE -T "$FAST_CACHE_TARGET" 2>/dev/null || true)"

if [[ "$FAST_CACHE_FSTYPE" == "ext4" && "$FAST_CACHE_SOURCE" == *"[/AssetBundles]"* ]]; then
    echo "[LWCompat] Fast Asset Cache: ACTIVE ($FAST_CACHE_SOURCE)"
else
    echo "[LWCompat] Fast Asset Cache: INACTIVE (fallback: ${FAST_CACHE_FSTYPE:-unknown})"
fi
# --- end Fast Asset Cache status ---



log "Wine prefix : $WINEPREFIX"
log "Proton      : $PROTONPATH"
log "Proxy log   : $PROXY_LOG"
log "Launching Last War..."

# The HTTPS CONNECT proxy is bootstrap-only. Never allow proxy variables
# from the parent shell or bootstrap session to leak into normal gameplay.
unset HTTPS_PROXY https_proxy
unset HTTP_PROXY http_proxy
unset ALL_PROXY all_proxy

echo
python3 "$UMU" "$EXE" &
UMU_PID=$!

wait "$UMU_PID"
EXIT_CODE=$?

while \
    pgrep -f '[L]astWarLauncher\.exe' >/dev/null 2>&1 || \
    pgrep -f '[L]astWar\.exe' >/dev/null 2>&1
do
    sleep 1
done

log "Last War session ended."
log "Exit code: $EXIT_CODE"
exit "$EXIT_CODE"
