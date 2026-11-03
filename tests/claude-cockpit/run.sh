#!/bin/sh
# Runs every *_test.lua next to this script (tests/claude-cockpit/, outside the
# plugin folder so the host does not install them). Run it from anywhere. Each
# test is one chunk: this script prepends the unmodified panel source as the
# string PANEL_SRC, and the test stubs the host globals and loads it with
# loadstring.
#
# Interpreter: `luau` from PATH if present, else `luau-test` (a small C++
# runner over the luau VM with a loadstring global). Override with LUAU=.
set -e
here=$(cd "$(dirname "$0")" && pwd)
cd "$here/../../claude-cockpit"
if [ -z "$LUAU" ]; then
    if command -v luau >/dev/null 2>&1; then LUAU=luau; else LUAU=luau-test; fi
fi
tmp="${TMPDIR:-/tmp}/claude-cockpit-tests.$$"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT
for test in "$here"/*_test.lua; do
    out="$tmp/$(basename "$test" .lua).luau"
    {
        printf 'local PANEL_SRC = [==[\n'
        cat panel.luau
        printf '\n]==]\n'
        cat "$test"
    } > "$out"
    "$LUAU" "$out"
done

sh "$here/list_sessions_test.sh"
