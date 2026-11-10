-- module: kuma.luau
-- summarize, buildDashboard and pushSample on hand-built Metric/Structure
-- tables (synthetic data). Run through tests/kuma-status/run.sh.

local K = loadstring(MODULE_SRC)()

local function eq(a, b, m) if a ~= b then error(m .. ": got " .. tostring(a) .. " want " .. tostring(b), 2) end end
local function list(t) return table.concat(t, ",") end

local function metric(id, name, status, extra)
    local m = { id = id, name = name, type = "http", status = status, tags = {} }
    for k, v in pairs(extra or {}) do m[k] = v end
    return m
end
local function set(...)
    local out = {}
    for _, m in ipairs({ ... }) do out[m.id] = m end
    return out
end

-- test: summarize_counts_and_color
local s = K.summarize(set(metric(1, "a", 1), metric(2, "b", 1), metric(3, "c", 0), metric(4, "d", 2)))
eq(s.up, 2, "up"); eq(s.down, 1, "down"); eq(s.pending, 1, "pending"); eq(s.color, "down", "down wins")
s = K.summarize(set(metric(1, "a", 1), metric(4, "d", 2)))
eq(s.color, "pending", "pending without down")
s = K.summarize(set(metric(1, "a", 1)))
eq(s.color, "up", "all up")

-- test: summarize_maintenance_counts_as_up_color_only
s = K.summarize(set(metric(1, "a", 3), metric(2, "b", 1)))
eq(s.up, 1, "maintenance not counted"); eq(s.color, "up", "maintenance keeps color up")
s = K.summarize(set(metric(1, "a", 3)))
eq(s.up, 0, "only maintenance: no up"); eq(s.color, "up", "only maintenance: color up")

-- test: summarize_empty_is_idle
s = K.summarize({})
eq(s.color, "idle", "no series is idle")
eq(s.up + s.down + s.pending, 0, "no counts")
s = K.summarize(set(metric(9, "grp", 1, { type = "group" })))
eq(s.color, "idle", "groups alone are idle"); eq(s.up, 0, "groups are not counted")

-- test: summarize_down_names_listed
s = K.summarize(set(metric(1, "zeta", 0), metric(2, "alpha", 0), metric(3, "ok", 1)))
eq(list(s.downNames), "alpha,zeta", "down names sorted")

-- test: tags_multi_tag_in_two_groups_counted_once
local metrics = set(
    metric(1, "a", 1, { tags = { "x", "y" } }),
    metric(2, "b", 0, { tags = { "x" } }),
    metric(3, "c", 1, { tags = {} }),
    metric(9, "grp", 1, { type = "group" })
)
local d = K.buildDashboard(metrics, nil, {}, {})
eq(d.mode, "tags", "mode")
eq(#d.groups, 3, "x, y and untagged")
eq(d.groups[1].name, "x", "sorted by name"); eq(#d.groups[1].rows, 2, "x has a and b")
eq(d.groups[2].name, "y", "y"); eq(#d.groups[2].rows, 1, "y has a")
s = K.summarize(metrics)
eq(s.up, 2, "a counted once despite two tags"); eq(s.down, 1, "down")

-- test: tags_untagged_group_last
eq(d.groups[3].name, "", "untagged group is last, empty name")
eq(d.groups[3].rows[1].name, "c", "untagged row")
eq(d.groups[1].up, 1, "x: a is up"); eq(d.groups[1].total, 2, "x total")

-- test: hierarchy_groups_from_structure
local structure = {
    [10] = { id = 10, name = "Prod", type = "group", children = { 11, 12, 20 }, tags = {}, active = true },
    [20] = { id = 20, name = "Sub", type = "group", parent = 10, children = { 13 }, tags = {}, active = true },
    [11] = { id = 11, name = "a", type = "http", parent = 10, children = {}, tags = {}, active = true },
    [12] = { id = 12, name = "b", type = "http", parent = 10, children = {}, tags = {}, active = false },
    [13] = { id = 13, name = "c", type = "http", parent = 20, children = {}, tags = {}, active = true },
    [14] = { id = 14, name = "loose", type = "http", children = {}, tags = {}, active = true },
}
local hm = set(
    metric(11, "a", 1, { ping = 40, uptime1d = 1.0 }), metric(13, "c", 0, { uptime1d = 0.5 }),
    metric(14, "loose", 1), metric(10, "Prod", 1, { type = "group" }), metric(20, "Sub", 1, { type = "group" })
)
d = K.buildDashboard(hm, structure, {}, {})
eq(d.mode, "hierarchy", "mode")
eq(#d.groups, 3, "Prod, Prod / Sub, ungrouped")
eq(d.groups[1].name, "Prod", "top group"); eq(d.groups[2].name, "Prod / Sub", "nested group path")
eq(d.groups[3].name, "", "ungrouped last"); eq(d.groups[3].rows[1].id, 14, "loose monitor")
eq(#d.groups[1].rows, 2, "Prod direct non-group children only")

-- test: hierarchy_paused_row_flagged
local paused
for _, r in ipairs(d.groups[1].rows) do if r.id == 12 then paused = r end end
eq(paused.paused, true, "monitor missing from /metrics is paused")
eq(paused.status, -1, "paused status is -1")
eq(d.groups[1].total, 1, "paused rows do not count in total")
eq(d.groups[1].up, 1, "up")

-- test: group_uptime_mean_nil_without_data
eq(d.groups[1].uptime1d, 1.0, "mean of children with data")
eq(d.groups[2].uptime1d, 0.5, "single child")
eq(d.groups[3].uptime1d, nil, "no data, no value")

-- test: row_beats_prefer_status_page_over_buffer
d = K.buildDashboard(hm, structure, { [11] = { 1, 1, 0 } }, { [11] = { 1 }, [13] = { 0, 0 } })
eq(list(d.groups[1].rows[1].beats), "1,1,0", "status page beats win")
eq(list(d.groups[2].rows[1].beats), "0,0", "buffer when no status page data")

-- test: pushsample_cap_drops_oldest
local buf = {}
for i = 1, 5 do K.pushSample(buf, 7, i, 3) end
eq(list(buf[7]), "3,4,5", "last 3 kept in order")

-- test: rows_carry_url_and_cert_days
d = K.buildDashboard(set(metric(1, "a", 1, { url = "https://u.example.test/", certDays = 12, tags = { "t" } })), nil, {}, {})
eq(d.groups[1].rows[1].url, "https://u.example.test/", "row url")
eq(d.groups[1].rows[1].certDays, 12, "row cert days")

print("model_test OK")
