#!/usr/bin/env bash
# overlay_ctl.sh: every key survives changes to the others.
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
ctl() { XDG_CONFIG_HOME="$T" bash "$ROOT/src/overlay_ctl.sh" "$@"; }
val() { grep -oP "^$1=\\K.*" "$T/lwcompat/settings.conf"; }

ctl custom on >/dev/null
ctl fps toggle >/dev/null
ctl hud on >/dev/null
assert_eq 1 "$(val LWCOMPAT_CUSTOM_HUD)" "custom HUD kept when FPS/DXVK HUD change"
assert_eq 1 "$(val LWCOMPAT_FPS)" "fps toggled on"
assert_eq 1 "$(val LWCOMPAT_HUD)" "DXVK HUD on"

ctl custom toggle >/dev/null
assert_eq 0 "$(val LWCOMPAT_CUSTOM_HUD)" "custom HUD toggled off"
assert_eq 1 "$(val LWCOMPAT_FPS)" "fps kept"

# Older two-line files (written by previous versions) still load.
printf 'LWCOMPAT_FPS=0\nLWCOMPAT_HUD=1\n' > "$T/lwcompat/settings.conf"
out="$(ctl status)"
grep -qx 'HUD : ON' <<<"$out" && pass "old file: DXVK HUD read" || fail "old file: DXVK HUD"
grep -qx 'CUSTOM HUD : OFF' <<<"$out" && pass "old file: custom HUD defaults to off" || fail "old file: custom default"
grep -qx 'FPS : OFF' <<<"$out" && pass "status lines keep the format the GUI matches" || fail "status format"

ctl custom bogus >/dev/null 2>&1 && fail "invalid state accepted" || pass "invalid state rejected"
finish
