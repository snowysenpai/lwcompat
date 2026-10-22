#!/usr/bin/env bash
# Per-user overlay settings in ~/.config/lwcompat/settings.conf:
#   fps     DXVK FPS counter            (LWCOMPAT_FPS)
#   hud     DXVK performance HUD        (LWCOMPAT_HUD)
#   custom  LWCompat custom Vulkan HUD  (LWCOMPAT_CUSTOM_HUD)
#   wayland Wine's native Wayland driver (LWCOMPAT_WAYLAND)
#   fpslimit  DXVK frame rate cap, 0 = off (LWCOMPAT_FPS_LIMIT)
set -euo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/lwcompat"
CONFIG="$CONFIG_DIR/settings.conf"

FPS=0
HUD=0
CUSTOM=0
WAYLAND=0
LIMIT=0

load_config() {
    LWCOMPAT_FPS=0
    LWCOMPAT_HUD=0
    LWCOMPAT_CUSTOM_HUD=0
    LWCOMPAT_WAYLAND=0
    LWCOMPAT_FPS_LIMIT=0

    if [[ -r "$CONFIG" ]]; then
        # shellcheck disable=SC1090
        source "$CONFIG"
    fi

    FPS="$LWCOMPAT_FPS"
    HUD="$LWCOMPAT_HUD"
    CUSTOM="$LWCOMPAT_CUSTOM_HUD"
    WAYLAND="$LWCOMPAT_WAYLAND"
    LIMIT="$LWCOMPAT_FPS_LIMIT"

    [[ "$FPS" == "1" ]] || FPS=0
    [[ "$HUD" == "1" ]] || HUD=0
    [[ "$CUSTOM" == "1" ]] || CUSTOM=0
    [[ "$WAYLAND" == "1" ]] || WAYLAND=0
    valid_limit "$LIMIT" || LIMIT=0
}

# 0 (off) or a cap between 20 and 360 FPS.
valid_limit() {
    [[ "$1" == "0" ]] || { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 20 && $1 <= 360 )); }
}

# Writes every key this tool knows and keeps any other line untouched, so
# no setting is dropped when another one changes.
save_config() {
    mkdir -p "$CONFIG_DIR"

    local tmp
    tmp="$(mktemp "$CONFIG_DIR/settings.conf.XXXXXX")"

    {
        if [[ -r "$CONFIG" ]]; then
            grep -vE '^(LWCOMPAT_FPS|LWCOMPAT_HUD|LWCOMPAT_CUSTOM_HUD|LWCOMPAT_WAYLAND|LWCOMPAT_FPS_LIMIT)=' "$CONFIG" || true
        fi
        printf 'LWCOMPAT_FPS=%s\n' "$FPS"
        printf 'LWCOMPAT_HUD=%s\n' "$HUD"
        printf 'LWCOMPAT_CUSTOM_HUD=%s\n' "$CUSTOM"
        printf 'LWCOMPAT_WAYLAND=%s\n' "$WAYLAND"
        printf 'LWCOMPAT_FPS_LIMIT=%s\n' "$LIMIT"
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
    echo "WAYLAND : $(on_off "$WAYLAND")"
    if [[ "$LIMIT" == "0" ]]; then
        echo "FPS LIMIT : OFF"
    else
        echo "FPS LIMIT : $LIMIT"
    fi
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
        wayland) WAYLAND="$(new_value "$WAYLAND" "$2")" ;;
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

    fpslimit)
        [[ $# -ge 2 ]] || {
            echo "Usage: lwcompat-overlay fpslimit {off|20-360}" >&2
            exit 2
        }

        load_config
        value="$2"
        [[ "$value" == "off" ]] && value=0
        valid_limit "$value" || {
            echo "Invalid FPS limit: $2 (use off or 20-360)" >&2
            exit 2
        }
        LIMIT="$value"
        save_config
        show_status
        ;;

    fps|hud|custom|wayland)
        [[ $# -ge 2 ]] || {
            echo "Usage: lwcompat-overlay {fps|hud|custom|wayland} {on|off|toggle}" >&2
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
        echo "  lwcompat-overlay wayland {on|off|toggle}  Wine native Wayland driver (experimental)" >&2
        echo "  lwcompat-overlay fpslimit {off|20-360}    DXVK frame rate cap" >&2
        exit 2
        ;;
esac
