#!/usr/bin/env bash
# prefix_fonts.sh with a fake prefix and stub fc-list / wine.
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/prefix" "$T/bin" "$T/stub" "$T/hostfonts"
: > "$T/prefix/system.reg"
echo "fake font data" > "$T/hostfonts/Canadian.ttf"

# fc-list prints "<file>: " for an installed family, nothing otherwise.
cat > "$T/stub/fc-list" <<STUB
#!/bin/bash
[[ -f "$T/font-installed" && "\$1" == "Noto Sans Canadian Aboriginal" ]] && echo "$T/hostfonts/Canadian.ttf: "
exit 0
STUB
# wine reg add: append the value the way system.reg stores it; count calls.
cat > "$T/bin/wine" <<'STUB'
#!/bin/bash
echo x >> "$WINEPREFIX/wine.calls"
printf '"%s"="%s"\n' "$5" "$9" >> "$WINEPREFIX/system.reg"
STUB
printf '#!/bin/bash\nexit 0\n' > "$T/bin/wineserver"
chmod +x "$T/stub/fc-list" "$T/bin/wine" "$T/bin/wineserver"

run() { PATH="$T/stub:$PATH" bash "$ROOT/src/prefix_fonts.sh" "$T/prefix" "$T/bin"; }
calls() { [[ -f "$T/prefix/wine.calls" ]] && wc -l < "$T/prefix/wine.calls" || echo 0; }
F="$T/prefix/drive_c/windows/Fonts/NotoSansCanadianAboriginal.ttf"

out="$(run)"
grep -q 'WARNING: .Noto Sans Canadian Aboriginal. is not installed' <<<"$out" &&
    pass "missing host font only warns" || fail "missing font warning: $out"
[[ ! -e "$F" ]] && pass "  ... nothing copied" || fail "copied without a source"

touch "$T/font-installed"
out="$(run)"
cmp -s "$T/hostfonts/Canadian.ttf" "$F" && pass "host font copied into C:\\Windows\\Fonts" || fail "font copy"
grep -Fq '"Noto Sans Canadian Aboriginal (TrueType)"="NotoSansCanadianAboriginal.ttf"' "$T/prefix/system.reg" &&
    pass "font registered" || fail "registry value"
grep -q 'Added font' <<<"$out" && pass "  ... and logged" || fail "added log"

out="$(run)"
assert_eq 1 "$(calls)" "second run does not start wine again"
assert_eq "" "$out" "second run is silent"

rm -f "$F"
run >/dev/null
[[ -f "$F" ]] && pass "deleted font file is restored" || fail "restore file"
assert_eq 1 "$(calls)" "  ... without touching the registry again"

finish
