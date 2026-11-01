#!/bin/sh
# Runs every tests/*_test.lua. Each test is one chunk: this script prepends the
# unmodified panel source as the string PANEL_SRC, and the test stubs the host
# globals and loads it with loadstring.
#
# A test that needs another module starts with the line `-- module: <file>`;
# this script then also splices that file as the string MODULE_SRC, and the
# test loads it with loadstring (after stubbing host globals if it needs any). Native relative require() is not
# used: the runner below has no require, and the panel stubs it anyway.
# `-- module: <file> <dep>...` splices every listed file into the table
# MODULES (keyed by file name), for a test whose require stub loads the real
# dependencies; MODULE_SRC is still the first one.
#
# Then it runs tests/space_jq_test.sh (shell + jq, not a *_test.lua): the jq
# index reducer of space_index.luau on a real ncdu fixture, and
# tests/space_script_test.sh: the real scan script under /bin/sh.
#
# Interpreter: `luau` from PATH if present, else `luau-test` (a ~40-line C++
# runner over the luau VM in the noctalia sources: compile + load + pcall, plus
# a loadstring global; built with g++ into ~/.local/bin). Override with LUAU=.
set -e
cd "$(dirname "$0")/.."
if [ -z "$LUAU" ]; then
    if command -v luau >/dev/null 2>&1; then LUAU=luau; else LUAU=luau-test; fi
fi
tmp="${TMPDIR:-/tmp}/file-search-tests.$$"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT
for test in tests/*_test.lua; do
    out="$tmp/$(basename "$test" .lua).luau"
    {
        printf 'local PANEL_SRC = [==[\n'
        cat panel.luau
        printf '\n]==]\n'
        mods=$(sed -n '1s/^-- module: //p' "$test")
        if [ -n "$mods" ]; then
            printf 'local MODULES = {}\n'
            for mod in $mods; do
                printf 'MODULES["%s"] = [==[\n' "$mod"
                cat "$mod"
                printf '\n]==]\n'
            done
            printf 'local MODULE_SRC = MODULES["%s"]\n' "${mods%% *}"
        fi
        cat "$test"
    } > "$out"
    "$LUAU" "$out"
done
LUAU="$LUAU" sh tests/space_jq_test.sh
LUAU="$LUAU" sh tests/space_script_test.sh
