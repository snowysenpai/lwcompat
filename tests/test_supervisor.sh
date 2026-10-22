#!/usr/bin/env bash
# lwcompat.sh launch loop end to end with stub UMU/launcher, updater and
# manifest fetcher. Runs in its own PID namespace so stop_prefix's pkill can
# never reach a real game. Skipped where user namespaces are unavailable.
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

if [[ "${1:-}" != "--inner" ]]; then
    if ! unshare -rpf --mount-proc true 2>/dev/null; then
        echo "  skip  unprivileged user/PID namespaces unavailable"
        exit 0
    fi
    exec unshare -rpf --mount-proc bash "${BASH_SOURCE[0]}" --inner
fi

T="$(mktemp -d)"
trap 'pkill -f "$T/" 2>/dev/null; rm -rf "$T"' EXIT

# A process whose name (comm) is LastWar.exe, like the real game under Wine.
cp "$(command -v sleep)" "$T/LastWar.exe"

setup() {  # scenario
    rm -rf "$T/app" "$T/game" "$T/prefix" "$T/proton" "$T/cfg" "$T/stub"
    mkdir -p "$T/app/logs" "$T/game" "$T/prefix" "$T/proton/files/bin" "$T/cfg/lwcompat" "$T/stub"
    : > "$T/game/LastWarLauncher.exe"
    printf '#!/bin/bash\nexit 0\n' > "$T/proton/files/bin/wineserver"
    printf '#!/bin/bash\nexit 0\n' > "$T/stub/notify-send"

    printf 'LWCOMPAT_GAME_DIR=%q\nLWCOMPAT_PREFIX=%q\nLWCOMPAT_UMU=%q\nLWCOMPAT_PROTON=%q\n' \
        "$T/game" "$T/prefix" "$T/app/umu-run" "$T/proton" > "$T/app/config.sh"
    cp "$ROOT/src/lwcompat.sh" "$ROOT/src/launcher_log.sh" "$T/app/"
    echo "0.0.0-test" > "$T/app/VERSION"

    # Fake UMU: n-th launch writes the n-th scripted Launcher.log outcome.
    cat > "$T/app/umu-run" <<EOF
import os, subprocess, sys, time
n = len(open("$T/umu.calls").read()) if os.path.exists("$T/umu.calls") else 0
open("$T/umu.calls", "a").write("x")
outcomes = open("$T/outcomes").read().split()
outcome = outcomes[min(n, len(outcomes) - 1)]
log = open("$T/game/Launcher.log", "a")
lines = {
    "start": 'Starting game at: "C:\\\\Game\\\\LastWar.exe"',
    "update": "Strict Game check: 214/215 files match, 1 replacements, 0 extra/conflicting entries",
    "stall": "Failed to load remote manifest: NetworkError(TimedOut)",
}
time.sleep(0.3)
if outcome == "start":
    subprocess.Popen(["$T/LastWar.exe", "1.5"])
log.write("[t][Launcher][INFO] " + lines[outcome] + "\n")
log.flush()
time.sleep(0.5)
EOF

    # Fake updater: exit code from file; 10 also starts the game (handoff).
    cat > "$T/app/update.sh" <<EOF
#!/bin/bash
echo "\$LWCOMPAT_UPDATE_HANDOFF" > "$T/update.handoff"
rc=\$(cat "$T/update.rc")
if [[ "\$rc" == 10 ]]; then "$T/LastWar.exe" 1.5 & fi
exit "\$rc"
EOF
    chmod +x "$T/app/update.sh" "$T/stub/notify-send" "$T/proton/files/bin/wineserver"

    cat > "$T/app/fetch_signed_manifest.py" <<EOF
open("$T/fetch.calls", "a").write("x")
EOF

    rm -f "$T/umu.calls" "$T/fetch.calls" "$T/update.handoff"
    echo "$1" > "$T/outcomes"
}

run() {
    PATH="$T/stub:$PATH" XDG_CONFIG_HOME="$T/cfg" XDG_CACHE_HOME="$T/cache" \
        LWCOMPAT_APP_DIR="$T/app" timeout 60 bash "$T/app/lwcompat.sh" > "$T/out.log" 2>&1
    echo $?
}
count() { [[ -f "$1" ]] && wc -c < "$1" || echo 0; }

# 1. Normal launch.
setup "start"
assert_eq 0 "$(run)" "normal launch exits 0 after the game ends"
assert_eq 1 "$(count "$T/umu.calls")" "  ... launcher started once"
grep -q 'Last War session ended' "$T/out.log" && pass "  ... waited for the game session" || fail "session end"

# 2. Real update, updater hands the running game over (rc 10).
setup "update"; echo 10 > "$T/update.rc"
assert_eq 0 "$(run)" "update with handoff exits 0"
assert_eq 1 "$(count "$T/umu.calls")" "  ... no second launcher start"
assert_eq 1 "$(cat "$T/update.handoff" 2>/dev/null)" "  ... updater was asked to hand over"
grep -q 'game already started' "$T/out.log" && pass "  ... logged the handoff" || fail "handoff log"
grep -q 'Last War session ended' "$T/out.log" && pass "  ... waited for the handed-over game" || fail "handoff session wait"

# 3. Real update, updater finishes without starting the game (rc 0).
setup "update start"; echo 0 > "$T/update.rc"
assert_eq 0 "$(run)" "update without handoff exits 0"
assert_eq 2 "$(count "$T/umu.calls")" "  ... launcher started again after the update"

# 4. Updater failure is fatal.
setup "update"; echo 1 > "$T/update.rc"
assert_eq 1 "$(run)" "updater failure exits 1"
grep -q 'Automatic updater failed' "$T/out.log" && pass "  ... reported" || fail "updater failure message"

# 5. Manifest stall: fetch natively once, then launch.
setup "stall start"
assert_eq 0 "$(run)" "manifest stall recovers"
assert_eq 1 "$(count "$T/fetch.calls")" "  ... native manifest fetch ran once"
assert_eq 2 "$(count "$T/umu.calls")" "  ... launcher retried"

finish
