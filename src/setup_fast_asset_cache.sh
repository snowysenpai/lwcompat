#!/usr/bin/env bash

set -euo pipefail

log() {
    echo "[LWCompat Fast Cache Setup] $*"
}

die() {
    echo "[LWCompat Fast Cache Setup] ERROR: $*" >&2
    exit 1
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

HELPER_SRC="$SCRIPT_DIR/fast_asset_cache.sh"

if [[ -f "$SCRIPT_DIR/../systemd/lwcompat-fast-asset-cache.service" ]]; then
    SERVICE_SRC="$SCRIPT_DIR/../systemd/lwcompat-fast-asset-cache.service"
else
    SERVICE_SRC="$SCRIPT_DIR/lwcompat-fast-asset-cache.service"
fi

PREFIX="${LWCOMPAT_PREFIX:-$HOME/Games/LastWar}"

TARGET="$PREFIX/drive_c/FunFly/Last War-Survival Game/Cache/AssetBundles"

FAST_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/lwcompat/fast-cache"
FAST_IMG="$FAST_ROOT/assetbundles.ext4"

MNT="/mnt/lwcompat-assetbundles"

# The helper binds the image's Cache directory over the launcher's Cache
# directory so AssetBundles.Temp -> AssetBundles renames stay on one mount.
IMAGE_CACHE="$MNT/Cache"
IMAGE_BUNDLES="$IMAGE_CACHE/AssetBundles"

CONFIG_DIR="/etc/lwcompat"
CONFIG="$CONFIG_DIR/fast-asset-cache.conf"

SYSTEM_HELPER="/usr/local/libexec/lwcompat-fast-asset-cache"
SYSTEM_SERVICE="/etc/systemd/system/lwcompat-fast-asset-cache.service"
SERVICE_NAME="lwcompat-fast-asset-cache.service"

GIB=$((1024 * 1024 * 1024))

for cmd in \
    sudo mkfs.ext4 chattr lsattr rsync \
    mount umount mountpoint findmnt systemctl \
    truncate du df find pgrep
do
    command -v "$cmd" >/dev/null 2>&1 ||
        die "Required command not found: $cmd"
done

[[ -x "$HELPER_SRC" ]] ||
    die "Helper not found: $HELPER_SRC"

[[ -f "$SERVICE_SRC" ]] ||
    die "systemd service not found: $SERVICE_SRC"

[[ -d "$TARGET" ]] ||
    die "AssetBundles directory not found: $TARGET"

if pgrep -x 'LastWar\.exe|LastWarLauncher' >/dev/null 2>&1; then
    die "Last War is running. Close the game and launcher first."
fi

log "Target : $TARGET"
log "Image  : $FAST_IMG"
echo

sudo -v

mkdir -p "$FAST_ROOT"

TARGET_FS="$(findmnt -n -o FSTYPE -T "$TARGET" 2>/dev/null || true)"
TARGET_SOURCE="$(findmnt -n -o SOURCE -T "$TARGET" 2>/dev/null || true)"

FAST_ACTIVE=0

if [[ "$TARGET_FS" == "ext4" &&
      ( "$TARGET_SOURCE" == *"[/Cache]"* || "$TARGET_SOURCE" == *"[/AssetBundles]"* ) ]]; then
    FAST_ACTIVE=1
    log "Existing Fast Asset Cache is currently active."
fi

NEW_IMAGE=0

if [[ ! -f "$FAST_IMG" ]]; then
    log "No Fast Asset Cache image found."

    SOURCE_BYTES="$(du -s -B1 "$TARGET" | awk '{print $1}')"
    SOURCE_GIB=$(( (SOURCE_BYTES + GIB - 1) / GIB ))

    EXTRA_GIB=$(( SOURCE_GIB / 2 ))

    if (( EXTRA_GIB < 4 )); then
        EXTRA_GIB=4
    fi

    IMAGE_GIB=$(( SOURCE_GIB + EXTRA_GIB ))

    if (( IMAGE_GIB < 12 )); then
        IMAGE_GIB=12
    fi

    if [[ -n "${LWCOMPAT_FAST_CACHE_SIZE_GB:-}" ]]; then
        IMAGE_GIB="$LWCOMPAT_FAST_CACHE_SIZE_GB"
    fi

    AVAILABLE_BYTES="$(df -B1 --output=avail "$FAST_ROOT" | tail -n1 | tr -d ' ')"
    REQUIRED_BYTES=$(( SOURCE_BYTES + GIB ))

    if (( AVAILABLE_BYTES < REQUIRED_BYTES )); then
        die "Not enough free space to migrate AssetBundles."
    fi

    ROOT_FS="$(findmnt -n -o FSTYPE -T "$FAST_ROOT" 2>/dev/null || true)"

    if [[ "$ROOT_FS" == "btrfs" ]]; then
        log "Btrfs detected; enabling NOCOW for new Fast Cache files..."
        sudo chattr +C "$FAST_ROOT" 2>/dev/null || true
    fi

    log "Creating ${IMAGE_GIB} GiB sparse ext4 casefold image..."

    truncate -s "${IMAGE_GIB}G" "$FAST_IMG"

    mkfs.ext4 \
        -q \
        -F \
        -m 0 \
        -O casefold \
        -E encoding=utf8 \
        "$FAST_IMG"

    NEW_IMAGE=1
else
    log "Existing image found; it will not be recreated."
fi

TEMP_MOUNTED=0

if (( FAST_ACTIVE == 0 )); then
    sudo mkdir -p "$MNT"

    if ! mountpoint -q "$MNT"; then
        log "Mounting Fast Cache image temporarily..."

        sudo mount \
            -o loop,noatime \
            "$FAST_IMG" \
            "$MNT"

        TEMP_MOUNTED=1
    fi

    sudo mkdir -p "$IMAGE_CACHE"
    sudo chown "$(id -u):$(id -g)" "$IMAGE_CACHE"

    if [[ ! -d "$IMAGE_BUNDLES" && -d "$MNT/AssetBundles" ]]; then
        log "Migrating legacy image layout to Cache-level mount..."
        sudo mv "$MNT/AssetBundles" "$IMAGE_BUNDLES"
    fi

    for dir in AssetBundles AssetBundles.Temp warmup; do
        if [[ ! -d "$IMAGE_CACHE/$dir" ]]; then
            log "Creating casefold-enabled $dir directory..."

            sudo mkdir "$IMAGE_CACHE/$dir"
            sudo chown "$(id -u):$(id -g)" "$IMAGE_CACHE/$dir"
            sudo chattr +F "$IMAGE_CACHE/$dir"
        fi
    done

    ATTRS="$(lsattr -d "$IMAGE_BUNDLES" 2>/dev/null | awk '{print $1}')"

    [[ "$ATTRS" == *F* ]] ||
        die "Casefold attribute is not active on $IMAGE_BUNDLES"

    FAST_COUNT="$(
        find "$IMAGE_BUNDLES" \
            -maxdepth 1 \
            -type f \
            -printf '.' 2>/dev/null |
        wc -c
    )"

    if (( NEW_IMAGE == 1 || FAST_COUNT == 0 )); then
        SOURCE_COUNT="$(
            find "$TARGET" \
                -maxdepth 1 \
                -type f \
                -printf '.' |
            wc -c
        )"

        log "Migrating $SOURCE_COUNT AssetBundle files..."
        log "This is a one-time operation."

        rsync \
            -a \
            --info=progress2 \
            "$TARGET/" \
            "$IMAGE_BUNDLES/"

        DEST_COUNT="$(
            find "$IMAGE_BUNDLES" \
                -maxdepth 1 \
                -type f \
                -printf '.' |
            wc -c
        )"

        if [[ "$SOURCE_COUNT" != "$DEST_COUNT" ]]; then
            die "Migration verification failed: source=$SOURCE_COUNT destination=$DEST_COUNT"
        fi

        log "Migration verified: $DEST_COUNT files."
    else
        log "Existing Fast Cache contains $FAST_COUNT files; migration skipped."
    fi

    sync

    if (( TEMP_MOUNTED == 1 )); then
        log "Unmounting temporary image mount..."
        sudo umount "$MNT"
    fi
fi

log "Installing system helper..."

sudo install -d -m 0755 "$CONFIG_DIR"
sudo install -d -m 0755 /usr/local/libexec

sudo install \
    -m 0755 \
    "$HELPER_SRC" \
    "$SYSTEM_HELPER"

sudo install \
    -m 0644 \
    "$SERVICE_SRC" \
    "$SYSTEM_SERVICE"

log "Writing configuration..."

{
    printf 'FAST_IMG=%q\n' "$FAST_IMG"
    printf 'TARGET=%q\n' "$TARGET"
    printf 'MNT=%q\n' "$MNT"
} | sudo tee "$CONFIG" >/dev/null

log "Enabling Fast Asset Cache service..."

sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME" >/dev/null
sudo systemctl restart "$SERVICE_NAME"

echo

FINAL_FS="$(findmnt -n -o FSTYPE -T "$TARGET" 2>/dev/null || true)"
FINAL_SOURCE="$(findmnt -n -o SOURCE -T "$TARGET" 2>/dev/null || true)"

if [[ "$FINAL_FS" != "ext4" || "$FINAL_SOURCE" != *"[/Cache]"* ]]; then
    die "Fast Asset Cache service started but target validation failed."
fi

FINAL_COUNT="$(
    find "$TARGET" \
        -maxdepth 1 \
        -type f \
        -printf '.' |
    wc -c
)"

echo "============================================"
echo " LWCompat Fast Asset Cache"
echo "============================================"
echo "Status : ACTIVE"
echo "FS     : $FINAL_FS"
echo "Source : $FINAL_SOURCE"
echo "Files  : $FINAL_COUNT"
echo "Image  : $FAST_IMG"
echo
echo "Fast Asset Cache setup completed successfully."
