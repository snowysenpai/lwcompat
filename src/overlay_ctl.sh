#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/lwcompat"
CONFIG="$CONFIG_DIR/settings.conf"

FPS=0
HUD=0

load_config() {
    if [[ -r "$CONFIG" ]]; then
        # shellcheck disable=SC1090
        source "$CONFIG"
    fi

    FPS="${LWCOMPAT_FPS:-0}"
    HUD="${LWCOMPAT_HUD:-0}"

    [[ "$FPS" == "1" ]] || FPS=0
    [[ "$HUD" == "1" ]] || HUD=0
}

save_config() {
    mkdir -p "$CONFIG_DIR"

    local tmp
    tmp="$(mktemp "$CONFIG_DIR/settings.conf.XXXXXX")"

    {
        printf 'LWCOMPAT_FPS=%s\n' "$FPS"
        printf 'LWCOMPAT_HUD=%s\n' "$HUD"
    } > "$tmp"

    chmod 0600 "$tmp"
    mv -f "$tmp" "$CONFIG"
}

show_status() {
    load_config

    echo "=== LWCompat Overlays ==="

    if [[ "$FPS" == "1" ]]; then
        echo "FPS : ON"
    else
        echo "FPS : OFF"
    fi

    if [[ "$HUD" == "1" ]]; then
        echo "HUD : ON"
    else
        echo "HUD : OFF"
    fi
}

set_value() {
    local target="$1"
    local value="$2"

    load_config

    case "$value" in
        on|1|yes|true)
            value=1
            ;;
        off|0|no|false)
            value=0
            ;;
        toggle)
            ;;
        *)
            echo "Invalid state: $value" >&2
            exit 2
            ;;
    esac

    case "$target" in
        fps)
            if [[ "$value" == "toggle" ]]; then
                if [[ "$FPS" == "1" ]]; then
                    FPS=0
                else
                    FPS=1
                fi
            else
                FPS="$value"
            fi
            ;;
        hud)
            if [[ "$value" == "toggle" ]]; then
                if [[ "$HUD" == "1" ]]; then
                    HUD=0
                else
                    HUD=1
                fi
            else
                HUD="$value"
            fi
            ;;
        *)
            echo "Unknown overlay: $target" >&2
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

    fps|hud)
        [[ $# -ge 2 ]] || {
            echo "Usage: lwcompat-overlay {fps|hud} {on|off|toggle}" >&2
            exit 2
        }

        set_value "$1" "$2"
        ;;

    *)
        echo "Usage:" >&2
        echo "  lwcompat-overlay status" >&2
        echo "  lwcompat-overlay fps {on|off|toggle}" >&2
        echo "  lwcompat-overlay hud {on|off|toggle}" >&2
        exit 2
        ;;
esac
