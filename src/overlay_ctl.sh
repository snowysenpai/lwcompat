#!/usr/bin/env bash
# Per-user overlay settings in ~/.config/lwcompat/settings.conf:
#   fps     DXVK FPS counter            (LWCOMPAT_FPS)
#   hud     DXVK performance HUD        (LWCOMPAT_HUD)
#   custom  LWCompat custom Vulkan HUD  (LWCOMPAT_CUSTOM_HUD)
set -euo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/lwcompat"
CONFIG="$CONFIG_DIR/settings.conf"

FPS=0
HUD=0
CUSTOM=0

load_config() {
    LWCOMPAT_FPS=0
    LWCOMPAT_HUD=0
    LWCOMPAT_CUSTOM_HUD=0

    if [[ -r "$CONFIG" ]]; then
        # shellcheck disable=SC1090
        source "$CONFIG"
    fi

    FPS="$LWCOMPAT_FPS"
    HUD="$LWCOMPAT_HUD"
    CUSTOM="$LWCOMPAT_CUSTOM_HUD"

    [[ "$FPS" == "1" ]] || FPS=0
    [[ "$HUD" == "1" ]] || HUD=0
    [[ "$CUSTOM" == "1" ]] || CUSTOM=0
}

# Rewrites every known key so none is dropped when another one changes.
save_config() {
    mkdir -p "$CONFIG_DIR"

    local tmp
    tmp="$(mktemp "$CONFIG_DIR/settings.conf.XXXXXX")"

    {
        printf 'LWCOMPAT_FPS=%s\n' "$FPS"
        printf 'LWCOMPAT_HUD=%s\n' "$HUD"
        printf 'LWCOMPAT_CUSTOM_HUD=%s\n' "$CUSTOM"
    } > "$tmp"

    chmod 0600 "$tmp"
    mv -f "$tmp" "$CONFIG"
}

on_off() {
    [[ "$1" == "1" ]] && echo ON || echo OFF
}

show_status() {
    load_config

    # The GUI matches these lines exactly.
    echo "=== LWCompat Overlays ==="
    echo "FPS : $(on_off "$FPS")"
    echo "HUD : $(on_off "$HUD")"
    echo "CUSTOM HUD : $(on_off "$CUSTOM")"
}

# new_value current requested -> prints 0/1
new_value() {
    case "$2" in
        on|1|yes|true) echo 1 ;;
        off|0|no|false) echo 0 ;;
        toggle) [[ "$1" == "1" ]] && echo 0 || echo 1 ;;
        *)
            echo "Invalid state: $2" >&2
            exit 2
            ;;
    esac
}

set_value() {
    load_config

    case "$1" in
        fps) FPS="$(new_value "$FPS" "$2")" ;;
        hud) HUD="$(new_value "$HUD" "$2")" ;;
        custom) CUSTOM="$(new_value "$CUSTOM" "$2")" ;;
        *)
            echo "Unknown overlay: $1" >&2
            exit 2
            ;;
    esac

    save_config
    show_status
}

case "${1:-status}" in
    status)
        show_status
        ;;

    fps|hud|custom)
        [[ $# -ge 2 ]] || {
            echo "Usage: lwcompat-overlay {fps|hud|custom} {on|off|toggle}" >&2
            exit 2
        }

        set_value "$1" "$2"
        ;;

    *)
        echo "Usage:" >&2
        echo "  lwcompat-overlay status" >&2
        echo "  lwcompat-overlay fps {on|off|toggle}      DXVK FPS counter" >&2
        echo "  lwcompat-overlay hud {on|off|toggle}      DXVK performance HUD" >&2
        echo "  lwcompat-overlay custom {on|off|toggle}   LWCompat custom Vulkan HUD" >&2
        exit 2
        ;;
esac
