#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

APP_DIR="${LWCOMPAT_APP_DIR:-$HOME/.local/share/lwcompat}"
CONFIG="$APP_DIR/config.sh"

CONNECT_PROXY="$SCRIPT_DIR/connect_proxy.py"
BOOTSTRAP_CLIENT="$SCRIPT_DIR/bootstrap_client.py"

CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/lwcompat/update"
LOG_DIR="$CACHE_ROOT/logs"

CONNECT_LOG="$LOG_DIR/connect.log"
UMU_LOG="$LOG_DIR/umu.log"

FAST_CACHE_CMD="$HOME/.local/bin/lwcompat-fast-cache"

mkdir -p "$CACHE_ROOT" "$LOG_DIR"

[[ -f "$CONFIG" ]] || {
    echo "[LWCompat update] Missing config: $CONFIG" >&2
    exit 1
}

# shellcheck disable=SC1090
source "$CONFIG"

PREFIX="$LWCOMPAT_PREFIX"
GAME_DIR="$LWCOMPAT_GAME_DIR"
UMU="$LWCOMPAT_UMU"
PROTON="$LWCOMPAT_PROTON"

LAUNCHER="$GAME_DIR/LastWarLauncher.exe"
GAME_EXE="$GAME_DIR/Game/LastWar.exe"

MANIFEST="$GAME_DIR/manifest.json"
MANIFEST_SIG="$GAME_DIR/manifest.json.sig"
LAUNCHER_LOG="$GAME_DIR/Launcher.log"

OLD_MANIFEST="$CACHE_ROOT/manifest-before-update.json"

CONNECT_PID=""
UMU_PID=""

FAST_CACHE_WAS_ACTIVE=0


log() {
    printf '[LWCompat update] %s\n' "$*"
}


stop_pid() {
    local pid="${1:-}"

    [[ -n "$pid" ]] || return 0

    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true

        for _ in {1..30}; do
            kill -0 "$pid" 2>/dev/null || return 0
            sleep 0.1
        done

        kill -9 "$pid" 2>/dev/null || true
    fi
}


stop_prefix() {
    if [[ -x "$PROTON/files/bin/wineserver" ]]; then
        WINEPREFIX="$PREFIX" \
            "$PROTON/files/bin/wineserver" -k \
            >/dev/null 2>&1 || true
    fi

    pkill -f '[L]astWarLauncher\.exe' 2>/dev/null || true
    pkill -f '[L]astWar\.exe' 2>/dev/null || true

    stop_pid "$UMU_PID"
    UMU_PID=""

    sleep 1
}


restore_fast_cache() {
    if (( FAST_CACHE_WAS_ACTIVE == 1 )); then
        log "Restoring Fast Asset Cache..."

        "$FAST_CACHE_CMD" enable || {
            log "WARNING: Fast Asset Cache could not be restored automatically."
        }

        FAST_CACHE_WAS_ACTIVE=0
    fi
}


cleanup() {
    stop_prefix
    stop_pid "$CONNECT_PID"
    CONNECT_PID=""

    restore_fast_cache
}

trap cleanup EXIT INT TERM


wait_port() {
    python3 - <<'PY'
import socket
import time

for _ in range(100):
    try:
        with socket.create_connection(
            ("127.0.0.1", 18083),
            timeout=0.2,
        ):
            raise SystemExit(0)
    except OSError:
        time.sleep(0.1)

raise SystemExit(1)
PY
}


start_connect_proxy() {
    stop_pid "$CONNECT_PID"

    : > "$CONNECT_LOG"

    python3 "$CONNECT_PROXY" \
        >>"$CONNECT_LOG" 2>&1 &

    CONNECT_PID=$!

    if ! wait_port; then
        tail -50 "$CONNECT_LOG" >&2 || true
        return 1
    fi

    log "HTTPS update bridge ready: 127.0.0.1:18083"
}


launch_update_launcher() {
    : > "$UMU_LOG"

    env \
        -u HTTP_PROXY \
        -u http_proxy \
        -u ALL_PROXY \
        -u all_proxy \
        HTTPS_PROXY="http://127.0.0.1:18083" \
        https_proxy="http://127.0.0.1:18083" \
        NO_PROXY="127.0.0.1,localhost" \
        no_proxy="127.0.0.1,localhost" \
        WINEPREFIX="$PREFIX" \
        PROTONPATH="$PROTON" \
        GAMEID="umu-default" \
        PROTONFIXES_DISABLE=1 \
        python3 "$UMU" "$LAUNCHER" \
        >>"$UMU_LOG" 2>&1 &

    UMU_PID=$!
}


manifest_version() {
    python3 - "$MANIFEST" <<'PY'
import json
import sys
from pathlib import Path

p = Path(sys.argv[1])

try:
    print(int(json.loads(p.read_text())["version"]))
except Exception:
    print(0)
PY
}


remote_version_from_log() {
    python3 - "$LAUNCHER_LOG" <<'PY'
import re
import sys
from pathlib import Path

p = Path(sys.argv[1])

if not p.is_file():
    print(0)
    raise SystemExit

text = p.read_text(
    encoding="utf-8",
    errors="replace",
)

matches = re.findall(
    r"Remote manifest version:\s*[^,]+,(\d+),",
    text,
)

print(matches[-1] if matches else 0)
PY
}


native_update_launcher() {
    python3 - "$MANIFEST" "$OLD_MANIFEST" "$LAUNCHER" <<'PY'
import json
import os
import struct
import sys
from pathlib import Path
from urllib.request import Request, urlopen

manifest_path = Path(sys.argv[1])
old_manifest_path = Path(sys.argv[2])
launcher_path = Path(sys.argv[3])

manifest = json.loads(
    manifest_path.read_text(encoding="utf-8")
)

entry = manifest.get("launcher")

if not isinstance(entry, dict):
    raise SystemExit(
        "[LWCompat update] Manifest has no launcher entry."
    )

path = entry["path"]
expected = int(entry["size"])
file_hash = entry["hash"]

old_hash = None

if old_manifest_path.is_file():
    try:
        old = json.loads(
            old_manifest_path.read_text(
                encoding="utf-8"
            )
        )

        old_entry = old.get("launcher")

        if isinstance(old_entry, dict):
            old_hash = old_entry.get("hash")

    except Exception:
        pass

current_size = (
    launcher_path.stat().st_size
    if launcher_path.is_file()
    else -1
)

needs_update = (
    current_size != expected
    or (
        old_hash is not None
        and old_hash != file_hash
    )
)

if not needs_update:
    print(
        "[LWCompat update] Launcher already current."
    )
    raise SystemExit(0)

base = manifest["url"].rstrip("/")

url = (
    f"{base}/files/"
    f"{Path(path).name}.{file_hash}.bin"
)

tmp = launcher_path.with_name(
    launcher_path.name + ".lwcompat-update"
)

print(
    f"[LWCompat update] Native launcher update:"
)
print(f"  URL  : {url}")
print(f"  Size : {expected}")

req = Request(
    url,
    headers={
        "User-Agent": "LWCompat/0.1",
        "Accept": "*/*",
        "Accept-Encoding": "identity",
        "Connection": "close",
    },
)

with urlopen(req, timeout=60) as response, \
     tmp.open("wb") as output:

    total = 0

    while True:
        chunk = response.read(1024 * 1024)

        if not chunk:
            break

        output.write(chunk)
        total += len(chunk)

        print(
            f"\r  {total / 1024 / 1024:.1f} MiB",
            end="",
            flush=True,
        )

    output.flush()
    os.fsync(output.fileno())

print()

if tmp.stat().st_size != expected:
    tmp.unlink(missing_ok=True)

    raise SystemExit(
        "[LWCompat update] Launcher size mismatch."
    )

with tmp.open("rb") as f:
    if f.read(2) != b"MZ":
        raise SystemExit(
            "[LWCompat update] Launcher is not PE."
        )

    f.seek(0x3C)
    offset = struct.unpack("<I", f.read(4))[0]

    f.seek(offset)

    if f.read(4) != b"PE\0\0":
        raise SystemExit(
            "[LWCompat update] Invalid PE header."
        )

os.replace(tmp, launcher_path)

print(
    "[LWCompat update] Launcher update installed."
)
PY
}


force_changed_client_files() {
    python3 - "$OLD_MANIFEST" "$MANIFEST" "$GAME_DIR" <<'PY'
import json
import sys
from pathlib import Path, PureWindowsPath

old_path = Path(sys.argv[1])
new_path = Path(sys.argv[2])
game_dir = Path(sys.argv[3])

if not old_path.is_file():
    print(
        "[LWCompat update] No previous manifest; "
        "native verifier will decide what is missing."
    )
    raise SystemExit(0)

try:
    old = json.loads(old_path.read_text())
    new = json.loads(new_path.read_text())
except Exception as exc:
    raise SystemExit(
        f"[LWCompat update] Manifest comparison failed: {exc}"
    )

old_files = {
    item.get("path"): item
    for item in old.get("files", [])
    if isinstance(item, dict)
    and item.get("path")
}

changed = 0

for item in new.get("files", []):
    if not isinstance(item, dict):
        continue

    rel = item.get("path")

    if not rel:
        continue

    previous = old_files.get(rel)

    same = (
        previous is not None
        and previous.get("hash") == item.get("hash")
        and int(previous.get("size", -1))
            == int(item.get("size", -2))
    )

    if same:
        continue

    win = PureWindowsPath(rel)

    target = game_dir.joinpath(
        "Game",
        *win.parts,
    )

    if target.exists():
        target.unlink()
        changed += 1

print(
    f"[LWCompat update] Changed client files "
    f"forced for native refresh: {changed}"
)
PY
}


disable_fast_cache() {
    [[ -x "$FAST_CACHE_CMD" ]] || return 0

    if "$FAST_CACHE_CMD" status \
        | grep -q 'Status  : ACTIVE'
    then
        FAST_CACHE_WAS_ACTIVE=1

        log "Temporarily disabling Fast Asset Cache..."

        "$FAST_CACHE_CMD" disable
    else
        log "Fast Asset Cache already disabled."
    fi
}


sync_resources_with_retries() {
    local max_attempts=40
    local attempt

    disable_fast_cache

    for attempt in $(seq 1 "$max_attempts"); do
        log "Resource sync attempt $attempt/$max_attempts"

        stop_prefix

        : > "$LAUNCHER_LOG"

        launch_update_launcher

        while true; do
            if grep -Fq \
                'Starting game at:' \
                "$LAUNCHER_LOG" 2>/dev/null
            then
                log "Resource sync completed."

                stop_prefix
                return 0
            fi

            if grep -Eq \
                'Launcher error:|Failed to download file after retry|Failed to download zip manifest|Failed to load remote manifest|Download failed for|Failed to move downloaded bundle' \
                "$LAUNCHER_LOG" 2>/dev/null
            then
                log "Transient launcher failure detected."

                tail -12 "$LAUNCHER_LOG" \
                    | sed 's/^/[launcher] /'

                stop_prefix

                log "Retrying automatically in 2 seconds..."
                sleep 2
                break
            fi

            if [[ -n "$UMU_PID" ]] \
               && ! kill -0 "$UMU_PID" 2>/dev/null
            then
                log "Launcher exited before completion."

                stop_prefix
                sleep 2
                break
            fi

            sleep 0.25
        done
    done

    log "ERROR: resource sync did not complete."
    return 1
}


acquire_current_manifest() {
    local attempt

    if [[ -f "$MANIFEST" ]]; then
        cp -f "$MANIFEST" "$OLD_MANIFEST"
    else
        rm -f "$OLD_MANIFEST"
    fi

    for attempt in $(seq 1 10); do
        log "Checking official manifest ($attempt/10)..."

        stop_prefix
        : > "$LAUNCHER_LOG"

        launch_update_launcher

        for _ in $(seq 1 240); do
            local remote
            local current

            remote="$(remote_version_from_log)"
            current="$(manifest_version)"

            if (( remote > 0 )); then
                log "Remote manifest version: $remote"

                if (( current == remote )) \
                   && [[ -f "$MANIFEST_SIG" ]]
                then
                    log "Signed manifest cache is current."

                    stop_prefix
                    return 0
                fi
            fi

            if grep -Eq \
                'Launcher update required|Differences found , start update|No updates available.|Local bundle versions:' \
                "$LAUNCHER_LOG" 2>/dev/null
            then
                remote="$(remote_version_from_log)"
                current="$(manifest_version)"

                if (( remote > 0 && current == remote )) \
                   && [[ -f "$MANIFEST_SIG" ]]
                then
                    log "Fresh signed manifest acquired."

                    stop_prefix
                    return 0
                fi
            fi

            if grep -Fq \
                'Launcher error:' \
                "$LAUNCHER_LOG" 2>/dev/null
            then
                break
            fi

            sleep 0.25
        done

        stop_prefix

        log "Manifest acquisition retry..."
        sleep 2
    done

    log "ERROR: unable to acquire signed official manifest."
    return 1
}


main() {
    [[ -f "$CONNECT_PROXY" ]] || {
        log "Missing connect proxy: $CONNECT_PROXY"
        exit 1
    }

    [[ -f "$BOOTSTRAP_CLIENT" ]] || {
        log "Missing native client updater: $BOOTSTRAP_CLIENT"
        exit 1
    }

    [[ -f "$LAUNCHER" ]] || {
        log "Missing launcher: $LAUNCHER"
        exit 1
    }

    start_connect_proxy

    log "Phase 1/4: official manifest."
    acquire_current_manifest

    log "Phase 2/4: native launcher/client update."

    native_update_launcher

    force_changed_client_files

    env \
        -u HTTPS_PROXY \
        -u https_proxy \
        -u HTTP_PROXY \
        -u http_proxy \
        -u ALL_PROXY \
        -u all_proxy \
        python3 "$BOOTSTRAP_CLIENT" \
        "$GAME_DIR" \
        --manifest "$MANIFEST"

    log "Phase 3/4: launcher resources."
    sync_resources_with_retries

    log "Phase 4/4: cleanup."

    restore_fast_cache

    log "Update complete."
    log "Normal gameplay can now start with a clean network environment."
}

main "$@"
