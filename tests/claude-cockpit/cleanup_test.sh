#!/bin/sh
# Runs the exact argv deleteSession execs for the session-env/file-history
# cleanup (captured from sessions.luau) in a temp HOME: the id folders go when
# this is the only transcript with that id, and stay while a copy remains in
# another project folder.
set -e
here=$(cd "$(dirname "$0")" && pwd)
LUAU=${LUAU:-$(command -v luau || echo luau-test)}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
{
    printf 'local MODULE_SRC = [==[\n'
    cat "$here/../../claude-cockpit/sessions.luau"
    printf '\n]==]\n'
    cat <<L
noctalia = {
    expandPath = function(p) return (p:gsub("^~", "$tmp")) end,
    tr = function(k) return k end, pluginDir = function() return "/p" end,
    runAsync = function(argv, cb)
        if argv[1] == "sh" then for i = 3, 8 do print(argv[i]) end end
        cb({ exitCode = 0 }); return true
    end,
}
local s = loadstring(MODULE_SRC)()
local g = s.groupByProject({ { id = "ab-1", projectDir = "-p", cwd = "/w", mtime = 1 } })
s.deleteSession(g[1].sessions[1], function() end)
L
} > "$tmp/capture.luau"
"$LUAU" "$tmp/capture.luau" > "$tmp/out"
[ "$(wc -l < "$tmp/out")" -eq 6 ] || { echo "FAIL: captured argv"; cat "$tmp/out"; exit 1; }
script=$(sed -n 1p "$tmp/out"); p1=$(sed -n 3p "$tmp/out"); p2=$(sed -n 4p "$tmp/out")
p3=$(sed -n 5p "$tmp/out"); p4=$(sed -n 6p "$tmp/out")
setup() {
    rm -rf "$tmp/.claude"
    mkdir -p "$tmp/.claude/session-env/ab-1" "$tmp/.claude/file-history/ab-1" "$tmp/.claude/projects/-p" "$tmp/.claude/projects/-q"
}
run() { sh -c "$script" sh "$p1" "$p2" "$p3" "$p4"; }
setup
run
[ ! -e "$tmp/.claude/session-env/ab-1" ] && [ ! -e "$tmp/.claude/file-history/ab-1" ] || { echo "FAIL a: folders kept"; exit 1; }
setup
: > "$tmp/.claude/projects/-q/ab-1.jsonl"
run
[ -d "$tmp/.claude/session-env/ab-1" ] && [ -d "$tmp/.claude/file-history/ab-1" ] || { echo "FAIL b: folders removed"; exit 1; }
echo "cleanup_test ok"
