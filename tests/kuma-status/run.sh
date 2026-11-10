#!/bin/sh
# Runs every *_test.lua next to this script (tests/kuma-status/, outside the
# plugin folder so the host does not install them). Each test is one chunk:
# its first line `-- module: <file>...` names plugin files this script splices
# in as strings MODULES["<file>"]; MODULE_SRC is the first one. The test stubs
# host globals and loads a module with loadstring. Interpreter: `luau` from
# PATH, else `luau-test`. Override with LUAU=.
set -e
here=$(cd "$(dirname "$0")" && pwd)
cd "$here/../../kuma-status" # modules are read from the plugin folder
if [ -z "$LUAU" ]; then
    if command -v luau >/dev/null 2>&1; then LUAU=luau; else LUAU=luau-test; fi
fi
tmp="${TMPDIR:-/tmp}/kuma-status-tests.$$"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT
fail=0
for test in "$here"/*_test.lua; do
    out="$tmp/$(basename "$test" .lua).luau"
    {
        mods=$(sed -n '1s/^-- module: //p' "$test")
        printf 'local MODULES = {}\n'
        for mod in $mods; do
            printf 'MODULES["%s"] = [==[\n' "$mod"
            cat "$mod"
            printf '\n]==]\n'
        done
        printf 'local MODULE_SRC = MODULES["%s"]\n' "${mods%% *}"
        cat "$test"
    } > "$out"
    if "$LUAU" "$out"; then echo "PASS $(basename "$test")"; else echo "FAIL $(basename "$test")"; fail=1; fi
done
exit $fail
