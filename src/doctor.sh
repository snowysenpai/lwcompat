#!/usr/bin/env bash
# Read-only LWCompat diagnostics. Prints a report that is safe to share:
# the home directory is shown as "~" and nothing is modified.
#
#   lwcompat-doctor              full report
#   lwcompat-doctor --offline    skip the CDN check
set -u

APP_DIR="${LWCOMPAT_APP_DIR:-$HOME/.local/share/lwcompat}"
CONFIG="$APP_DIR/config.sh"
SETTINGS_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/lwcompat/settings.conf"
SESSION_LOG="$APP_DIR/logs/lwcompat.log"
CDN_BASE="https://lastwar-cdn.akamaized.net/hotupdate/pc/micro"

# shellcheck source=launcher_log.sh
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/launcher_log.sh"

OFFLINE=0
[[ "${1:-}" == "--offline" ]] && OFFLINE=1

redact() {
    sed -e "s#$HOME#~#g"
}

section() {
    printf '\n== %s ==\n' "$1"
}

row() {
    printf '%-22s %s\n' "$1" "$2"
}

json_field() {
    python3 -I -c 'import json,sys
try: print(json.load(open(sys.argv[1]))[sys.argv[2]])
except Exception: print("?")' "$1" "$2" 2>/dev/null
}

report() {
    section "LWCompat"
    row "Version" "$(cat "$APP_DIR/VERSION" 2>/dev/null || echo unknown)"
    row "Date" "$(date --iso-8601=seconds)"
    row "System" "$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-?}") / $(uname -r)"

    if [[ ! -r "$CONFIG" ]]; then
        row "Config" "MISSING ($CONFIG)"
        return
    fi

    # shellcheck disable=SC1090
    source "$CONFIG"

    local game="$LWCOMPAT_GAME_DIR"
    local launcher_log="$game/Launcher.log"

    section "Paths"
    for item in "Prefix:$LWCOMPAT_PREFIX" "Game:$game" "UMU:$LWCOMPAT_UMU" "Proton:$LWCOMPAT_PROTON"; do
        local name="${item%%:*}" path="${item#*:}"
        [[ -e "$path" ]] && row "$name" "OK  $path" || row "$name" "MISSING  $path"
    done
    row "Proton version" "$(cut -d' ' -f2 "$LWCOMPAT_PROTON/version" 2>/dev/null || echo ?)"
    row "Launcher sha256" "$(sha256sum "$game/LastWarLauncher.exe" 2>/dev/null | cut -c1-16)"

    section "Game"
    if pgrep -x 'LastWar\.exe|LastWarLauncher' >/dev/null 2>&1; then
        row "Running" "yes"
    else
        row "Running" "no"
    fi

    local local_ver remote_line remote_ver
    local_ver="$(json_field "$game/manifest.json" version)"
    remote_line="$(grep -o 'Remote manifest version: [^ ]*' "$launcher_log" 2>/dev/null | tail -1)"
    remote_ver="$(cut -d, -f2 <<<"${remote_line#*: }")"

    row "Local manifest" "$local_ver"
    row "Remote manifest" "${remote_ver:-unknown} (from last Launcher.log)"
    [[ -s "$game/manifest.json.sig" ]] && row "Manifest signature" "present" || row "Manifest signature" "MISSING"

    section "Last launcher run"
    local verdict="no Launcher.log"
    if [[ -f "$launcher_log" ]]; then
        case "$(launcher_log_state "$launcher_log")" in
            started) verdict="OK: game started" ;;
            update) verdict="real update pending" ;;
            manifest-stall) verdict="manifest download stalled in Wine (LWCompat fetches it natively)" ;;
            transient) verdict="transient network timeout (retried automatically)" ;;
            *)
                if grep -Fq 'ERROR' "$launcher_log"; then
                    verdict="other launcher error (see below)"
                else
                    verdict="no decision recorded"
                fi
                ;;
        esac
        row "Updated" "$(date -r "$launcher_log" '+%F %T')"
    fi
    row "Verdict" "$verdict"
    grep -F 'ERROR' "$launcher_log" 2>/dev/null | tail -3 | cut -c1-200 | sed 's/^/  /'

    section "Fast Asset Cache"
    if command -v lwcompat-fast-cache >/dev/null 2>&1; then
        lwcompat-fast-cache status 2>&1 | grep -E 'Enabled|Service|Layout|Status' | sed 's/^/  /'
    else
        row "Status" "not installed"
    fi

    section "Overlays"
    local fps=0 dxvk=0 custom=0
    if [[ -r "$SETTINGS_FILE" ]]; then
        fps="$(grep -oP '^LWCOMPAT_FPS=\K.*' "$SETTINGS_FILE" || echo 0)"
        dxvk="$(grep -oP '^LWCOMPAT_HUD=\K.*' "$SETTINGS_FILE" || echo 0)"
        custom="$(grep -oP '^LWCOMPAT_CUSTOM_HUD=\K.*' "$SETTINGS_FILE" || echo 0)"
    fi
    row "FPS / DXVK HUD" "${fps:-0} / ${dxvk:-0}"
    row "Custom Vulkan HUD" "setting=${custom:-0}, layer=$(grep -q '"library_path"' "$APP_DIR/hud/VK_LAYER_LWCOMPAT_hud_spike.json" 2>/dev/null && echo valid || echo missing/invalid)"

    if (( OFFLINE == 0 )); then
        section "Network"
        local channel url
        channel="$(json_field "$game/manifest.json" channel)"
        url="$CDN_BASE/manifest/${channel:-all}/manifests/${local_ver}.json.sig"
        row "CDN (manifest .sig)" "$(curl -s -o /dev/null --max-time 10 \
            -w 'HTTP %{http_code}, %{size_download} B, %{time_total}s, %{remote_ip}' "$url" 2>&1)"
    fi

    section "Last LWCompat session"
    if [[ -r "$SESSION_LOG" ]]; then
        # Only the newest session (older installs used one growing log).
        local session
        session="$(awk '/LWCompat launch:/ { buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }' "$SESSION_LOG")"
        grep -m1 'LWCompat launch:' <<<"$session" | sed 's/^/  /'
        grep -E '\[LWCompat( update| manifest)?\]|exit code' <<<"$session" | tail -12 | sed 's/^/  /'
    else
        row "Session log" "none"
    fi
}

report 2>&1 | redact
