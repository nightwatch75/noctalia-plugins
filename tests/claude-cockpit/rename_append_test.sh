#!/bin/sh
# Runs the exact argv renameSession execs (captured from sessions.luau, so the
# shell snippet has one source) against temp files with and without a final
# newline; each must end with N+1 lines of valid JSON, the last one the title.
# The json.encode stub escapes like a real encoder; jq does the decoding.
set -e
here=$(cd "$(dirname "$0")" && pwd)
LUAU=${LUAU:-$(command -v luau || echo luau-test)}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
{
    printf 'local MODULE_SRC = [==[\n'
    cat "$here/../../claude-cockpit/sessions.luau"
    printf '\n]==]\n'
    cat <<'L'
local function enc(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        if c == '"' then return '\\"' elseif c == "\\" then return "\\\\" end
        return string.format("\\u%04x", c:byte())
    end) .. '"'
end
noctalia = {
    expandPath = function(p) return (p:gsub("^~", "/h")) end,
    tr = function(k) return k end, pluginDir = function() return "/p" end,
    json = { encode = function(t)
        return '{"type":' .. enc(t.type) .. ',"customTitle":' .. enc(t.customTitle) .. ',"sessionId":' .. enc(t.sessionId) .. '}'
    end },
    runAsync = function(argv, cb)
        print(argv[3]); print(argv[6]); return true
    end,
}
local s = loadstring(MODULE_SRC)()
s.renameSession({ id = "ab-1", jsonlPath = "J" }, 'a"b\\c\nd é 😀', function() end)
L
} > "$tmp/capture.luau"
"$LUAU" "$tmp/capture.luau" > "$tmp/out"
script=$(sed -n 1p "$tmp/out")
line=$(sed -n 2p "$tmp/out")
want='a"b\c d é 😀'
for tail in newline none; do
    f="$tmp/$tail.jsonl"
    printf '{"type":"user"}\n{"type":"x"}' > "$f"
    [ "$tail" = newline ] && printf '\n' >> "$f"
    sh -c "$script" sh "$f" "$line"
    [ "$(wc -l < "$f")" -eq 3 ] || { echo "FAIL $tail: line count"; exit 1; }
    jq -e . "$f" >/dev/null || { echo "FAIL $tail: invalid JSON"; exit 1; }
    [ "$(tail -n1 "$f" | jq -r .customTitle)" = "$want" ] || { echo "FAIL $tail: title"; exit 1; }
done
m="$tmp/missing.jsonl"
if sh -c "$script" sh "$m" "$line"; then echo "FAIL missing: exit 0"; exit 1; fi
[ ! -e "$m" ] || { echo "FAIL missing: file created"; exit 1; }
echo "rename_append_test ok"
