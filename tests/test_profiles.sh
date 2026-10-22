#!/usr/bin/env bash
# profiles.py on a synthetic user.reg: switching restores exactly the login
# values, keeps every other byte, and saves refreshed tokens on switch.
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
REG="$T/user.reg"
export LWCOMPAT_USER_REG="$REG" LWCOMPAT_APP_DIR="$T/app" LWCOMPAT_PROFILE_DIR="$T/app/profiles"
export LWCOMPAT_PROFILE_SKIP_CHECKS=1
prof() { python3 -I "$ROOT/src/profiles.py" "$@"; }

login_block() {  # account marker
    cat <<REG
"Login.access_token_h2663318312"=hex:$1,aa,bb,cc,dd,ee,ff,00,11,22,33,44,55,\\
  66,77,88,99,$1,00
"Login.access_token_time_h274858562"=dword:0000000$2
"Login.refresh_token_h1853727793"=hex:$1,10,20,30,40,50,60,70,80,90,a0,b0,\\
  c0,d0,$1,00
"Setting.GAME_UID_h4081398996"=hex:$1,31,32,33,00
"SERVER_PORT_h2862336198"=dword:0000047$2
REG
}

write_reg() {  # account marker
    {
        printf 'WINE REGISTRY Version 2\n;; All keys relative to \\\\User\\\\S-1-5-21\n\n'
        printf '[Software\\\\FunFly\\\\Last War-Survival Game] 1792669984\n#time=1dd4575fd0b5d64\n'
        printf '"1473445896001148GF_Done_1001_h111"=dword:00000001\n'
        login_block "$1" "$2"
        printf '"QualitySetting.Resolution_h222"=hex:31,30,38,30,\\\n  00\n\n'
        printf '[Software\\\\Wine\\\\X11 Driver] 1789520095\n"Decorated"="Y"\n\n'
    } > "$REG"
}

login_of() { python3 -I -c '
import re,sys
t=open(sys.argv[1]).read()
m=re.search(r"\"Login.refresh_token_h\d+\"=hex:(..)", t); print(m.group(1) if m else "none")' "$REG"; }

non_login() { grep -vE '^"(Login\.|Setting\.GAME_UID|SERVER_PORT)|^  ' "$REG"; }

write_reg a1 1
prof save alpha >/dev/null
cp "$REG" "$T/alpha.orig"

write_reg b2 2                 # the user logged into another account in the game
prof save beta >/dev/null

prof use alpha >/dev/null
assert_eq a1 "$(login_of)" "use alpha restores alpha's tokens"
diff <(non_login) <(grep -vE '^"(Login\.|Setting\.GAME_UID|SERVER_PORT)|^  ' "$T/alpha.orig") >/dev/null &&
    pass "every non-login value and other sections unchanged" || fail "non-login content changed"
python3 -I -c 'import sys; a=open(sys.argv[1]).read(); b=open(sys.argv[2]).read(); sys.exit(sorted(a.splitlines())!=sorted(b.splitlines()))' \
    "$REG" "$T/alpha.orig" && pass "file content equals the saved alpha state" || fail "alpha round trip"

# Playing as alpha refreshes its token; switching away must keep the new one.
sed -i 's/"Login.refresh_token_h1853727793"=hex:a1/"Login.refresh_token_h1853727793"=hex:a9/' "$REG"
prof use beta >/dev/null
assert_eq b2 "$(login_of)" "use beta loads beta"
prof use alpha >/dev/null
assert_eq a9 "$(login_of)" "alpha's refreshed token was saved on switch"

[[ "$(stat -c %a "$LWCOMPAT_PROFILE_DIR/alpha.reglines")" == 600 ]] && pass "profile files are 0600" || fail "profile mode"
ls "$T/app/backups/profiles"/user.reg.* >/dev/null 2>&1 && pass "user.reg backed up before switching" || fail "backup"
prof list | grep -q '^\* alpha$' && pass "list marks the active profile" || fail "list"
prof rename alpha main >/dev/null
prof list | grep -q '^\* main$' && pass "rename keeps the active marker" || fail "rename active"
[[ -f "$LWCOMPAT_PROFILE_DIR/main.reglines" && ! -e "$LWCOMPAT_PROFILE_DIR/alpha.reglines" ]] && pass "rename moves the profile" || fail "rename file"
prof rename beta main >/dev/null 2>&1 && fail "rename overwrote an existing profile" || pass "rename refuses to overwrite"
prof rename main 'x y' >/dev/null 2>&1 && fail "rename accepted an unsafe name" || pass "rename rejects unsafe names"
prof use main >/dev/null && assert_eq a9 "$(login_of)" "renamed profile still switches"

prof save 'bad/name' >/dev/null 2>&1 && fail "unsafe profile name accepted" || pass "unsafe profile name rejected"

printf '[Software\\\\FunFly\\\\Last War-Survival Game] 1\n"Other_h1"=dword:00000001\n\n' > "$REG"
prof save gamma >/dev/null 2>&1 && fail "saved a profile without a login" || pass "refuses to save without a login"

finish
