#!/usr/bin/env bash
# start.sh: one log per session, lwcompat.log symlink, retention, legacy
# archive and exit code passthrough. Uses a stub lwcompat.sh.
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/logs"
printf 'old line 1\nold line 2\n' > "$T/logs/lwcompat.log"
printf '#!/usr/bin/env bash\necho "run $RUN"\nexit "${CODE:-0}"\n' > "$T/lwcompat.sh"
chmod +x "$T/lwcompat.sh"

# Pre-create 11 older sessions so retention is exercised without sleeping.
mkdir -p "$T/logs/sessions"
for i in $(seq -w 1 11); do : > "$T/logs/sessions/lwcompat-202601${i}-000000.log"; done

RUN=last CODE=7 LWCOMPAT_APP_DIR="$T" LWCOMPAT_KEEP_LOGS=10 bash "$ROOT/src/start.sh"
assert_eq 7 "$?" "exit code is passed through"

assert_eq 10 "$(ls "$T/logs/sessions"/lwcompat-2*.log | wc -l)" "keeps the newest 10 sessions"
[[ ! -e "$T/logs/sessions/lwcompat-20260101-000000.log" ]] && pass "oldest session pruned" || fail "oldest session pruned"
[[ -L "$T/logs/lwcompat.log" ]] && pass "lwcompat.log is a symlink" || fail "lwcompat.log is a symlink"
grep -q 'run last' "$T/logs/lwcompat.log" && pass "symlink points at the new session" || fail "symlink target"
grep -q 'LWCompat exit code: 7' "$T/logs/lwcompat.log" && pass "exit code logged" || fail "exit code logged"
assert_eq "old line 1" "$(zcat "$T/logs/sessions/lwcompat-legacy.log.gz" | head -1)" "old single log archived"

finish
