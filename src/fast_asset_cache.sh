#!/usr/bin/env bash

set -euo pipefail

CONFIG="/etc/lwcompat/fast-asset-cache.conf"

die() {
    echo "[LWCompat Fast Cache] ERROR: $*" >&2
    exit 1
}

log() {
    echo "[LWCompat Fast Cache] $*"
}

[[ -r "$CONFIG" ]] || die "Config not found: $CONFIG"

# shellcheck disable=SC1090
source "$CONFIG"

: "${FAST_IMG:?FAST_IMG is not configured}"
: "${TARGET:?TARGET is not configured}"

MNT="${MNT:-/mnt/lwcompat-assetbundles}"

start_cache() {
    [[ -f "$FAST_IMG" ]] || die "Image not found: $FAST_IMG"
    [[ -d "$TARGET" ]] || die "AssetBundles target not found: $TARGET"

    mkdir -p "$MNT"

    # Already active: leave it alone.
    if mountpoint -q "$TARGET"; then
        fs="$(findmnt -n -o FSTYPE -T "$TARGET" 2>/dev/null || true)"
        src="$(findmnt -n -o SOURCE -T "$TARGET" 2>/dev/null || true)"

        if [[ "$fs" == "ext4" && "$src" == *"[/AssetBundles]"* ]]; then
            log "Fast Asset Cache already active."
            return 0
        fi

        die "Target is already mounted by something else: $src ($fs)"
    fi

    if ! mountpoint -q "$MNT"; then
        log "Mounting ext4 casefold image..."
        mount -o loop,noatime "$FAST_IMG" "$MNT"
    fi

    [[ -d "$MNT/AssetBundles" ]] ||
        die "AssetBundles directory missing inside image."

    attrs="$(lsattr -d "$MNT/AssetBundles" 2>/dev/null | awk '{print $1}')"

    [[ "$attrs" == *F* ]] ||
        die "AssetBundles inside image does not have the casefold (F) attribute."

    log "Binding Fast Asset Cache to game directory..."
    mount --bind "$MNT/AssetBundles" "$TARGET"

    log "Fast Asset Cache active:"
    findmnt -T "$TARGET"
}

stop_cache() {
    if mountpoint -q "$TARGET"; then
        log "Unmounting AssetBundles bind mount..."
        umount "$TARGET"
    fi

    if mountpoint -q "$MNT"; then
        log "Unmounting ext4 image..."
        umount "$MNT"
    fi

    log "Fast Asset Cache stopped. Original Btrfs cache is visible."
}

sync_cache() {
    [[ -f "$FAST_IMG" ]] || die "Image not found: $FAST_IMG"
    [[ -d "$TARGET" ]] || die "AssetBundles target not found: $TARGET"

    if mountpoint -q "$TARGET"; then
        die "Fast Asset Cache must be disabled before refresh."
    fi

    mkdir -p "$MNT"

    local mounted_here=0
    local rc=0

    if ! mountpoint -q "$MNT"; then
        log "Mounting ext4 image for refresh..."
        mount -o loop,noatime "$FAST_IMG" "$MNT"
        mounted_here=1
    fi

    [[ -d "$MNT/AssetBundles" ]] ||
        die "AssetBundles directory missing inside image."

    log "Refreshing Fast Asset Cache from updated game data..."

    rsync \
        -a \
        --delete \
        --info=stats2 \
        "$TARGET/" \
        "$MNT/AssetBundles/" || rc=$?

    sync

    if (( mounted_here == 1 )); then
        log "Unmounting ext4 image..."
        umount "$MNT" || rc=$?
    fi

    if (( rc != 0 )); then
        die "Fast Asset Cache refresh failed."
    fi

    log "Fast Asset Cache refresh completed."
}

status_cache() {
    echo "=== LWCompat Fast Asset Cache ==="
    echo "Image : $FAST_IMG"
    echo "Target: $TARGET"
    echo "Mount : $MNT"
    echo

    if mountpoint -q "$TARGET"; then
        echo "Status: ACTIVE"
        findmnt -T "$TARGET"
    else
        echo "Status: INACTIVE"
        echo "Original AssetBundles directory is being used."
    fi
}

case "${1:-status}" in
    start)
        start_cache
        ;;
    stop)
        stop_cache
        ;;
    restart)
        stop_cache
        start_cache
        ;;
    status)
        status_cache
        ;;
    sync|refresh)
        sync_cache
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|refresh}" >&2
        exit 2
        ;;
esac
