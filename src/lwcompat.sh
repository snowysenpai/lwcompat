#!/usr/bin/env bash
set -uo pipefail

APP_DIR="${LWCOMPAT_APP_DIR:-$HOME/.local/share/lwcompat}"
CONFIG="$APP_DIR/config.sh"
LOG_DIR="$APP_DIR/logs"
UPDATE="$APP_DIR/update.sh"
MANIFEST_FETCH="$APP_DIR/fetch_signed_manifest.py"

HUD_DIR="$APP_DIR/hud"
HUD_LAYER_NAME="VK_LAYER_LWCOMPAT_hud_spike"
HUD_MANIFEST="$HUD_DIR/VK_LAYER_LWCOMPAT_hud_spike.json"
HUD_LIBRARY="$HUD_DIR/liblwcompat_hud_spike.so"
HUD_FEED="$APP_DIR/network_feed.py"
HUD_LOG="$LOG_DIR/hud-network.log"
HUD_FEED_PID=""

mkdir -p "$LOG_DIR"

log() {
    printf '%(%H:%M:%S)T [LWCompat] %s\n' -1 "$*"
}

# Desktop notification for events the user would otherwise not see
# (the GUI window or desktop entry has no terminal). Best effort.
notify() {
    local urgency="$1"
    shift

    command -v notify-send >/dev/null 2>&1 || return 0

    local icon="$HOME/.local/share/icons/lastwar-lwcompat.png"
    [[ -f "$icon" ]] || icon="applications-games"

    notify-send -a LWCompat -u "$urgency" -i "$icon" \
        "Last War (LWCompat)" "$*" >/dev/null 2>&1 || true
}

die() {
    printf '%(%H:%M:%S)T [LWCompat] ERROR: %s\n' -1 "$*" >&2
    notify critical "$* Run lwcompat-doctor for details."
    exit 1
}

[[ -f "$CONFIG" ]] || die "Missing config: $CONFIG"

# shellcheck disable=SC1090
source "$CONFIG"

# shellcheck source=launcher_log.sh
source "$APP_DIR/launcher_log.sh" || die "Missing $APP_DIR/launcher_log.sh"

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

# Runs update.sh. Returns 0 when the update finished, or 10 when the
# updater's final resource sync already started the game cleanly (it is
# handed over instead of being killed and launched a second time).
run_updater() {
    log "Update/resource mismatch detected."
    log "Starting automatic LWCompat updater..."

    stop_prefix

    local keep_env=()

    # Keep the custom HUD layer for a game the updater hands over.
    if [[ -z "${HUD_FEED_PID:-}" ]]; then
        keep_env=(-u VK_LAYER_PATH -u VK_INSTANCE_LAYERS)
    fi

    env \
        -u HTTPS_PROXY \
        -u https_proxy \
        -u HTTP_PROXY \
        -u http_proxy \
        -u ALL_PROXY \
        -u all_proxy \
        "${keep_env[@]}" \
        -u MANGOHUD \
        -u MANGOHUD_CONFIG \
        -u MANGOHUD_CONFIGFILE \
        LWCOMPAT_UPDATE_HANDOFF=1 \
        "$UPDATE"

    local rc=$?

    case "$rc" in
        0)
            log "Automatic update completed."
            return 0
            ;;
        10)
            log "Automatic update completed; game already started."
            return 10
            ;;
        *)
            die "Automatic updater failed with exit code $rc."
            ;;
    esac
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
LWCOMPAT_CUSTOM_HUD=0
LWCOMPAT_WAYLAND=0

if [[ -r "$SETTINGS_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$SETTINGS_FILE"
fi

[[ "$LWCOMPAT_FPS" == "1" ]] || LWCOMPAT_FPS=0
[[ "$LWCOMPAT_HUD" == "1" ]] || LWCOMPAT_HUD=0
[[ "$LWCOMPAT_CUSTOM_HUD" == "1" ]] || LWCOMPAT_CUSTOM_HUD=0
[[ "$LWCOMPAT_WAYLAND" == "1" ]] || LWCOMPAT_WAYLAND=0

# Wine's native Wayland driver (experimental). Under XWayland, windowed
# Unity games can map clicks with an offset after the compositor resizes
# the window; winewayland sizes the window itself.
if [[ "$LWCOMPAT_WAYLAND" == "1" && -n "${WAYLAND_DISPLAY:-}" ]]; then
    export PROTON_ENABLE_WAYLAND=1
    log "Display driver : Wayland (winewayland)"
else
    unset PROTON_ENABLE_WAYLAND PROTON_USE_WAYLAND
    log "Display driver : X11 (XWayland)"
fi

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
      ( "$FAST_CACHE_SOURCE" == *"[/Cache]"* ||
        "$FAST_CACHE_SOURCE" == *"[/AssetBundles]"* )
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

# The CONNECT relay belongs to update.sh; make sure none is left behind
# (e.g. by an interrupted update) before the launcher runs without a proxy.
stop_connect_proxy() {
    pkill -f "$APP_DIR/connect_proxy.py" 2>/dev/null || true
}


stop_hud() {
    if [[ -n "${HUD_FEED_PID:-}" ]] &&
       kill -0 "$HUD_FEED_PID" 2>/dev/null
    then
        kill "$HUD_FEED_PID" 2>/dev/null || true

        for _ in {1..20}; do
            kill -0 "$HUD_FEED_PID" 2>/dev/null || break
            sleep 0.1
        done

        kill -9 "$HUD_FEED_PID" 2>/dev/null || true
        wait "$HUD_FEED_PID" 2>/dev/null || true
    fi

    HUD_FEED_PID=""
}


# Custom Vulkan HUD layer plus its network feed. Optional: any problem
# disables the HUD for this session instead of blocking the game.
start_hud() {
    # A truncated manifest makes the Vulkan loader skip the layer silently.
    grep -q '"library_path"' "$HUD_MANIFEST" 2>/dev/null || {
        log "HUD manifest missing or invalid: $HUD_MANIFEST"
        return 1
    }

    [[ -r "$HUD_LIBRARY" ]] || {
        log "HUD library missing: $HUD_LIBRARY"
        return 1
    }

    [[ -f "$HUD_FEED" ]] || {
        log "HUD network feed missing: $HUD_FEED"
        return 1
    }

    : > "$HUD_LOG"

    python3 "$HUD_FEED" --interval 0.75 >>"$HUD_LOG" 2>&1 &

    HUD_FEED_PID=$!

    sleep 0.2

    if ! kill -0 "$HUD_FEED_PID" 2>/dev/null; then
        log "HUD network feed failed to start."
        tail -30 "$HUD_LOG" >&2 || true
        HUD_FEED_PID=""
        return 1
    fi

    # Exported here so UMU/Proton discover the explicit layer at startup.
    export VK_LAYER_PATH="$HUD_DIR"
    export VK_INSTANCE_LAYERS="$HUD_LAYER_NAME"

    unset MANGOHUD
    unset MANGOHUD_CONFIG
    unset MANGOHUD_CONFIGFILE

    log "Custom Vulkan HUD: ACTIVE"
    log "HUD network feed: ACTIVE (PID $HUD_FEED_PID)"
}


runtime_cleanup() {
    stop_connect_proxy
    stop_hud
}

trap runtime_cleanup EXIT INT TERM


launch_clean() {
    : > "$LAUNCHER_LOG"

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

    UMU_PID=$!

    for _ in $(seq 1 1200); do
        case "$(launcher_log_state "$LAUNCHER_LOG")" in
            started)
                log "Game launch authorized by official launcher."
                return 0
                ;;
            update)
                log "Real update/resource mismatch detected."
                return 20
                ;;
            manifest-stall)
                # Wine < 11.6 schannel stalls on the signed remote manifest;
                # it is fetched natively by fetch_signed_manifest.
                log "Remote manifest download stalled inside Wine."
                return 21
                ;;
            transient)
                log "Transient launcher network failure detected."
                return 30
                ;;
        esac

        if ! kill -0 "$UMU_PID" 2>/dev/null; then
            log "Launcher exited before game startup."
            return 31
        fi

        sleep 0.25
    done

    log "Launcher startup timed out."
    return 32
}


fetch_signed_manifest() {
    [[ -f "$MANIFEST_FETCH" ]] || {
        log "Native manifest fetcher missing: $MANIFEST_FETCH"
        return 1
    }

    env \
        -u HTTPS_PROXY \
        -u https_proxy \
        -u HTTP_PROXY \
        -u http_proxy \
        -u ALL_PROXY \
        -u all_proxy \
        python3 "$MANIFEST_FETCH" \
        --game-dir "$GAME_DIR" \
        --launcher-log "$LAUNCHER_LOG" \
        --backup-dir "$APP_DIR/backups/manifests"
}

LWCOMPAT_VERSION="$(cat "$APP_DIR/VERSION" 2>/dev/null || echo unknown)"

log "LWCompat v$LWCOMPAT_VERSION starting..."
log "Wine prefix : $PREFIX"
log "Proton      : $PROTON"

MAX_LAUNCH_ATTEMPTS=20
UPDATE_ALREADY_RAN=0
MANIFEST_FETCHES=0
LAUNCH_OK=0

# Runtime gameplay/launcher path stays direct.
# 18083 is reserved for the updater only.
stop_connect_proxy

if [[ "$LWCOMPAT_CUSTOM_HUD" == "1" ]]; then
    if ! start_hud; then
        stop_hud
        unset VK_LAYER_PATH VK_INSTANCE_LAYERS
        log "Custom Vulkan HUD: UNAVAILABLE (continuing without it)"
    fi
else
    log "Custom Vulkan HUD: OFF"
fi

# Host fonts for scripts the prefix lacks (no-op once installed).
if [[ -x "$APP_DIR/prefix_fonts.sh" ]]; then
    "$APP_DIR/prefix_fonts.sh" "$PREFIX" "$PROTON/files/bin"
fi

for ATTEMPT in $(seq 1 "$MAX_LAUNCH_ATTEMPTS"); do
    log "Launcher attempt $ATTEMPT/$MAX_LAUNCH_ATTEMPTS"

    launch_clean
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
            notify normal "Game update found. Updating, this can take a few minutes..."

            UPDATE_ALREADY_RAN=1

            if run_updater; then
                log "Updater finished; returning to direct launcher."
                sleep 1
            else
                # rc 10: the game is already running from the updater.
                UMU_PID=""
                LAUNCH_OK=1
                break
            fi
            ;;

        21)
            stop_prefix
            stop_connect_proxy

            MANIFEST_FETCHES=$((MANIFEST_FETCHES + 1))

            if (( MANIFEST_FETCHES <= 3 )) && fetch_signed_manifest; then
                log "Signed manifest installed natively; retrying launcher..."
                notify low "New game manifest fetched; continuing launch."
            else
                log "Temporary Last War metadata timeout."
                log "Retrying launcher directly..."
            fi

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

EXIT_CODE=0

if [[ -n "${UMU_PID:-}" ]]; then
    wait "$UMU_PID"
    EXIT_CODE=$?
fi

while pgrep -x 'LastWar\.exe|LastWarLauncher' >/dev/null 2>&1
do
    sleep 1
done

log "Last War session ended."
log "Exit code: $EXIT_CODE"

exit "$EXIT_CODE"
