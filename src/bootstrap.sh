#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

CONNECT_PROXY="$SCRIPT_DIR/connect_proxy.py"
BUNDLE_PROXY="$SCRIPT_DIR/bundle_proxy.py"
BOOTSTRAP_CLIENT="$SCRIPT_DIR/bootstrap_client.py"

DOWNLOADER_URL="${LWCOMPAT_DOWNLOADER_URL:-https://www.lastwar.com/Download/Micro/LastWarDownloader.exe}"
CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/lwcompat/bootstrap"
DOWNLOADER="$CACHE_ROOT/LastWarDownloader.exe"

PREFIX="${LWCOMPAT_PREFIX:-$HOME/Games/LastWar}"
GAME_DIR="$PREFIX/drive_c/users/steamuser/AppData/Local/FunFly/Last War-Survival Game"
MANIFEST_TEMP="$GAME_DIR/Temp/manifest.temp"
MANIFEST="$GAME_DIR/manifest.json"
LAUNCHER="$GAME_DIR/LastWarLauncher.exe"
LAUNCHER_LOG="$GAME_DIR/Launcher.log"

UMU="${LWCOMPAT_UMU:-}"
PROTON="${LWCOMPAT_PROTON:-}"

LOG_DIR="$CACHE_ROOT/logs"
CONNECT_LOG="$LOG_DIR/connect-proxy.log"
BUNDLE_LOG="$LOG_DIR/bundle-proxy.log"
UMU_LOG="$LOG_DIR/umu-bootstrap.log"

CONNECT_PID=""
BUNDLE_PID=""
UMU_PID=""

log() {
    printf '[LWCompat bootstrap] %s\n' "$*"
}

die() {
    printf '[LWCompat bootstrap] ERROR: %s\n' "$*" >&2
    exit 1
}

[[ -n "$UMU" && -f "$UMU" ]] || die "LWCOMPAT_UMU is missing or invalid."
[[ -n "$PROTON" && -d "$PROTON" ]] || die "LWCOMPAT_PROTON is missing or invalid."
[[ -f "$CONNECT_PROXY" ]] || die "Missing: $CONNECT_PROXY"
[[ -f "$BUNDLE_PROXY" ]] || die "Missing: $BUNDLE_PROXY"
[[ -f "$BOOTSTRAP_CLIENT" ]] || die "Missing: $BOOTSTRAP_CLIENT"

mkdir -p "$CACHE_ROOT" "$LOG_DIR" "$PREFIX"

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

    pkill -f '[L]astWarDownloader\.exe' 2>/dev/null || true
    pkill -f '[L]astWarLauncher\.exe' 2>/dev/null || true
    pkill -f '[L]astWar\.exe' 2>/dev/null || true

    stop_pid "$UMU_PID"
    UMU_PID=""

    sleep 1
}

cleanup() {
    stop_pid "$CONNECT_PID"
    stop_pid "$BUNDLE_PID"

    CONNECT_PID=""
    BUNDLE_PID=""
}

trap cleanup EXIT INT TERM

wait_port() {
    local port="$1"

    python3 - "$port" <<'PY'
import socket
import sys
import time

port = int(sys.argv[1])

for _ in range(100):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.2):
            raise SystemExit(0)
    except OSError:
        time.sleep(0.1)

raise SystemExit(1)
PY
}

download_downloader() {
    log "Preparing official Last War downloader..."

    env \
        -u HTTPS_PROXY \
        -u https_proxy \
        -u HTTP_PROXY \
        -u http_proxy \
        -u ALL_PROXY \
        -u all_proxy \
        python3 - "$DOWNLOADER_URL" "$DOWNLOADER" <<'PY'
import hashlib
import os
import struct
import sys
from pathlib import Path
from urllib.request import Request, urlopen

url = sys.argv[1]
dst = Path(sys.argv[2])
tmp = dst.with_name(dst.name + ".download")


def valid_pe(path):
    try:
        with path.open("rb") as f:
            if f.read(2) != b"MZ":
                return False

            f.seek(0x3C)
            raw = f.read(4)
            if len(raw) != 4:
                return False

            pe = struct.unpack("<I", raw)[0]
            f.seek(pe)

            return f.read(4) == b"PE\0\0"
    except OSError:
        return False


if dst.is_file() and valid_pe(dst):
    print(f"[LWCompat bootstrap] Using cached downloader: {dst}")
    raise SystemExit(0)


req = Request(
    url,
    headers={
        "User-Agent": "Mozilla/5.0 LWCompat",
        "Accept": "*/*",
    },
)

sha = hashlib.sha256()

try:
    with urlopen(req, timeout=60) as response, tmp.open("wb") as output:
        while True:
            chunk = response.read(1024 * 1024)

            if not chunk:
                break

            output.write(chunk)
            sha.update(chunk)

        output.flush()
        os.fsync(output.fileno())

    if not valid_pe(tmp):
        raise RuntimeError("downloaded file is not a valid PE executable")

    os.replace(tmp, dst)

except Exception:
    try:
        tmp.unlink()
    except FileNotFoundError:
        pass
    raise

print(f"[LWCompat bootstrap] Downloader SHA256: {sha.hexdigest()}")
PY
}

start_connect_proxy() {
    stop_pid "$CONNECT_PID"

    : > "$CONNECT_LOG"

    python3 "$CONNECT_PROXY" >>"$CONNECT_LOG" 2>&1 &
    CONNECT_PID=$!

    wait_port 18083 || {
        tail -n 50 "$CONNECT_LOG" >&2 || true
        die "CONNECT proxy failed to start."
    }

    log "HTTPS bootstrap bridge: 127.0.0.1:18083"
}

start_bundle_proxy() {
    stop_pid "$BUNDLE_PID"

    : > "$BUNDLE_LOG"

    python3 "$BUNDLE_PROXY" >>"$BUNDLE_LOG" 2>&1 &
    BUNDLE_PID=$!

    wait_port 18080 || die "CDN bridge failed to start."
    wait_port 18081 || die "API bridge failed to start."

    log "Bundle bridges: 18080 / 18081"
}

launch_with_connect_proxy() {
    local exe="$1"

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
        python3 "$UMU" "$exe" >>"$UMU_LOG" 2>&1 &

    UMU_PID=$!
}

launch_clean() {
    local exe="$1"

    env \
        -u HTTPS_PROXY \
        -u https_proxy \
        -u HTTP_PROXY \
        -u http_proxy \
        -u ALL_PROXY \
        -u all_proxy \
        WINEPREFIX="$PREFIX" \
        PROTONPATH="$PROTON" \
        GAMEID="umu-default" \
        PROTONFIXES_DISABLE=1 \
        python3 "$UMU" "$exe" >>"$UMU_LOG" 2>&1 &

    UMU_PID=$!
}

manifest_ready() {
    python3 - "$MANIFEST_TEMP" <<'PY' >/dev/null 2>&1
import json
import sys
from pathlib import Path

p = Path(sys.argv[1])

if not p.is_file():
    raise SystemExit(1)

try:
    data = json.loads(p.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(1)

files = data.get("files")

if (
    not isinstance(files, list)
    or not files
    or not data.get("url")
    or not data.get("version")
):
    raise SystemExit(1)
PY
}

wait_for_manifest() {
    log "Waiting for official launcher manifest..."

    for _ in {1..1200}; do
        if manifest_ready; then
            log "Remote manifest acquired."
            return 0
        fi

        sleep 0.5
    done

    die "Timed out waiting for manifest.temp."
}

patch_manifest() {
    python3 - "$MANIFEST" <<'PY'
import json
import os
import sys
import tempfile
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))

data["bundle_url"] = "http://127.0.0.1:18080/"
data["bundle_ver_url"] = "http://127.0.0.1:18081"

fd, temp_name = tempfile.mkstemp(
    prefix="manifest.lwcompat.",
    suffix=".tmp",
    dir=str(path.parent),
)

try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(
            data,
            handle,
            ensure_ascii=False,
            separators=(",", ":"),
        )
        handle.flush()
        os.fsync(handle.fileno())

    os.replace(temp_name, path)

finally:
    try:
        os.unlink(temp_name)
    except FileNotFoundError:
        pass
PY
}

wait_for_game_start_marker() {
    local timeout="${LWCOMPAT_RESOURCE_TIMEOUT:-21600}"
    local started
    local now

    started="$(date +%s)"

    log "Waiting for launcher resource sync to complete..."

    while true; do
        if [[ -f "$LAUNCHER_LOG" ]] &&
           grep -Fq 'Starting game at:' "$LAUNCHER_LOG"
        then
            log "Launcher resource sync completed."
            return 0
        fi

        now="$(date +%s)"

        if (( now - started >= timeout )); then
            die "Timed out waiting for launcher resource completion."
        fi

        sleep 1
    done
}

download_downloader

log "Stage 1/3: acquiring official manifest."

start_connect_proxy
launch_with_connect_proxy "$DOWNLOADER"

wait_for_manifest

# The official launcher has done the only job we need from it at this stage.
stop_prefix
stop_pid "$CONNECT_PID"
CONNECT_PID=""

[[ -f "$LAUNCHER" ]] || die "LastWarLauncher.exe was not installed."

log "Stage 2/3: downloading PC client natively on Linux."

env \
    -u HTTPS_PROXY \
    -u https_proxy \
    -u HTTP_PROXY \
    -u http_proxy \
    -u ALL_PROXY \
    -u all_proxy \
    python3 "$BOOTSTRAP_CLIENT" "$GAME_DIR"

[[ -f "$MANIFEST" ]] || die "Native bootstrap did not create manifest.json."
[[ -f "$GAME_DIR/Game/LastWar.exe" ]] || die "Native bootstrap did not create Game/LastWar.exe."

patch_manifest

log "Stage 3/3: syncing launcher resources."

# Make the completion marker unambiguous for this run.
if [[ -s "$LAUNCHER_LOG" ]]; then
    cp -f "$LAUNCHER_LOG" "$LOG_DIR/Launcher-stage1.log"
fi
: > "$LAUNCHER_LOG"

start_bundle_proxy

# Stage 3 deliberately runs without the CONNECT proxy.
# Bundle traffic uses 18080/18081 through the patched manifest, while
# launcher metadata/table/Lua HTTPS traffic goes directly to the network.
launch_clean "$LAUNCHER"

wait_for_game_start_marker

# Launcher has started the game. Stop this bootstrap session so the normal
# LWCompat runtime can later launch LastWar.exe with its regular environment.
stop_prefix

stop_pid "$BUNDLE_PID"
BUNDLE_PID=""

log "Fresh Last War bootstrap complete."
log "Game directory: $GAME_DIR"
log "LastWar.exe will be launched later with a clean network environment."
