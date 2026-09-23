#!/usr/bin/env bash
set -uo pipefail

APP_DIR="${LWCOMPAT_APP_DIR:-$HOME/.local/share/lwcompat}"
CONFIG="$APP_DIR/config.sh"
LOG_DIR="$APP_DIR/logs"
UPDATE="$APP_DIR/update.sh"
CONNECT_PROXY="$APP_DIR/connect_proxy.py"
CONNECT_LOG="$LOG_DIR/connect.log"
CONNECT_PID=""

mkdir -p "$LOG_DIR"

log() {
    printf '[LWCompat] %s\n' "$*"
}

die() {
    printf '[LWCompat] ERROR: %s\n' "$*" >&2
    exit 1
}

[[ -f "$CONFIG" ]] || die "Missing config: $CONFIG"

# shellcheck disable=SC1090
source "$CONFIG"

GAME_DIR="$LWCOMPAT_GAME_DIR"
PREFIX="$LWCOMPAT_PREFIX"
UMU="$LWCOMPAT_UMU"
PROTON="$LWCOMPAT_PROTON"

LAUNCHER="$GAME_DIR/LastWarLauncher.exe"
LAUNCHER_LOG="$GAME_DIR/Launcher.log"

[[ -d "$PREFIX" ]] || die "Wine prefix not found: $PREFIX"
[[ -f "$LAUNCHER" ]] || die "Launcher not found: $LAUNCHER"
[[ -f "$UMU" ]] || die "UMU not found: $UMU"
[[ -d "$PROTON" ]] || die "Proton not found: $PROTON"
[[ -x "$UPDATE" ]] || die "Updater not found: $UPDATE"

stop_prefix() {
    if [[ -x "$PROTON/files/bin/wineserver" ]]; then
        WINEPREFIX="$PREFIX" \
            "$PROTON/files/bin/wineserver" -k \
            >/dev/null 2>&1 || true
    fi

    pkill -f '[L]astWarLauncher\.exe' 2>/dev/null || true
    pkill -f '[L]astWar\.exe' 2>/dev/null || true

    sleep 1
}

run_updater() {
    log "Update/resource mismatch detected."
    log "Starting automatic LWCompat updater..."

    stop_prefix

    env \
        -u HTTPS_PROXY \
        -u https_proxy \
        -u HTTP_PROXY \
        -u http_proxy \
        -u ALL_PROXY \
        -u all_proxy \
        -u VK_LAYER_PATH \
        -u VK_INSTANCE_LAYERS \
        -u MANGOHUD \
        -u MANGOHUD_CONFIG \
        -u MANGOHUD_CONFIGFILE \
        "$UPDATE"

    local rc=$?

    if (( rc != 0 )); then
        die "Automatic updater failed with exit code $rc."
    fi

    log "Automatic update completed."
}

export WINEPREFIX="$PREFIX"
export PROTONPATH="$PROTON"
export GAMEID="umu-default"
export PROTONFIXES_DISABLE=1
export PROTON_VERB="waitforexitandrun"

CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/lwcompat"
DXVK_CACHE="$CACHE_ROOT/dxvk"
NVIDIA_CACHE="$CACHE_ROOT/nvidia"
MESA_CACHE="$CACHE_ROOT/mesa"

mkdir -p \
    "$DXVK_CACHE" \
    "$NVIDIA_CACHE" \
    "$MESA_CACHE"

export DXVK_STATE_CACHE_PATH="$DXVK_CACHE"
export DXVK_SHADER_CACHE_PATH="$DXVK_CACHE"

export UMU_RUNTIME_UPDATE=0
export DXVK_LOG_LEVEL="${DXVK_LOG_LEVEL:-none}"

export __GL_SHADER_DISK_CACHE=1
export __GL_SHADER_DISK_CACHE_PATH="$NVIDIA_CACHE"

export MESA_SHADER_CACHE_DISABLE=false
export MESA_SHADER_CACHE_DIR="$MESA_CACHE"

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
    export DXVK_HUD="full"
    export DXVK_LOG_LEVEL="info"

    log "Developer mode : ACTIVE"
    log "DXVK HUD       : FULL"
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

    log "FPS overlay : $([[ "$LWCOMPAT_FPS" == "1" ]] && echo ON || echo OFF)"
    log "DXVK HUD    : $([[ "$LWCOMPAT_HUD" == "1" ]] && echo ON || echo OFF)"
fi

FAST_CACHE_TARGET="$PREFIX/drive_c/FunFly/Last War-Survival Game/Cache/AssetBundles"

FAST_CACHE_FSTYPE="$(
    findmnt -n -o FSTYPE \
        -T "$FAST_CACHE_TARGET" \
        2>/dev/null || true
)"

FAST_CACHE_SOURCE="$(
    findmnt -n -o SOURCE \
        -T "$FAST_CACHE_TARGET" \
        2>/dev/null || true
)"

if [[ "$FAST_CACHE_FSTYPE" == "ext4" &&
      "$FAST_CACHE_SOURCE" == *"[/AssetBundles]"*
]]
then
    log "Fast Asset Cache: ACTIVE"
else
    log "Fast Asset Cache: INACTIVE"
fi

# Normal gameplay must never inherit bootstrap/update proxies.
unset HTTPS_PROXY https_proxy
unset HTTP_PROXY http_proxy
unset ALL_PROXY all_proxy
unset NO_PROXY no_proxy

wait_connect_port() {
    python3 - <<'PY2'
import socket
import time

for _ in range(100):
    try:
        with socket.create_connection(
            ("127.0.0.1", 18083),
            timeout=0.2,
        ):
            raise SystemExit(0)
    except OSError:
        time.sleep(0.1)

raise SystemExit(1)
PY2
}


stop_connect_proxy() {
    if [[ -n "${CONNECT_PID:-}" ]] &&
       kill -0 "$CONNECT_PID" 2>/dev/null
    then
        kill "$CONNECT_PID" 2>/dev/null || true

        for _ in {1..30}; do
            kill -0 "$CONNECT_PID" 2>/dev/null || break
            sleep 0.1
        done

        kill -9 "$CONNECT_PID" 2>/dev/null || true
    fi

    CONNECT_PID=""

    # Only kill LWCompat's installed launcher bridge.
    pkill -f "$APP_DIR/connect_proxy.py" 2>/dev/null || true
}


start_connect_proxy() {
    stop_connect_proxy

    [[ -f "$CONNECT_PROXY" ]] || {
        log "Launcher network bridge missing: $CONNECT_PROXY"
        return 1
    }

    : > "$CONNECT_LOG"

    python3 "$CONNECT_PROXY" \
        >>"$CONNECT_LOG" 2>&1 &

    CONNECT_PID=$!

    if ! wait_connect_port; then
        tail -30 "$CONNECT_LOG" >&2 || true
        stop_connect_proxy
        return 1
    fi

    log "Launcher network bridge: 127.0.0.1:18083"
}


runtime_cleanup() {
    stop_connect_proxy
}

trap runtime_cleanup EXIT INT TERM


launch_clean() {
    local mode="${1:-direct}"

    : > "$LAUNCHER_LOG"

    if [[ "$mode" == "proxy" ]]; then
        start_connect_proxy || return 40

        log "Launching official launcher with network bridge..."

        env \
            -u HTTP_PROXY \
            -u http_proxy \
            -u ALL_PROXY \
            -u all_proxy \
            HTTPS_PROXY="http://127.0.0.1:18083" \
            https_proxy="http://127.0.0.1:18083" \
            NO_PROXY="127.0.0.1,localhost" \
            no_proxy="127.0.0.1,localhost" \
            python3 "$UMU" "$LAUNCHER" &

    else
        stop_connect_proxy

        log "Launching official launcher directly..."

        env \
            -u HTTPS_PROXY \
            -u https_proxy \
            -u HTTP_PROXY \
            -u http_proxy \
            -u ALL_PROXY \
            -u all_proxy \
            -u NO_PROXY \
            -u no_proxy \
            python3 "$UMU" "$LAUNCHER" &
    fi

    UMU_PID=$!

    for _ in $(seq 1 1200); do
        if grep -Fq \
            'Starting game at:' \
            "$LAUNCHER_LOG" 2>/dev/null
        then
            log "Game launch authorized by official launcher."
            return 0
        fi

        # Genuine update state.
        if grep -Eq \
            'Launcher update required|Differences found , start update|Bundle version mismatch|Strict Game check: [0-9]+/[0-9]+ files match, [1-9][0-9]* replacements|Failed to move downloaded bundle to final destination' \
            "$LAUNCHER_LOG" 2>/dev/null
        then
            log "Real update/resource mismatch detected."
            return 20
        fi

        # Transient Last War launcher networking problem.
        if grep -Eq \
            'Failed to get remote .* version info|Failed to load remote manifest|Failed to download zip manifest|NetSpeedError|error decoding response body|operation timed out|source: TimedOut|Launcher error:' \
            "$LAUNCHER_LOG" 2>/dev/null
        then
            log "Transient launcher network failure detected."
            return 30
        fi

        if ! kill -0 "$UMU_PID" 2>/dev/null; then
            log "Launcher exited before game startup."
            return 31
        fi

        sleep 0.25
    done

    log "Launcher startup timed out."
    return 32
}

log "LWCompat v0.2.3 starting..."
log "Wine prefix : $PREFIX"
log "Proton      : $PROTON"

MAX_LAUNCH_ATTEMPTS=20
UPDATE_ALREADY_RAN=0
LAUNCH_OK=0

# Runtime gameplay/launcher path stays direct.
# 18083 is reserved for the updater only.
stop_connect_proxy

for ATTEMPT in $(seq 1 "$MAX_LAUNCH_ATTEMPTS"); do
    log "Launcher attempt $ATTEMPT/$MAX_LAUNCH_ATTEMPTS"

    launch_clean "direct"
    RESULT=$?

    case "$RESULT" in
        0)
            LAUNCH_OK=1
            break
            ;;

        20)
            stop_prefix
            stop_connect_proxy

            if (( UPDATE_ALREADY_RAN == 1 )); then
                die "Real update/resource mismatch still exists after updater."
            fi

            log "Real update detected. Running updater..."

            run_updater
            UPDATE_ALREADY_RAN=1

            log "Updater finished; returning to direct launcher."
            sleep 1
            ;;

        30)
            stop_prefix
            stop_connect_proxy

            log "Temporary Last War metadata timeout."
            log "Game files are current; retrying launcher directly..."

            sleep 1
            ;;

        31|32)
            stop_prefix
            stop_connect_proxy

            log "Launcher exited before game startup."
            log "Retrying directly..."

            sleep 1
            ;;

        *)
            stop_prefix
            stop_connect_proxy

            die "Unexpected launcher state: $RESULT"
            ;;
    esac
done

if (( LAUNCH_OK != 1 )); then
    stop_prefix
    stop_connect_proxy

    die "Launcher could not start the game after $MAX_LAUNCH_ATTEMPTS attempts."
fi

# Critical: update proxy must never leak into gameplay.
stop_connect_proxy

unset HTTPS_PROXY https_proxy
unset HTTP_PROXY http_proxy
unset ALL_PROXY all_proxy
unset NO_PROXY no_proxy

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
