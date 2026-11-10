-- module: kuma.luau
-- Parsing of Kuma data: /metrics text, /api/monitors, status page + heartbeat
-- JSON, and URL validation. All data is synthetic (the repo is public).
-- Run through tests/kuma-status/run.sh.

local K = loadstring(MODULE_SRC)()

local function eq(a, b, m) if a ~= b then error(m .. ": got " .. tostring(a) .. " want " .. tostring(b), 2) end end
local function list(t) return table.concat(t, ",") end

local function line(metric, tags, id, name, ty, value, window)
    local l = metric .. "{" .. tags .. 'monitor_id="' .. id .. '",monitor_name="' .. name .. '",monitor_type="' .. ty
        .. '",monitor_url="https://host-' .. id .. '.example.test/",monitor_hostname="null",monitor_port="null"'
    if window then l = l .. ',window="' .. window .. '"' end
    return l .. "} " .. value
end

local LONG = string.rep("x", 500)
local METRICS = table.concat({
    "# HELP monitor_status Monitor Status (1 = UP, 0= DOWN, 2= PENDING, 3= MAINTENANCE)",
    "# TYPE monitor_status gauge",
    line("monitor_status", 'alpha="",', 1, "svc-a", "http", 1),
    line("monitor_status", 'alpha="",beta="",', 2, "svc-b", "keyword", 0),
    line("monitor_status", "", 3, "grp-x", "group", 1),
    line("monitor_status", "", 4, "evil\\nname", "http", 2),
    line("monitor_status", "", 5, LONG, "http", 1),
    line("monitor_status", "", 6, 'quo\\"te', "http", 1),
    "# TYPE monitor_response_time gauge",
    line("monitor_response_time", 'alpha="",', 1, "svc-a", "http", 41),
    line("monitor_response_time", 'alpha="",beta="",', 2, "svc-b", "keyword", -1),
    line("monitor_uptime_ratio", 'alpha="",', 1, "svc-a", "http", 0.5, "30d"),
    line("monitor_uptime_ratio", 'alpha="",', 1, "svc-a", "http", 0.99, "1d"),
    line("monitor_cert_days_remaining", 'alpha="",', 1, "svc-a", "http", 60),
}, "\n")

local m = K.parseMetrics(METRICS)

-- test: metrics_tags_not_reserved
eq(list(m[1].tags), "alpha", "tags of 1")
eq(list(m[2].tags), "alpha,beta", "tags of 2")
eq(#m[3].tags, 0, "no tags on group")
eq(m[3].type, "group", "type")
eq(m[1].status, 1, "status up")
eq(m[2].status, 0, "status down")
eq(m[1].name, "svc-a", "name")

-- test: metrics_ping_minus_one_is_nil
eq(m[1].ping, 41, "ping")
eq(m[2].ping, nil, "ping -1 is nil")
eq(m[3].ping, nil, "ping absent is nil")
eq(m[1].uptime1d, 0.99, "uptime 1d, not 30d")
eq(m[1].certDays, 60, "cert days")

-- test: metrics_name_sanitized
eq(m[4].name, "evil name", "escaped newline becomes a space")
eq(#m[5].name <= 80, true, "long name truncated")
eq(m[6].name, 'quo"te', "escaped quote unescaped")

-- test: safetext_strips_controls_and_keeps_utf8
eq(K.safeText("a\nb\r\tc\0d", 80), "a b  c d", "controls to spaces")
local trunc = K.safeText(string.rep("è", 100), 80)
eq(utf8.len(trunc) ~= nil, true, "truncated text is valid utf8")
eq(utf8.len(trunc) <= 80, true, "at most 80 characters")

-- test: monitors_children_and_parent
local s = K.parseMonitors({ monitors = {
    { id = 10, name = "grp", type = "group", active = true, childrenIDs = { 11, 12 }, tags = {} },
    { id = 11, name = "a", type = "http", active = true, parent = 10, childrenIDs = {}, tags = { { name = "alpha" } } },
    { id = 12, name = "b", type = "http", active = false, parent = 10, childrenIDs = {}, tags = {} },
} })
eq(s[11].parent, 10, "parent")
eq(s[10].parent, nil, "no parent")
eq(list(s[10].children), "11,12", "children")
eq(s[12].active, false, "active flag")
eq(list(s[11].tags), "alpha", "tag names")

-- test: statusurl_rejects_other_schemes
for _, u in ipairs({ "ftp://h.example.test/status/dev", "javascript:alert(1)", "file:///status/dev", "" }) do
    local origin, slug, err = K.statusPageUrl(u)
    eq(origin, nil, "origin nil for " .. u)
    eq(type(err), "string", "err for " .. u)
end

-- test: statusurl_accepts_http_and_https
local o, sl = K.statusPageUrl("http://127.0.0.1:3002/status/dev")
eq(o, "http://127.0.0.1:3002", "http origin")
eq(sl, "dev", "slug")
o, sl = K.statusPageUrl("https://status.example.test/status/Dev/")
eq(o, "https://status.example.test", "https origin")
eq(sl, "dev", "slug lowercased, trailing slash ok")

-- test: statusurl_requires_status_path
for _, u in ipairs({ "https://h.example.test/", "https://h.example.test/status", "https://h.example.test/other/dev" }) do
    local origin = K.statusPageUrl(u)
    eq(origin, nil, "rejected " .. u)
end

-- test: baseurl_accepts_http_and_https_rejects_others
eq(K.baseUrl("https://h.example.test/"), "https://h.example.test", "trailing slash")
eq(K.baseUrl("http://127.0.0.1:3002"), "http://127.0.0.1:3002", "http loopback")
eq(K.baseUrl("https://h.example.test/kuma/"), "https://h.example.test/kuma", "subpath kept")
for _, u in ipairs({ "ftp://x", "https://", "javascript:alert(1)", "https://a b.example.test", "" }) do
    eq(K.baseUrl(u), nil, "rejected " .. u)
end

-- test: statuspage_keeps_last_40_beats
local beats = {}
for i = 1, 60 do beats[i] = { status = i % 2, time = "t" .. i, ping = i } end
local page = { config = { title = "Dev board" }, publicGroupList = { { name = "G", monitorList = { { id = 1, name = "svc-a" }, { id = 2, name = "svc-b" } } } } }
local hb = { heartbeatList = { ["1"] = beats }, uptimeList = {} }
local sp = K.parseStatusPage(page, hb, "https://status.example.test", "dev")
eq(sp.title, "Dev board", "title")
eq(sp.url, "https://status.example.test/status/dev", "url")
eq(#sp.groups[1].monitors[1].beats, 40, "40 beats")
eq(sp.groups[1].monitors[1].beats[40], 0, "newest last (60 % 2)")
eq(sp.groups[1].monitors[1].beats[1], 1, "oldest kept is beat 21")

-- test: statuspage_string_ids_and_empty_beats
eq(sp.groups[1].monitors[2].id, 2, "id is a number")
eq(#sp.groups[1].monitors[2].beats, 0, "no beats, no error")

-- test: metrics_url_from_label_or_host_port
local custom = table.concat({
    'monitor_status{monitor_id="21",monitor_name="has-url",monitor_type="http",monitor_url="https://svc.example.test/health",monitor_hostname="null",monitor_port="null"} 1',
    'monitor_status{monitor_id="22",monitor_name="host-only",monitor_type="port",monitor_url="null",monitor_hostname="h.example.test",monitor_port="8883"} 1',
    'monitor_status{monitor_id="23",monitor_name="none",monitor_type="group",monitor_url="null",monitor_hostname="null",monitor_port="null"} 1',
}, "\n")
local cm = K.parseMetrics(custom)
eq(cm[21].url, "https://svc.example.test/health", "url label")
eq(cm[22].url, "h.example.test:8883", "hostname:port fallback")
eq(cm[23].url, nil, "nothing to show")

print("parse_test OK")
