#!/usr/bin/env bash
set -uo pipefail

APP_DIR="${LWCOMPAT_APP_DIR:-$HOME/.local/share/lwcompat}"
CONFIG="$APP_DIR/config.sh"
LOG_DIR="$APP_DIR/logs"
UPDATE="$APP_DIR/update.sh"

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

launch_clean() {
    : > "$LAUNCHER_LOG"

    log "Launching official Last War launcher..."

    python3 "$UMU" "$LAUNCHER" &
    UMU_PID=$!

    for _ in $(seq 1 1200); do
        if grep -Fq \
            'Starting game at:' \
            "$LAUNCHER_LOG" 2>/dev/null
        then
            log "Game launch authorized by official launcher."
            return 0
        fi

        if grep -Eq \
            'Launcher update required|Differences found , start update|Bundle version mismatch|Strict Game check: [0-9]+/[0-9]+ files match, [1-9][0-9]* replacements|Launcher error:|Failed to download file after retry|Failed to download zip manifest|Failed to load remote manifest|Failed to move downloaded bundle' \
            "$LAUNCHER_LOG" 2>/dev/null
        then
            log "Launcher requires update/recovery."
            return 10
        fi

        if ! kill -0 "$UMU_PID" 2>/dev/null; then
            log "Launcher exited before game startup."
            return 11
        fi

        sleep 0.25
    done

    log "Launcher startup timed out."
    return 12
}

log "LWCompat v0.2.0 starting..."
log "Wine prefix : $PREFIX"
log "Proton      : $PROTON"

launch_clean
RESULT=$?

if (( RESULT != 0 )); then
    run_updater

    # Updater leaves everything clean/current.
    # Start a fresh official launcher to generate the launch ticket.
    launch_clean
    RESULT=$?

    if (( RESULT != 0 )); then
        stop_prefix
        die "Launcher still failed after automatic update."
    fi
fi

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
