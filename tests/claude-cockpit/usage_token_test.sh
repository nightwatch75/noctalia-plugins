#!/bin/sh
# get-claude-usage must send the OAuth token to curl on stdin (-K -), never in
# argv, where other local users could read it from /proc/<pid>/cmdline. Runs
# the real script in a temp HOME with a fake curl that records argv and stdin.
set -e
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home/.claude/projects/-p" "$tmp/bin"
printf '{"claudeAiOauth":{"accessToken":"SECRET-TOKEN-123"}}' > "$tmp/home/.claude/.credentials.json"
cat > "$tmp/bin/curl" <<L
#!/bin/sh
printf '%s\n' "\$*" >> "$tmp/argv"
if [ "\$1" = -s ] && printf '%s' "\$*" | grep -q -- ' -K -'; then cat >> "$tmp/stdin"; fi
printf '{"five_hour":{"utilization":1}}'
L
chmod +x "$tmp/bin/curl"
HOME="$tmp/home" PATH="$tmp/bin:$PATH" bash "$here/../../claude-cockpit/get-claude-usage" --json >/dev/null 2>&1 || true
[ -s "$tmp/argv" ] || { echo "FAIL: curl never ran"; exit 1; }
if grep -q SECRET-TOKEN "$tmp/argv"; then echo "FAIL: token in curl argv"; cat "$tmp/argv"; exit 1; fi
grep -q 'Authorization: Bearer SECRET-TOKEN-123' "$tmp/stdin" || { echo "FAIL: header not on stdin"; cat "$tmp/stdin" 2>/dev/null; exit 1; }
echo "ok usage_token"
