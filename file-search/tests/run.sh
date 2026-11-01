#!/bin/sh
# Runs every tests/*_test.lua. Each test is one chunk: this script prepends the
# unmodified panel source as the string PANEL_SRC, and the test stubs the host
# globals and loads it with loadstring.
#
# Convention for later tests of other modules (space.luau, ...): do the same,
# splice the module source as a string (MODULE_SRC) and load it with
# loadstring after stubbing the host globals. Native relative require() is not
# used: the runner below has no require, and the panel stubs it anyway.
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
        cat "$test"
    } > "$out"
    "$LUAU" "$out"
done
