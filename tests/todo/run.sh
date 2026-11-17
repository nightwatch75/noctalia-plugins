#!/bin/sh
# Runs every *_test.lua next to this script (tests/todo/, outside the plugin
# folder so the host does not install them). A test starts with the line
# `-- module: <file> [<file>...]`; this script splices each file from todo/ into
# the table MODULES (keyed by file name) and the first one as the string
# MODULE_SRC; the test loads them with loadstring. Run it from anywhere.
# Interpreter: `luau` from PATH, else `luau-test` (~/.local/bin). Override with LUAU=.
set -e
here=$(cd "$(dirname "$0")" && pwd)
cd "$here/../../todo"
if [ -z "$LUAU" ]; then
    if command -v luau >/dev/null 2>&1; then LUAU=luau; else LUAU=luau-test; fi
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for test in "$here"/*_test.lua; do
    [ -e "$test" ] || continue
    out="$tmp/$(basename "$test" .lua).luau"
    mods=$(sed -n '1s/^-- module: //p' "$test")
    {
        printf 'local MODULES = {}\n'
        for mod in $mods; do
            printf 'MODULES["%s"] = [==[\n' "$mod"
            cat "$mod"
            printf '\n]==]\n'
        done
        printf 'local MODULE_SRC = MODULES["%s"]\n' "${mods%% *}"
        cat "$test"
    } > "$out"
    # date math must hold in any timezone, not just the one of this machine
    for tz in UTC Europe/Rome America/New_York Pacific/Kiritimati; do
        TZ=$tz "$LUAU" "$out"
    done
    echo "ok $(basename "$test")"
done
