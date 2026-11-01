#!/bin/sh
# The real SCAN_SCRIPT of space.luau, run by /bin/sh with a stub ncdu (writes
# tests/fixtures/small.ncdu.json to its -o file) and the real jq. Luau prints
# space.SCAN_SCRIPT and idx.jqProgram (modules spliced as in run.sh, host
# stubbed). Every path sits under a folder with a hostile name, passed as
# positional arguments like space.luau does: nothing in it may run.
# Cases: ok (with nice), ncdu fails with no output (marker "empty"), ok with
# nice "" (none).
set -e
cd "$(dirname "$0")/.."
if [ -z "$LUAU" ]; then
    if command -v luau >/dev/null 2>&1; then LUAU=luau; else LUAU=luau-test; fi
fi
fail() { echo "space_script_test: FAIL: $*" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

{
    printf 'local MODULES = {}\n'
    for mod in space.luau shared.luau usage.luau space_index.luau; do
        printf 'MODULES["%s"] = [==[\n' "$mod"
        cat "$mod"
        printf '\n]==]\n'
    done
    cat <<'EOF'
noctalia = setmetatable({}, { __index = function() return function() end end })
local cache = {}
require = function(path)
    local name = path:gsub("^%./", "")
    cache[name] = cache[name] or assert(loadstring(MODULES[name], "=" .. name))()
    return cache[name]
end
local space = require("./space.luau")
print(space.SCAN_SCRIPT)
EOF
} > "$tmp/script.luau"
"$LUAU" "$tmp/script.luau" > "$tmp/script.sh"
sh -n "$tmp/script.sh" || fail "sh -n"
{
    printf 'local MODULE_SRC = [==[\n'
    cat space_index.luau
    printf '\n]==]\n'
    printf 'print(loadstring(MODULE_SRC)().jqProgram(6, 5, 1048576))\n'
} > "$tmp/prog.luau"
"$LUAU" "$tmp/prog.luau" > "$tmp/prog.jq"

hostile="$tmp/x \$(touch pwned) \`touch pwned\` 'q\" ;
nl"
mkdir -p "$hostile/root"
fixture="$(pwd)/tests/fixtures/small.ncdu.json"

# Stub ncdu: $FAIL set = exit 1 with no output; else the fixture to the -o
# file. It also records its oom_score_adj (inherited from the script).
cat > "$hostile/ncdu" <<EOF
#!/bin/sh
cat /proc/self/oom_score_adj > "\$OOM_FILE" 2>/dev/null || true
[ -n "\$FAIL" ] && exit 1
while [ \$# -gt 0 ]; do
    if [ "\$1" = "-o" ]; then cp "$fixture" "\$2"; fi
    shift
done
exit 1
EOF
chmod +x "$hostile/ncdu"
jq=$(command -v jq)
nice=$(command -v nice)

# $1 nice, $2 non-empty = ncdu fails. Files in $hostile, cwd $tmp.
run() {
    rm -f "$hostile"/space-* "$tmp/oom"
    (cd "$tmp" && OOM_FILE="$tmp/oom" FAIL="$2" /bin/sh -c "$(cat "$tmp/script.sh")" sh \
        "$hostile/ncdu" "$jq" "$(cat "$tmp/prog.jq")" \
        "$hostile/space-1.scan" "$hostile/space-1.tmp" "$hostile/space-root.json" "$hostile/space-1.done" \
        "$1" --exclude-kernfs --exclude "$hostile/a*b" -- "$hostile/root")
    [ -z "$(find "$tmp" -name pwned)" ] || fail "an argument was run as code"
    [ ! -e "$hostile/space-1.scan" ] && [ ! -e "$hostile/space-1.tmp" ] || fail "scan or temp file left"
}

for n in "$nice" ""; do
    run "$n"
    [ "$(cat "$hostile/space-1.done")" = ok ] || fail "marker (nice '$n'): $(cat "$hostile/space-1.done")"
    [ "$(cat "$tmp/oom")" = 1000 ] || fail "oom_score_adj not raised: $(cat "$tmp/oom")"
    head -n 1 "$hostile/space-root.json" | jq -e '.v == 2' >/dev/null || fail "index header"
    jq -c . "$hostile/space-root.json" >/dev/null || fail "index is not JSON Lines"
    [ "$(wc -l < "$hostile/space-root.json")" -gt 1 ] || fail "index has no records"
done

run "$nice" 1
[ "$(cat "$hostile/space-1.done")" = empty ] || fail "marker on a failed ncdu: $(cat "$hostile/space-1.done")"
[ ! -e "$hostile/space-root.json" ] || fail "index written by a failed scan"

echo "space_script_test: ok"
