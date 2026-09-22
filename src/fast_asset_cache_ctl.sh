#!/usr/bin/env bash
set -euo pipefail

SERVICE="lwcompat-fast-asset-cache.service"
CONFIG="/etc/lwcompat/fast-asset-cache.conf"
HELPER="/usr/local/libexec/lwcompat-fast-asset-cache"

say() {
    printf '[LWCompat Fast Cache] %s\n' "$*"
}

fail() {
    printf '[LWCompat Fast Cache] ERROR: %s\n' "$*" >&2
    exit 1
}

game_running() {
    pgrep -f '[L]astWar\.exe|[L]astWarLauncher\.exe' >/dev/null 2>&1
}

require_installation() {
    [[ -f "$CONFIG" ]] ||
        fail "Fast Asset Cache is not installed. Run setup_fast_asset_cache.sh first."

    [[ -x "$HELPER" ]] ||
        fail "Fast Asset Cache helper is missing: $HELPER"

    systemctl cat "$SERVICE" >/dev/null 2>&1 ||
        fail "Fast Asset Cache systemd service is not installed."
}

show_status() {
    if [[ ! -f "$CONFIG" ]]; then
        echo "Fast Asset Cache: NOT INSTALLED"
        return 0
    fi

    # shellcheck disable=SC1090
    source "$CONFIG"

    local enabled="no"
    local active="no"
    local fs=""
    local src=""

    if systemctl is-enabled --quiet "$SERVICE" 2>/dev/null; then
        enabled="yes"
    fi

    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        active="yes"
    fi

    fs="$(findmnt -n -o FSTYPE -T "$TARGET" 2>/dev/null || true)"
    src="$(findmnt -n -o SOURCE -T "$TARGET" 2>/dev/null || true)"

    echo "=== LWCompat Fast Asset Cache ==="
    echo "Enabled : $enabled"
    echo "Service : $active"
    echo "FS      : ${fs:-unknown}"
    echo "Source  : ${src:-unknown}"

    if [[ "$fs" == "ext4" && "$src" == *"[/AssetBundles]"* ]]; then
        echo "Status  : ACTIVE"
    else
        echo "Status  : DISABLED / FALLBACK"
    fi
}

enable_cache() {
    require_installation

    if game_running; then
        fail "Last War is running. Close the game before enabling Fast Asset Cache."
    fi

    if systemctl is-active --quiet "$SERVICE" &&
       systemctl is-enabled --quiet "$SERVICE"; then
        say "Fast Asset Cache is already enabled."
        show_status
        return 0
    fi

    say "Enabling Fast Asset Cache..."

    sudo systemctl enable --now "$SERVICE"

    # shellcheck disable=SC1090
    source "$CONFIG"

    local fs src
    fs="$(findmnt -n -o FSTYPE -T "$TARGET" 2>/dev/null || true)"
    src="$(findmnt -n -o SOURCE -T "$TARGET" 2>/dev/null || true)"

    if [[ "$fs" != "ext4" || "$src" != *"[/AssetBundles]"* ]]; then
        fail "Service started, but Fast Asset Cache mount validation failed."
    fi

    say "Fast Asset Cache enabled."
    show_status
}

disable_cache() {
    require_installation

    if game_running; then
        fail "Last War is running. Close the game before disabling Fast Asset Cache."
    fi

    say "Disabling Fast Asset Cache..."

    sudo systemctl disable --now "$SERVICE"

    # shellcheck disable=SC1090
    source "$CONFIG"

    local fs
    fs="$(findmnt -n -o FSTYPE -T "$TARGET" 2>/dev/null || true)"

    if [[ "$fs" == "ext4" ]]; then
        fail "Fast Asset Cache service stopped, but the ext4 bind mount is still active."
    fi

    say "Fast Asset Cache disabled. Original filesystem is active."
    show_status
}

case "${1:-status}" in
    status)
        show_status
        ;;
    enable|on)
        enable_cache
        ;;
    disable|off)
        disable_cache
        ;;
    toggle)
        require_installation

        if systemctl is-active --quiet "$SERVICE"; then
            disable_cache
        else
            enable_cache
        fi
        ;;
    *)
        echo "Usage: lwcompat-fast-cache {status|enable|disable|toggle}" >&2
        exit 2
        ;;
esac
