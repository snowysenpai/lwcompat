#!/usr/bin/env bash
# Build the repro and run it against the Last War manifest with a given Proton.
#   tools/wine-schannel-repro/run.sh [/path/to/Proton]
# Uses a throwaway prefix; the game prefix is never touched.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROTON="${1:-}"
if [[ -z "$PROTON" ]]; then
    # shellcheck disable=SC1090
    source "${LWCOMPAT_APP_DIR:-$HOME/.local/share/lwcompat}/config.sh"
    PROTON="$LWCOMPAT_PROTON"
fi

WINE="$PROTON/files/bin/wine"
[[ -x "$WINE" ]] || { echo "wine not found in $PROTON" >&2; exit 2; }

WORK="${XDG_CACHE_HOME:-$HOME/.cache}/lwcompat/schannel-repro"
mkdir -p "$WORK/prefix"

x86_64-w64-mingw32-gcc -O2 -municode -o "$WORK/sspi_get.exe" "$HERE/sspi_get.c" -lws2_32 -lsecur32

export WINEPREFIX="$WORK/prefix" WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml="
[[ -f "$WINEPREFIX/system.reg" ]] || "$WINE" wineboot -i >/dev/null 2>&1

HOST=lastwar-cdn.akamaized.net
URL_PATH=/hotupdate/pc/micro/manifest/all/manifests/1101.json

echo "Proton: $(cat "$PROTON/version" 2>/dev/null || echo "$PROTON")"
rc=0
for i in 1 2 3; do
    out="$(RUSTMODE=1 SCH5=1 timeout 60 "$WINE" "$WORK/sspi_get.exe" "$HOST" "$URL_PATH" 2>&1 || true)"
    if grep -q 'COMPLETE' <<<"$out"; then
        echo "run $i: OK"
    else
        echo "run $i: STALL"; rc=1
    fi
    grep -m1 'MISSING WRONG' <<<"$out" | sed 's/^/        /' || true
done
"$PROTON/files/bin/wineserver" -k 2>/dev/null || true

if (( rc == 0 )); then
    echo "RESULT: this Proton is not affected."
else
    echo "RESULT: this Proton has the SECBUFFER_MISSING bug (Wine < 11.6 / commit 35b1e7eb)."
fi
exit "$rc"
