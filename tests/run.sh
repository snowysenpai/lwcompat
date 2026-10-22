#!/usr/bin/env bash
# Run all LWCompat tests: syntax checks, shellcheck (if installed) and
# tests/test_*.sh. Nothing here touches the game, the prefix or the system.
set -u

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
failed=()

echo "== syntax"
for f in install.sh uninstall.sh src/*.sh tests/*.sh tools/*/*.sh; do
    bash -n "$f" || failed+=("bash -n $f")
done
for f in src/*.py; do
    python3 -I -c 'import ast,sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])' "$f" ||
        failed+=("python syntax $f")
done
(( ${#failed[@]} == 0 )) && echo "  ok"

echo "== shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -S warning -x install.sh uninstall.sh src/*.sh tests/*.sh tools/*/*.sh &&
        echo "  ok" || failed+=("shellcheck")
else
    echo "  skip  shellcheck not installed"
fi

for t in tests/test_*.sh; do
    echo "== ${t#tests/}"
    bash "$t" || failed+=("$t")
done

echo
if (( ${#failed[@]} )); then
    printf 'FAILED: %s\n' "${failed[@]}"
    exit 1
fi
echo "ALL TESTS PASSED"
