#!/bin/sh
# Runs claude-cockpit/list-claude-orphans against a temp HOME and checks which
# leftovers it lists: only old, unreferenced, UUID-named id folders and project
# dirs holding nothing (or only an empty memory/).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../../claude-cockpit/list-claude-orphans"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
home="$tmp/home"
c="$home/.claude"
mkdir -p "$c/projects" "$c/session-env" "$c/file-history"
old='2 days ago'

U1=11111111-1111-1111-1111-111111111111 # old, orphan
U2=22222222-2222-2222-2222-222222222222 # young
U3=33333333-3333-3333-3333-333333333333 # has a jsonl
U4=44444444-4444-4444-4444-444444444444 # excluded
U5=55555555-5555-5555-5555-555555555555 # file-history orphan
mkid() { mkdir -p "$1"; echo x > "$1/f"; touch -d "$2" "$1/f" "$1"; }
mkid "$c/session-env/$U1" "$old"
mkid "$c/session-env/$U2" '1 hour ago'
mkid "$c/session-env/$U3" "$old"
mkid "$c/session-env/$U4" "$old"
mkid "$c/session-env/not-a-uuid" "$old"
mkid "$c/file-history/$U5" "$old"
mkdir -p "$c/projects/-has"; : > "$c/projects/-has/$U3.jsonl"

mkdir -p "$c/projects/-has"; : > "$c/projects/-has/.jsonl"
mkp() { mkdir -p "$c/projects/$1"; }
mkp -empty; mkp -emptymem; mkdir "$c/projects/-emptymem/memory"
mkp -mem; mkdir "$c/projects/-mem/memory"; echo x > "$c/projects/-mem/memory/x.md"
mkp -file; echo x > "$c/projects/-file/other.txt"
mkp -young
for p in -empty -emptymem -mem -file; do touch -d "$old" "$c/projects/$p"; done

out=$(HOME="$home" "$script" --exclude "$U4" --exclude zzz --exclude "")
got=$(printf '%s' "$out" | jq -r '.orphans[] | .kind + " " + (.path | split("/") | last)' | sort)
want=$(printf '%s\n' "file-history $U5" "project -empty" "project -emptymem" "session-env $U1" | sort)
if [ "$got" != "$want" ]; then
    printf 'FAIL\n got:\n%s\n want:\n%s\n' "$got" "$want"
    exit 1
fi
printf '%s' "$out" | jq -e '[.orphans[] | .bytes | type == "number"] | all' >/dev/null || { echo "FAIL bytes"; exit 1; }
# read-only
[ -d "$c/session-env/$U1" ] || { echo "FAIL removed something"; exit 1; }
echo "orphans_test ok"
