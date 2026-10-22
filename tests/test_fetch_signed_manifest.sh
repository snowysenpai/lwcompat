#!/usr/bin/env bash
# fetch_signed_manifest.py against a local HTTP server with a synthetic
# manifest (no real game data is stored in the repository).
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

HELPER="$ROOT/src/fetch_signed_manifest.py"
T="$(mktemp -d)"
SERVER_PID=""
trap '[[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$T"' EXIT

mkdir -p "$T/srv/manifest/all/manifests" "$T/game" "$T/backups"

serve_manifest() {  # version channel sig_bytes
    python3 -I -c 'import json,sys
v, ch = int(sys.argv[1]), sys.argv[2]
print(json.dumps({"version": v, "channel": ch, "files": {"Game/LastWar.exe": {"hash": "00"}}}), end="")' \
        "$1" "$2" > "$T/srv/manifest/all/manifests/1101.json"
    head -c "$3" /dev/zero > "$T/srv/manifest/all/manifests/1101.json.sig"
}

reset_game() {
    printf '{"version": 1093, "channel": "all", "files": {}}' > "$T/game/manifest.json"
    head -c 64 /dev/urandom > "$T/game/manifest.json.sig"
}

write_log() {  # announced_size
    printf '[x][Launcher][INFO] Remote manifest version: all,1101,0123456789abcdef0123456789abcdef,%s\n' "$1" \
        > "$T/Launcher.log"
}

run_helper() {
    python3 -I "$HELPER" --game-dir "$T/game" --launcher-log "$T/Launcher.log" \
        --backup-dir "$T/backups" --base "http://127.0.0.1:$PORT" >/dev/null 2>&1
    echo $?
}

PORT="$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
python3 -I -m http.server --bind 127.0.0.1 --directory "$T/srv" "$PORT" >/dev/null 2>&1 &
SERVER_PID=$!
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.1; done

size() { stat -c %s "$T/srv/manifest/all/manifests/1101.json"; }
local_version() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$T/game/manifest.json"; }

# 1. newer signed manifest is installed and the old one backed up
serve_manifest 1101 all 64; reset_game; write_log "$(size)"
assert_eq 0 "$(run_helper)" "installs newer manifest"
assert_eq 1101 "$(local_version)" "local manifest is now 1101"
cmp -s "$T/game/manifest.json.sig" "$T/srv/manifest/all/manifests/1101.json.sig" &&
    pass "signature installed" || fail "signature installed"
[[ -f "$(ls -d "$T"/backups/manifest-1093-*/manifest.json 2>/dev/null | head -1)" ]] &&
    pass "previous manifest backed up" || fail "previous manifest backed up"

# 2. nothing to do once current
assert_eq 3 "$(run_helper)" "already current -> exit 3"

# 3-5. every validation failure leaves the game untouched
serve_manifest 1101 all 64; reset_game; write_log "$(( $(size) + 1 ))"
assert_eq 1 "$(run_helper)" "size differs from announced size -> error"
assert_eq 1093 "$(local_version)" "  ... local manifest untouched"

serve_manifest 1101 all 63; reset_game; write_log "$(size)"
assert_eq 1 "$(run_helper)" "63-byte signature -> error"
assert_eq 1093 "$(local_version)" "  ... local manifest untouched"

serve_manifest 1100 all 64; reset_game; write_log "$(size)"
assert_eq 1 "$(run_helper)" "manifest version differs from announced -> error"

serve_manifest 1101 beta 64; reset_game; write_log "$(size)"
assert_eq 1 "$(run_helper)" "manifest channel differs -> error"
assert_eq 1093 "$(local_version)" "  ... local manifest untouched"

# 6-8. Ed25519 signature check with a key located inside the launcher.
# A synthetic key and fake launcher are generated here; no real key is stored.
if command -v openssl >/dev/null 2>&1; then
    openssl genpkey -algorithm ed25519 -out "$T/good.pem" 2>/dev/null
    openssl genpkey -algorithm ed25519 -out "$T/evil.pem" 2>/dev/null
    { head -c 4096 /dev/urandom
      openssl pkey -in "$T/good.pem" -pubout -outform DER 2>/dev/null | tail -c 32
      printf '+configured manifest public key is invalid: '
      head -c 4096 /dev/urandom; } > "$T/LastWarLauncher.exe"
    head -c 8192 /dev/urandom > "$T/NoKeyLauncher.exe"

    sign() { openssl pkeyutl -sign -inkey "$1" -rawin -in "$2" -out "$3" 2>/dev/null; }

    run_signed() {  # launcher
        XDG_CACHE_HOME="$T/cache" python3 -I "$HELPER" --game-dir "$T/game" \
            --launcher-log "$T/Launcher.log" --backup-dir "$T/backups" \
            --base "http://127.0.0.1:$PORT" --launcher "$1" > "$T/helper.out" 2>&1
        echo $?
    }

    signed_setup() {  # key used for the served manifest
        serve_manifest 1101 all 64
        sign "$1" "$T/srv/manifest/all/manifests/1101.json" "$T/srv/manifest/all/manifests/1101.json.sig"
        reset_game
        sign "$T/good.pem" "$T/game/manifest.json" "$T/game/manifest.json.sig"   # accepted pair
        write_log "$(size)"
        rm -rf "$T/cache"
    }

    signed_setup "$T/good.pem"
    assert_eq 0 "$(run_signed "$T/LastWarLauncher.exe")" "valid signature with the launcher's key installs"
    grep -q 'signature verified' "$T/helper.out" && pass "  ... signature was checked" || fail "signature checked"
    ls "$T/cache/lwcompat"/manifest-key-*.hex >/dev/null 2>&1 && pass "  ... key cached per launcher" || fail "key cache"

    signed_setup "$T/evil.pem"
    assert_eq 1 "$(run_signed "$T/LastWarLauncher.exe")" "manifest signed by another key is rejected"
    assert_eq 1093 "$(local_version)" "  ... local manifest untouched"

    signed_setup "$T/good.pem"
    assert_eq 0 "$(run_signed "$T/NoKeyLauncher.exe")" "launcher without a findable key falls back to installing"
    grep -q 'WARNING: launcher manifest key not found' "$T/helper.out" && pass "  ... with a warning" || fail "fallback warning"
else
    echo "  skip  openssl not installed (signature tests)"
fi

finish
