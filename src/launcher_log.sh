#!/usr/bin/env bash
# Classification of the official launcher's Launcher.log, shared by
# lwcompat.sh (launch loop) and doctor.sh. Source this file.

# Prints one state for the given Launcher.log, or nothing while undecided:
#   started         the launcher handed off to the game
#   update          real game/launcher update or resource mismatch
#   manifest-stall  remote manifest download stalled (Wine schannel bug)
#   transient       other network timeout / launcher error worth retrying
# Order matters: a log can contain several of these.
launcher_log_state() {
    local log="$1"

    [[ -r "$log" ]] || return 0

    if grep -Fq 'Starting game at:' "$log"; then
        echo started
    elif grep -Eq 'Launcher update required|Differences found , start update|Bundle version mismatch|Strict Game check: [0-9]+/[0-9]+ files match, [1-9][0-9]* replacements|Failed to move downloaded bundle to final destination' "$log"; then
        echo update
    elif grep -Fq 'Failed to load remote manifest' "$log"; then
        echo manifest-stall
    elif grep -Eq 'Failed to get remote .* version info|Failed to download zip manifest|NetSpeedError|error decoding response body|operation timed out|source: TimedOut|Launcher error:' "$log"; then
        echo transient
    fi
}
