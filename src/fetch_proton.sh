#!/usr/bin/env bash
# Download an official GE-Proton release from GitHub, verify it against the
# release's published SHA-512 and unpack it next to existing Proton builds.
# LWCompat never redistributes Proton itself.
#
#   fetch_proton.sh [TAG]        TAG defaults to the latest release
#   LWCOMPAT_PROTON_DIR=...      install root (default: Steam compatibilitytools.d)
#
# Prints the installed Proton directory on the last line of stdout.
set -euo pipefail

REPO="GloriousEggroll/proton-ge-custom"
TAG="${1:-latest}"
DEST_ROOT="${LWCOMPAT_PROTON_DIR:-$HOME/.local/share/Steam/compatibilitytools.d}"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/lwcompat/proton"

log() {
    printf '[LWCompat Proton] %s\n' "$*" >&2
}

die() {
    printf '[LWCompat Proton] ERROR: %s\n' "$*" >&2
    exit 1
}

for cmd in curl python3 sha512sum tar; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
done

if [[ "$TAG" == "latest" ]]; then
    api="https://api.github.com/repos/$REPO/releases/latest"
else
    [[ "$TAG" =~ ^GE-Proton[0-9]+-[0-9]+$ ]] || die "Invalid tag: $TAG"
    api="https://api.github.com/repos/$REPO/releases/tags/$TAG"
fi

# Resolve tag and asset URLs (x86_64 tarball + its sha512sum) from the API.
mapfile -t release < <(
    curl -fsSL --max-time 30 "$api" | python3 -I -c '
import json, sys
r = json.load(sys.stdin)
tag = r["tag_name"]
assets = {a["name"]: a["browser_download_url"] for a in r["assets"]}
tar = f"{tag}-x86_64.tar.gz"
if tar not in assets:
    tar = f"{tag}.tar.gz"
print(tag)
print(assets[tar])
print(assets[tar.replace(".tar.gz", ".sha512sum")])
'
) || die "Could not read release information from GitHub."

TAG="${release[0]}"
TAR_URL="${release[1]}"
SUM_URL="${release[2]}"
TAR_NAME="${TAR_URL##*/}"

[[ "$TAR_URL" == https://github.com/$REPO/releases/download/* &&
   "$SUM_URL" == https://github.com/$REPO/releases/download/* ]] ||
    die "Unexpected download location: $TAR_URL"

# Release tarballs unpack to a directory named like the archive
# (e.g. GE-Proton11-11-x86_64); that name is also the install directory.
DIR="${TAR_NAME%.tar.gz}"
[[ "$DIR" =~ ^GE-Proton[0-9]+-[0-9]+(-x86_64)?$ ]] || die "Unexpected archive name: $TAR_NAME"

if [[ -x "$DEST_ROOT/$DIR/proton" ]]; then
    log "$DIR is already installed."
    printf '%s\n' "$DEST_ROOT/$DIR"
    exit 0
fi

mkdir -p "$CACHE" "$DEST_ROOT"

curl -fsSL --retry 3 -o "$CACHE/$TAR_NAME.sha512sum" "$SUM_URL"
expected="$(awk '{print $1; exit}' "$CACHE/$TAR_NAME.sha512sum")"

checksum() {
    sha512sum "$CACHE/$TAR_NAME" 2>/dev/null | awk '{print $1}'
}

# Reuse a complete cached download; otherwise resume or start it.
if [[ -n "$expected" && "$(checksum)" == "$expected" ]]; then
    log "Using cached $TAR_NAME."
else
    log "Downloading $TAR_NAME ..."
    curl -fL --retry 3 -C - --progress-bar -o "$CACHE/$TAR_NAME" "$TAR_URL" ||
        curl -fL --retry 3 --progress-bar -o "$CACHE/$TAR_NAME" "$TAR_URL"
fi

actual="$(checksum)"

if [[ -z "$expected" || "$expected" != "$actual" ]]; then
    rm -f "$CACHE/$TAR_NAME"
    die "SHA-512 mismatch for $TAR_NAME; download removed."
fi
log "SHA-512 verified."

# Every entry must live under "<DIR>/" (no absolute paths or ".."). The
# listing is captured first: piping into grep -q under pipefail would let a
# SIGPIPE from tar flip the result.
listing="$(tar -tzf "$CACHE/$TAR_NAME")" || die "Cannot list $TAR_NAME."
bad="$(grep -vE "^$DIR(/|$)" <<<"$listing" || true)"
dots="$(grep -E '(^|/)\.\.(/|$)' <<<"$listing" || true)"
if [[ -n "$bad" || -n "$dots" ]]; then
    die "Archive contains unexpected paths; not extracting."
fi

staging="$(mktemp -d "$DEST_ROOT/.lwcompat-$TAG.XXXXXX")"
trap 'rm -rf "$staging"' EXIT

log "Extracting into $DEST_ROOT ..."
tar -xzf "$CACHE/$TAR_NAME" -C "$staging" --no-same-owner

[[ -x "$staging/$DIR/proton" ]] || die "Extracted archive has no proton script."
mv "$staging/$DIR" "$DEST_ROOT/$DIR"

rm -f "$CACHE/$TAR_NAME"
log "Installed $DIR."
printf '%s\n' "$DEST_ROOT/$DIR"
