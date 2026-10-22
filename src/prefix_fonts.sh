#!/usr/bin/env bash
# Make host-installed fonts available to the game for scripts that the Proton
# prefix does not cover but Windows does (players use them in names).
# Fonts are copied from the user's own system packages; LWCompat ships none.
#
#   prefix_fonts.sh PREFIX WINE_BIN_DIR
#
# Idempotent: does nothing once a font is in place and registered.
set -uo pipefail

PREFIX="$1"
WINE_BIN="$2"
FONTS_DIR="$PREFIX/drive_c/windows/Fonts"
REG_KEY='HKLM\Software\Microsoft\Windows NT\CurrentVersion\Fonts'

# family|file name in C:\Windows\Fonts|why
FONTS=(
    "Noto Sans Canadian Aboriginal|NotoSansCanadianAboriginal.ttf|U+1400-167F (Windows: Gadugi/Euphemia), e.g. ᘮ"
)

log() {
    printf '%(%H:%M:%S)T [LWCompat fonts] %s\n' -1 "$*"
}

registered() {  # registry value name
    grep -Fq "\"$1\"=" "$PREFIX/system.reg" 2>/dev/null
}

for entry in "${FONTS[@]}"; do
    IFS='|' read -r family target why <<<"$entry"
    value="$family (TrueType)"
    dest="$FONTS_DIR/$target"

    if [[ -f "$dest" ]] && registered "$value"; then
        continue
    fi

    src="$(fc-list "$family" file 2>/dev/null | head -n 1 | sed 's/: *$//')"
    if [[ -z "$src" || ! -f "$src" ]]; then
        log "WARNING: '$family' is not installed on this system ($why); some names may show boxes."
        continue
    fi

    mkdir -p "$FONTS_DIR"
    cp -f "$src" "$dest" || { log "WARNING: could not copy $src"; continue; }

    if ! registered "$value"; then
        WINEPREFIX="$PREFIX" WINEDEBUG=-all "$WINE_BIN/wine" reg add "$REG_KEY" \
            /v "$value" /t REG_SZ /d "$target" /f >/dev/null 2>&1
        WINEPREFIX="$PREFIX" "$WINE_BIN/wineserver" -w 2>/dev/null
    fi

    if registered "$value"; then
        log "Added font: $family"
    else
        log "WARNING: could not register $family in the prefix."
    fi
done

exit 0
