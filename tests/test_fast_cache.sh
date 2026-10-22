#!/usr/bin/env bash
# Fast Asset Cache helper and ctl in a private mount namespace (unshare -rm):
# no root, no real mounts. A tmpfs stands in for the ext4 image; loop mounts
# and casefold attributes are shimmed. Skipped where unprivileged user
# namespaces are unavailable.
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

if [[ "${1:-}" != "--inner" ]]; then
    if ! unshare -rm true 2>/dev/null; then
        echo "  skip  unprivileged user namespaces unavailable"
        exit 0
    fi
    T="$(mktemp -d)"
    unshare -rm bash "${BASH_SOURCE[0]}" --inner "$T"
    rc=$?
    rm -rf "$T"
    exit "$rc"
fi

T="$2"
mount --make-rprivate /
mkdir -p "$T/img" "$T/mnt" "$T/shim" "$T/bin"
mount -t tmpfs tmpfs "$T/img"          # stands in for the ext4 image root

# Copies of the helper and ctl reading a test config instead of /etc.
for f in fast_asset_cache.sh fast_asset_cache_ctl.sh; do
    sed "s#^CONFIG=\"/etc/lwcompat/fast-asset-cache.conf\"#CONFIG=\"$T/fast-asset-cache.conf\"#" \
        "$ROOT/src/$f" > "$T/bin/$f"
done
HELPER="$T/bin/fast_asset_cache.sh"
CTL="$T/bin/fast_asset_cache_ctl.sh"
grep -q "CONFIG=\"$T/" "$HELPER" || { fail "could not redirect helper config"; finish; }

# Legacy image layout + game Cache directory (the "Btrfs" side).
mkdir -p "$T/img/AssetBundles" "$T/game/Cache/AssetBundles" \
         "$T/game/Cache/AssetBundles.Temp" "$T/game/Cache/warmup"
for i in 1 2 3; do
    echo "fast$i" > "$T/img/AssetBundles/b$i.bundle"
    echo "slow$i" > "$T/game/Cache/AssetBundles/b$i.bundle"
done
touch -d 2026-01-01 "$T/game/Cache/AssetBundles/"*.bundle
: > "$T/fake.img"
printf 'FAST_IMG=%q\nTARGET=%q\nMNT=%q\n' "$T/fake.img" "$T/game/Cache/AssetBundles" "$T/mnt" \
    > "$T/fast-asset-cache.conf"

cat > "$T/shim/mount" <<SHIM
#!/bin/bash
if [[ "\$*" == *loop* ]]; then exec /usr/bin/mount --bind "$T/img" "\${@: -1}"; fi
exec /usr/bin/mount "\$@"
SHIM
printf '#!/bin/bash\nexit 0\n' > "$T/shim/chattr"
printf '#!/bin/bash\necho "--------F------- ${@: -1}"\n' > "$T/shim/lsattr"
printf '#!/bin/bash\n/usr/bin/findmnt "$@" | sed "s/^tmpfs$/ext4/"\n' > "$T/shim/findmnt"
chmod +x "$T/shim/"*
export PATH="$T/shim:$PATH"

src() { findmnt -n -o SOURCE -T "$T/game/Cache/AssetBundles"; }
launcher_rename() {  # Temp -> AssetBundles, like the launcher
    echo x > "$T/game/Cache/AssetBundles.Temp/new.bundle"
    python3 -I -c 'import os,sys; os.rename(sys.argv[1], sys.argv[2])' \
        "$T/game/Cache/AssetBundles.Temp/new.bundle" "$T/game/Cache/AssetBundles/new.bundle" 2>&1 | tail -1
}
layout() { bash "$CTL" status 2>/dev/null | awk '/^Layout/ {print $3}'; }

# Old helper behaviour: AssetBundles-only bind.
mount -o loop "$T/fake.img" "$T/mnt"
mount --bind "$T/mnt/AssetBundles" "$T/game/Cache/AssetBundles"
out="$(launcher_rename)"
[[ "$out" == *"cross-device"* ]] && pass "legacy layout: launcher rename fails (EXDEV)" || fail "legacy rename: $out"
assert_eq legacy "$(layout)" "ctl reports legacy layout"

# Upgrade over the active legacy mount.
bash "$HELPER" start >/dev/null || fail "start returned non-zero"
[[ "$(src)" == *"[/Cache]"* ]] && pass "start binds the whole Cache directory" || fail "source is $(src)"
[[ -d "$T/img/Cache/AssetBundles" && ! -e "$T/img/AssetBundles" ]] && pass "image migrated in place" || fail "image migration"
[[ -d "$T/img/Cache/AssetBundles.Temp" && -d "$T/img/Cache/warmup" ]] && pass "Temp and warmup created in image" || fail "Temp/warmup"
assert_eq fast1 "$(cat "$T/game/Cache/AssetBundles/b1.bundle")" "game sees the cached bundles"
mountpoint -q "$T/game/Cache/AssetBundles" && fail "legacy bind still present" || pass "legacy bind removed"
assert_eq cache "$(layout)" "ctl reports cache layout"

out="$(launcher_rename)"
[[ -z "$out" && -f "$T/img/Cache/AssetBundles/new.bundle" ]] && pass "launcher rename works and lands in the image" || fail "rename: $out"

bash "$HELPER" start | grep -q 'already active' && pass "start is idempotent" || fail "second start"

bash "$HELPER" stop >/dev/null
assert_eq slow1 "$(cat "$T/game/Cache/AssetBundles/b1.bundle")" "stop shows the original directory"
mountpoint -q "$T/mnt" && fail "image still mounted after stop" || pass "image unmounted after stop"

bash "$HELPER" refresh >/dev/null || fail "refresh returned non-zero"
assert_eq slow1 "$(cat "$T/img/Cache/AssetBundles/b1.bundle")" "refresh syncs original -> image"

bash "$HELPER" start >/dev/null
bash "$HELPER" refresh >/dev/null 2>&1 && fail "refresh allowed while active" || pass "refresh refused while active"

bash "$HELPER" restart >/dev/null && [[ "$(src)" == *"[/Cache]"* ]] && pass "restart" || fail "restart"
bash "$HELPER" stop >/dev/null

finish
