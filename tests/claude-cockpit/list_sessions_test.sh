#!/bin/sh
# Runs claude-cockpit/list-claude-sessions against a temp HOME and checks the
# audit fields: status (ok | cwd_missing | dir_mismatch) and customTitle.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../../claude-cockpit/list-claude-sessions"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
home="$tmp/home"
proj="$home/.claude/projects"
real="$tmp/work"
odd="$tmp/work/my proj.v_è"
mkdir -p "$proj" "$real" "$odd"

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
mk wrong-dir aaaa0003 "$(user "$real")"
mk "$(enc "$odd")" aaaa0004 "$(user "$odd")"
mk wrong-dir aaaa0005 "$(user "$long")"
mk wrong-dir aaaa0006 '{"type":"user"}'
mk "$(enc "$real")" aaaa0007 "$(user "$real")" '{"type":"ai-title","aiTitle":"auto"}' \
    '{"type":"custom-title","customTitle":"first"}' '{"type":"custom-title","customTitle":"mine"}'

out=$(HOME="$home" "$script")
fail=0
check() { # <id> <field> <expected>
    got=$(printf '%s' "$out" | jq -r --arg id "$1" ".sessions[] | select(.id==\$id) | .$2")
    [ "$got" = "$3" ] || { echo "FAIL $1 $2: got '$got', want '$3'"; fail=1; }
}
check aaaa0001 status ok
check aaaa0002 status cwd_missing
check aaaa0003 status dir_mismatch
check aaaa0004 status ok
check aaaa0005 status ok
check aaaa0006 status ok
check aaaa0007 customTitle mine
check aaaa0001 customTitle ""
[ "$fail" = 0 ] && echo "list_sessions_test: ok"
exit "$fail"
