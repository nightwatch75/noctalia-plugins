-- module: kuma.luau
-- CPU budget: the host allows ~25 ms per callback. Builds a production-sized
-- synthetic data set (52 monitors, 100 heartbeats each, a /metrics text of
-- ~250 KB with long labels) and times each pure function; each must stay
-- under 15 ms. JSON decode is native and not measured here. Run through
-- tests/kuma-status/run.sh.

local K = loadstring(MODULE_SRC)()
local LIMIT_MS = 15

local function timed(name, fn)
    local t = os.clock()
    local r = fn()
    local ms = (os.clock() - t) * 1000
    print(string.format("%-18s %6.2f ms", name, ms))
    if ms >= LIMIT_MS then error(name .. " took " .. ms .. " ms (limit " .. LIMIT_MS .. ")") end
    return r
end

local pad = string.rep("p", 120)
local lines = {}
for id = 1, 52 do
    local base = 'tag_a="",tag_b="",monitor_id="' .. id .. '",monitor_name="svc-' .. id .. '",monitor_type="http",monitor_url="https://host-'
        .. id .. ".example.test/" .. pad .. '",monitor_hostname="host-' .. id .. '.example.test",monitor_port="443"'
    for _, w in ipairs({ "1d", "30d", "365d" }) do
        lines[#lines + 1] = "monitor_uptime_ratio{" .. base .. ',window="' .. w .. '"} 0.99'
        lines[#lines + 1] = "monitor_response_time_seconds{" .. base .. ',window="' .. w .. '"} 0.05'
    end
    for _, m in ipairs({ "monitor_cert_days_remaining", "monitor_cert_is_valid", "monitor_response_time", "monitor_status" }) do
        lines[#lines + 1] = m .. "{" .. base .. "} 1"
    end
end
local text = table.concat(lines, "\n")
print(string.format("metrics text: %d KB, %d lines", #text // 1024, #lines))

local metrics = timed("parseMetrics", function() return K.parseMetrics(text) end)
timed("parse step (150)", function() return K.metricsParser(text).step(150) end)

local monitors, beats = {}, {}
for id = 1, 52 do
    monitors[#monitors + 1] = { id = id, name = "svc-" .. id }
    local b = {}
    for i = 1, 100 do b[i] = { status = 1, time = "2026-01-01 00:00:00.000", ping = 12 } end
    beats[tostring(id)] = b
end
local page = { config = { title = "Board" }, publicGroupList = { { name = "G", monitorList = monitors } } }
local sp = timed("parseStatusPage", function() return K.parseStatusPage(page, { heartbeatList = beats }, "https://s.example.test", "dev") end)

local beatsById = {}
for _, m in ipairs(sp.groups[1].monitors) do beatsById[m.id] = m.beats end
timed("summarize", function() return K.summarize(metrics) end)
local d = timed("buildDashboard", function() return K.buildDashboard(metrics, nil, beatsById, {}) end)
assert(#d.groups[1].rows == 52, "52 rows in the tag group")
for _, m in pairs(metrics) do m.certDays = 40 end
local certs = timed("buildCertificates", function() return K.buildCertificates(metrics) end)
assert(certs.total == 52, "52 certificates")

print("budget_test OK")
