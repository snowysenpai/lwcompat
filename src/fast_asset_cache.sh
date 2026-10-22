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

# The whole launcher Cache directory is bound from the image, not only
# AssetBundles: the launcher downloads into Cache/AssetBundles.Temp and
# renames into Cache/AssetBundles, and rename(2) fails with EXDEV across
# filesystems or separate bind mounts (Wine: ERROR_NOT_SAME_DEVICE).
CACHE_TARGET="$(dirname -- "$TARGET")"
IMAGE_CACHE="$MNT/Cache"
IMAGE_BUNDLES="$IMAGE_CACHE/AssetBundles"
LEGACY_BUNDLES="$MNT/AssetBundles"

# Top-level Cache entries mirrored as empty directories inside the image.
CACHE_DIRS=(AssetBundles.Temp warmup)

mount_image() {
    mkdir -p "$MNT"

    if ! mountpoint -q "$MNT"; then
        log "Mounting ext4 casefold image..."
        mount -o loop,noatime "$FAST_IMG" "$MNT"
        return 0
    fi

    return 1
}

make_casefold_dir() {
    local dir="$1"
    local owner="$2"

    [[ -d "$dir" ]] && return 0

    mkdir "$dir"
    chown "$owner" "$dir"
    chattr +F "$dir"
}

# Convert the legacy image layout (/AssetBundles) to /Cache/AssetBundles.
# Same filesystem, so this is a rename, not a copy.
prepare_layout() {
    local owner

    if [[ ! -d "$IMAGE_BUNDLES" ]]; then
        [[ -d "$LEGACY_BUNDLES" ]] ||
            die "AssetBundles directory missing inside image."

        log "Migrating image layout to Cache-level mount..."

        owner="$(stat -c '%u:%g' "$LEGACY_BUNDLES")"

        mkdir -p "$IMAGE_CACHE"
        chown "$owner" "$IMAGE_CACHE"
        mv "$LEGACY_BUNDLES" "$IMAGE_BUNDLES"
    fi

    owner="$(stat -c '%u:%g' "$IMAGE_BUNDLES")"

    for name in "${CACHE_DIRS[@]}"; do
        make_casefold_dir "$IMAGE_CACHE/$name" "$owner"
    done

    attrs="$(lsattr -d "$IMAGE_BUNDLES" 2>/dev/null | awk '{print $1}')"

    [[ "$attrs" == *F* ]] ||
        die "AssetBundles inside image does not have the casefold (F) attribute."
}

active_source() {
    findmnt -n -o SOURCE -T "$TARGET" 2>/dev/null || true
}

start_cache() {
    [[ -f "$FAST_IMG" ]] || die "Image not found: $FAST_IMG"
    [[ -d "$TARGET" ]] || die "AssetBundles target not found: $TARGET"

    if mountpoint -q "$CACHE_TARGET"; then
        if [[ "$(active_source)" == *"[/Cache]"* ]]; then
            log "Fast Asset Cache already active."
            return 0
        fi

        die "Cache directory is already mounted by something else: $(active_source)"
    fi

    # Legacy AssetBundles-only bind left behind by an older helper.
    if mountpoint -q "$TARGET"; then
        log "Removing legacy AssetBundles bind mount..."
        umount "$TARGET"
    fi

    mount_image || true
    prepare_layout

    log "Binding Fast Asset Cache to launcher Cache directory..."
    mount --bind "$IMAGE_CACHE" "$CACHE_TARGET"

    log "Fast Asset Cache active:"
    findmnt -T "$CACHE_TARGET"
}

stop_cache() {
    if mountpoint -q "$CACHE_TARGET"; then
        log "Unmounting Cache bind mount..."
        umount "$CACHE_TARGET"
    fi

    if mountpoint -q "$TARGET"; then
        log "Unmounting legacy AssetBundles bind mount..."
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

    if mountpoint -q "$CACHE_TARGET" || mountpoint -q "$TARGET"; then
        die "Fast Asset Cache must be disabled before refresh."
    fi

    local mounted_here=0
    local rc=0

    if mount_image; then
        mounted_here=1
    fi

    prepare_layout

    log "Refreshing Fast Asset Cache from updated game data..."

    rsync \
        -a \
        --delete \
        --info=stats2 \
        "$TARGET/" \
        "$IMAGE_BUNDLES/" || rc=$?

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
    echo "Target: $CACHE_TARGET"
    echo "Mount : $MNT"
    echo

    if mountpoint -q "$CACHE_TARGET" || mountpoint -q "$TARGET"; then
        echo "Status: ACTIVE"
        findmnt -T "$TARGET"
    else
        echo "Status: INACTIVE"
        echo "Original Cache directory is being used."
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
