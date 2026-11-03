#!/bin/sh
# Runs the exact argv repairSession execs (captured from sessions.luau) in a
# temp HOME: the transcript and sidecar move to the encoded project dir, an
# existing file is never overwritten, other sessions stay untouched.
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
    fileExists = function(p) return p == "$tmp/.claude/projects/-old/ab-1" end,
    runAsync = function(argv, cb)
        print(table.concat(argv, "\\31")); cb({ exitCode = 0 }); return true
    end,
}
local s = loadstring(MODULE_SRC)()
local g = s.groupByProject({ { id = "ab-1", projectDir = "-old", cwd = "$tmp/new w", mtime = 1, status = "dir_mismatch" } })
s.repairSession(g[1].sessions[1], function() end)
L
} > "$tmp/capture.luau"
"$LUAU" "$tmp/capture.luau" > "$tmp/out"
[ "$(wc -l < "$tmp/out")" -eq 4 ] || { echo "FAIL: captured argv"; cat "$tmp/out"; exit 1; }
runstep() { # run argv line $1 for real
    n=$1
    set --
    oldifs=$IFS; IFS=$(printf '\037')
    set -- $(sed -n "${n}p" "$tmp/out")
    IFS=$oldifs
    "$@"
}
enc="$tmp/.claude/projects/-$(printf '%s' "${tmp#/}" | sed 's/[^A-Za-z0-9]/-/g')-new-w"
setup() {
    rm -rf "$tmp/.claude" "$tmp/new w"
    mkdir -p "$tmp/.claude/projects/-old/ab-1" "$tmp/.claude/projects/-other"
    echo mine > "$tmp/.claude/projects/-old/ab-1.jsonl"
    echo sub > "$tmp/.claude/projects/-old/ab-1/sub.txt"
    echo theirs > "$tmp/.claude/projects/-other/cd-2.jsonl"
}
setup
for i in 1 2 3 4; do runstep $i; done
[ -d "$tmp/new w" ] || { echo "FAIL a: cwd not created"; exit 1; }
[ "$(cat "$enc/ab-1.jsonl")" = mine ] && [ -f "$enc/ab-1/sub.txt" ] || { echo "FAIL b: not moved"; exit 1; }
[ ! -e "$tmp/.claude/projects/-old/ab-1.jsonl" ] && [ ! -e "$tmp/.claude/projects/-old/ab-1" ] || { echo "FAIL c: source kept"; exit 1; }
[ "$(cat "$tmp/.claude/projects/-other/cd-2.jsonl")" = theirs ] || { echo "FAIL d: other session touched"; exit 1; }
setup
mkdir -p "$enc"; echo keep > "$enc/ab-1.jsonl"
runstep 3
[ "$(cat "$enc/ab-1.jsonl")" = keep ] || { echo "FAIL e: overwritten"; exit 1; }
[ -f "$tmp/.claude/projects/-old/ab-1.jsonl" ] || { echo "FAIL f: source lost"; exit 1; }
echo "repair_test ok"
