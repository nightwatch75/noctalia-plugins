#!/bin/sh
# Runs every *_test.lua next to this script (tests/claude-cockpit/, outside the
# plugin folder so the host does not install them). Run it from anywhere. Each
# test is one chunk: this script prepends the unmodified panel source as the
# string PANEL_SRC (a test whose first line is `-- module: <file>` also gets that
# plugin file as MODULE_SRC), and the test stubs the host globals and loads it with
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
        mod=$(sed -n '1s/^-- module: //p' "$test")
        if [ -n "$mod" ]; then
            printf 'local MODULE_SRC = [==[\n'
            cat "$mod"
            printf '\n]==]\n'
        fi
        cat "$test"
    } > "$out"
    "$LUAU" "$out"
done

sh "$here/list_sessions_test.sh"
LUAU="$LUAU" sh "$here/rename_append_test.sh"
sh "$here/orphans_test.sh"
sh "$here/usage_token_test.sh"
LUAU="$LUAU" sh "$here/cleanup_test.sh"
LUAU="$LUAU" sh "$here/repair_test.sh"
