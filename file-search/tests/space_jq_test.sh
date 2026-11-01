#!/bin/sh
# jq index reducer of space_index.luau, run on a real ncdu 2.9 output.
# Luau prints idx.jqProgram(2, 2, 8193, 0) (module spliced as MODULE_SRC, like
# run.sh does), jq runs it on tests/fixtures/small.ncdu.json, and the result
# must equal the JSON Lines index below (compared with jq -cS). A second run
# with relMin 0.002 checks the fold relative to the parent.
#
# Fixture: `ncdu -0 -o` of a tiny tmpfs tree, root renamed to "/fixture". The
# "skip" folder was dropped by an absolute `--exclude`. pic.png and
# b/pic-link.jpg are one inode (nlink 2): each counts half. tmpfs reports no
# folder dsize, so 4096 was added by hand to folder "a" (ext4 reports one).
# Checks: totals, category sums, top files per category (topN 2, ties by name),
# "deep" is the depth-2 leaf with "deeper" folded in, "b" (8192 < 8193) is
# folded into the root, names with a newline and a quote stay JSON strings.
# "a/locked" was added by hand: ncdu writes a folder it could not read as
# {"read_error":true}; u counts such folders in the subtree (1 at "a" and the
# root, 0 in "deep"). UP.MKV, x.tar.gz and .bashrc were also added by hand for
# the category rule: upper-case extension = video, last extension wins
# (archives), a dotfile and README (no extension) = other.
# "big" (synthetic, ~10 GiB) holds blob.img and two folders: "under" is just
# under 0.2% of big and "over" just over. With relMin 0 both are kept; with
# relMin 0.002 "under" is folded into big's f and "a" (57344 bytes, under 0.2%
# of the root) into the root's f.
set -e
cd "$(dirname "$0")/.."
if [ -z "$LUAU" ]; then
    if command -v luau >/dev/null 2>&1; then LUAU=luau; else LUAU=luau-test; fi
fi
tmp="${TMPDIR:-/tmp}/file-search-jq.$$"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT

{
    printf 'local MODULE_SRC = [==[\n'
    cat space_index.luau
    printf '\n]==]\n'
    printf 'local idx = loadstring(MODULE_SRC)()\n'
    printf 'print(idx.jqProgram(2, 2, 8193, 0))\n'
    printf 'print("--")\n'
    printf 'print(idx.jqProgram(2, 2, 8193, 0.002))\n'
} > "$tmp/prog.luau"
"$LUAU" "$tmp/prog.luau" > "$tmp/both.jq"
sed '/^--$/,$d' "$tmp/both.jq" > "$tmp/prog.jq"
sed '1,/^--$/d' "$tmp/both.jq" > "$tmp/rel.jq"
jq -c -f "$tmp/prog.jq" tests/fixtures/small.ncdu.json > "$tmp/got.json"
jq -c -f "$tmp/rel.jq" tests/fixtures/small.ncdu.json > "$tmp/rel.json"

# A stream of records (header, then one per kept folder in pre-order; id is
# the child-index path, "0" = root). jq -cS puts each on one line, so the
# record order is compared too.
cat > "$tmp/want.json" <<'EOF'
{"v":4,"root":"/fixture"}
{"id":"0",
  "n":"/fixture","s":10780651520,"nf":16,"f":53248,"u":1,
  "c":[45056,8192,4096,24576,4096,4096,10737426432,43134976],
  "t":[{"n":"UP.MKV","s":16384,"k":1},{"n":"c.mkv","s":16384,"k":1},
       {"n":"a/pic.png","s":4096,"k":2},{"n":"b/pic-link.jpg","s":4096,"k":2},
       {"n":"a/quo\"te.mp3","s":4096,"k":3},
       {"n":"a/deep/big.zip","s":20480,"k":4},{"n":"x.tar.gz","s":4096,"k":4},
       {"n":"a/new\nline.txt","s":4096,"k":5},
       {"n":"b/tiny.lua","s":4096,"k":6},
       {"n":"big/blob.img","s":10737418240,"k":7},{"n":"a/deep/deeper/core.iso","s":8192,"k":7},
       {"n":"big/over/o.bin","s":21651456,"k":8},{"n":"big/under/u.bin","s":21471232,"k":8}]}
{"id":"0/0",
  "n":"a","s":57344,"nf":6,"f":28672,"u":1,
  "c":[12288,4096,4096,20480,4096,0,8192,4096],
  "t":[{"n":"movie.mkv","s":12288,"k":1},{"n":"pic.png","s":4096,"k":2},
       {"n":"quo\"te.mp3","s":4096,"k":3},{"n":"deep/big.zip","s":20480,"k":4},
       {"n":"new\nline.txt","s":4096,"k":5},{"n":"deep/deeper/core.iso","s":8192,"k":7}]}
{"id":"0/0/0",
  "n":"deep","s":28672,"nf":2,"f":28672,"u":0,"leaf":true,
  "c":[0,0,0,20480,0,0,8192,0],
  "t":[{"n":"big.zip","s":20480,"k":4},{"n":"deeper/core.iso","s":8192,"k":7}]}
{"id":"0/1",
  "n":"big","s":10780540928,"nf":3,"f":10737418240,"u":0,
  "c":[0,0,0,0,0,0,10737418240,43122688],
  "t":[{"n":"blob.img","s":10737418240,"k":7},
       {"n":"over/o.bin","s":21651456,"k":8},{"n":"under/u.bin","s":21471232,"k":8}]}
{"id":"0/1/0",
  "n":"under","s":21471232,"nf":1,"f":21471232,"u":0,"leaf":true,
  "c":[0,0,0,0,0,0,0,21471232],
  "t":[{"n":"u.bin","s":21471232,"k":8}]}
{"id":"0/1/1",
  "n":"over","s":21651456,"nf":1,"f":21651456,"u":0,"leaf":true,
  "c":[0,0,0,0,0,0,0,21651456],
  "t":[{"n":"o.bin","s":21651456,"k":8}]}
EOF

# nf: files in the whole subtree (folded folders and unreadable "locked" count;
# excluded entries do not): hard links count once per name.

# relMin 0.002: id, name and f of each record; "a" and "under" are folded.
cat > "$tmp/rel_want.json" <<'EOF'
{"v":4,"root":"/fixture"}
["0","/fixture",110592]
["0/0","big",10758889472]
["0/0/0","over",21651456]
EOF

# got must already be one record per line: that is what the loader slices.
if [ "$(wc -l < "$tmp/got.json")" -ne 7 ] \
    || [ "$(jq -cS . "$tmp/got.json")" != "$(jq -cS . "$tmp/want.json")" ]; then
    echo "space_jq_test: FAIL" >&2
    cat "$tmp/got.json" >&2
    exit 1
fi
if [ "$(jq -c 'if .id then [.id, .n, .f] else . end' "$tmp/rel.json")" != "$(jq -c . "$tmp/rel_want.json")" ]; then
    echo "space_jq_test: FAIL (relMin)" >&2
    cat "$tmp/rel.json" >&2
    exit 1
fi
echo "space_jq_test: ok"
