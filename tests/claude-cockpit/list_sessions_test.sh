#!/bin/sh
# Runs claude-cockpit/list-claude-sessions against a temp HOME and checks the
# audit fields: status (ok | relocated | misplaced | orphan), resolvedCwd,
# hasMemory and customTitle.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../../claude-cockpit/list-claude-sessions"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
home="$tmp/home"
proj="$home/.claude/projects"
real="$tmp/work"
odd="$tmp/work/my proj.v_è"
moved="$tmp/work/_git.repo_è" # a folder renamed after its sessions ran
other="$tmp/elsewhere"
mkdir -p "$proj" "$real" "$odd" "$moved" "$other"
# Many siblings: a normal tree must not hit the walk cap.
i=0; while [ $i -lt 400 ]; do mkdir "$tmp/work/sib$i"; i=$((i + 1)); done

# enc <path>: Claude Code's project dir name, one dash per character.
enc() { printf '%s' "$1" | LC_ALL=C.UTF-8 sed 's/[^A-Za-z0-9]/-/g'; }
# mk <project dir> <uuid> <jsonl line>...
mk() {
    d="$1"; id="$2"; shift 2
    mkdir -p "$proj/$d"
    : > "$proj/$d/$id.jsonl"
    for l in "$@"; do printf '%s\n' "$l" >> "$proj/$d/$id.jsonl"; done
}
user() { printf '{"type":"user","cwd":"%s"}' "$1"; }

long="$tmp/$(printf 'x%.0s' $(seq 1 210))"
mkdir -p "$long"

mk "$(enc "$real")" aaaa0001 "$(user "$real")"
mk "$(enc "$tmp/gone")" aaaa0002 "$(user "$tmp/gone")"
mk -nowhere-at-all aaaa0003 "$(user "$real")"
mk "$(enc "$odd")" aaaa0004 "$(user "$odd")"
mk wrong-dir aaaa0005 "$(user "$long")"
mk wrong-dir aaaa0006 '{"type":"user"}'
mk "$(enc "$real")" aaaa0007 "$(user "$real")" '{"type":"ai-title","aiTitle":"auto"}' \
    '{"type":"custom-title","customTitle":"first"}' '{"type":"custom-title","customTitle":"mine"}'
mk "$(enc "$moved")" aaaa0008 "$(user "$tmp/work/git-repo-old")"
# The recorded cwd exists too, but the project dir names another real folder.
mk "$(enc "$moved")" aaaa0009 "$(user "$other")"
mkdir -p "$proj/$(enc "$real")/memory" "$proj/$(enc "$tmp/gone")/memory"
: > "$proj/$(enc "$real")/memory/notes.md"

out=$(HOME="$home" "$script")
fail=0
check() { # <id> <field> <expected>
    got=$(printf '%s' "$out" | jq -r --arg id "$1" ".sessions[] | select(.id==\$id) | .$2")
    [ "$got" = "$3" ] || { echo "FAIL $1 $2: got '$got', want '$3'"; fail=1; }
}
check aaaa0001 status ok
check aaaa0001 resolvedCwd ""
check aaaa0002 status orphan
check aaaa0002 resolvedCwd ""
check aaaa0003 status misplaced
check aaaa0004 status ok
check aaaa0005 status ok
check aaaa0006 status ok
check aaaa0007 customTitle mine
check aaaa0001 customTitle ""
check aaaa0008 status relocated
check aaaa0008 resolvedCwd "$moved"
check aaaa0008 cwd "$tmp/work/git-repo-old"
check aaaa0009 status relocated
check aaaa0009 resolvedCwd "$moved"
check aaaa0001 hasMemory true
check aaaa0002 hasMemory false
check aaaa0003 hasMemory false
# The scan runs each file in an xargs -P child: a function missing from
# `export -f` gives an empty status, which the panel would read as "ok".
n=$(printf '%s' "$out" | jq '.sessions | length')
blank=$(printf '%s' "$out" | jq '[.sessions[] | select((.status // "") == "" or (.resolvedCwd | type) != "string" or (.hasMemory | type) != "boolean")] | length')
[ "$n" = 9 ] && [ "$blank" = 0 ] || { echo "FAIL fields missing in $blank of $n sessions"; fail=1; }
[ "$fail" = 0 ] && echo "list_sessions_test: ok"
exit "$fail"
