#!/usr/bin/env bash
# launcher_log_state on real Launcher.log samples plus edge cases.
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
source "$ROOT/src/launcher_log.sh"

F="$FIXTURES/launcher"
assert_eq started        "$(launcher_log_state "$F/started.log")"                "successful launch"
assert_eq manifest-stall "$(launcher_log_state "$F/manifest-stall.log")"         "manifest stall wins over generic 'Launcher error'"
assert_eq update         "$(launcher_log_state "$F/update-bundle-mismatch.log")" "bundle mismatch wins over zip-manifest timeout"
assert_eq transient      "$(launcher_log_state "$F/transient-zip-manifest.log")" "zip manifest timeout is transient"
assert_eq ""             "$(launcher_log_state "$F/undecided.log")"              "no decision while the launcher is still working"
assert_eq ""             "$(launcher_log_state "$F/does-not-exist.log")"         "missing log"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

echo '[x][Launcher::app::update][INFO] Strict Game check: 210/215 files match, 5 replacements, 0 extra/conflicting entries' > "$tmp"
assert_eq update "$(launcher_log_state "$tmp")" "non-zero replacements is an update"

echo '[x][Launcher::app::update][INFO] Strict Game check: 215/215 files match, 0 replacements, 0 extra/conflicting entries' > "$tmp"
assert_eq "" "$(launcher_log_state "$tmp")" "zero replacements is not an update"

cat "$F/manifest-stall.log" > "$tmp"
echo '[x][Launcher][INFO] Starting game at: "C:\\Game\\LastWar.exe"' >> "$tmp"
assert_eq started "$(launcher_log_state "$tmp")" "game start wins over earlier errors"

finish
