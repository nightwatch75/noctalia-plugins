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

-- test: tags_first_tag_only_puts_a_monitor_in_one_group
local multi = set(
    metric(1, "a", 1, { tags = { "x", "y" } }),
    metric(2, "b", 0, { tags = { "y" } }),
    metric(3, "c", 1, { tags = {} })
)
d = K.buildDashboard(multi, nil, {}, {}, { firstTagOnly = true })
eq(#d.groups, 3, "x, y and untagged")
eq(d.groups[1].name, "x", "x"); eq(#d.groups[1].rows, 1, "a only in x")
eq(d.groups[2].name, "y", "y"); eq(#d.groups[2].rows, 1, "y holds just b"); eq(d.groups[2].rows[1].name, "b", "b")
eq(d.groups[3].name, "", "untagged last")
d = K.buildDashboard(multi, nil, {}, {})
eq(#d.groups[2].rows, 2, "default keeps duplicates: y holds a and b")

-- test: cert_level_boundaries
eq(K.certLevel(-1), "expired", "negative"); eq(K.certLevel(0), "red", "today is red, not expired")
eq(K.certLevel(7), "red", "7 days is still red"); eq(K.certLevel(8), "yellow", "8 days")
eq(K.certLevel(30), "yellow", "30 days is still yellow"); eq(K.certLevel(31), "green", "31 days")

-- test: cert_limits_are_configurable_and_normalized
local lim = K.certLimits()
eq(lim.red, 7, "default red"); eq(lim.yellow, 30, "default yellow")
eq(K.certLevel(10, { red = 14, yellow = 60 }), "red", "custom red limit"); eq(K.certLevel(61, { red = 14, yellow = 60 }), "green", "custom yellow limit")
lim = K.certLimits(10, 5)
eq(lim.red, 10, "red kept"); eq(lim.yellow, 11, "yellow is always above red")
lim = K.certLimits("x", nil)
eq(lim.red, 7, "bad red falls back"); eq(lim.yellow, 30, "bad yellow falls back")
lim = K.certLimits(0, 0)
eq(lim.red, 1, "red at least 1"); eq(lim.yellow, 2, "yellow above it")
lim = K.certLimits(9999, 9999)
eq(lim.red, 365, "red capped"); eq(lim.yellow, 730, "yellow capped")
eq(K.certLimits(7.9, 30.2).red, 7, "whole days")

-- test: certificates_sorted_by_expiry_and_grouped
local cm = set(
    metric(1, "far", 1, { certDays = 45, url = "https://far.example.test" }),
    metric(2, "near", 1, { certDays = 5, url = "https://near.example.test" }),
    metric(3, "mid", 1, { certDays = 20 }),
    metric(4, "gone", 0, { certDays = -2 }),
    metric(5, "nocert", 1),
    metric(9, "grp", 1, { type = "group", certDays = 1 })
)
local c = K.buildCertificates(cm)
eq(#c.groups, 4, "expired, red, yellow, green")
eq(c.groups[1].level, "expired", "first group"); eq(c.groups[2].level, "red", "second"); eq(c.groups[3].level, "yellow", "third"); eq(c.groups[4].level, "green", "fourth")
eq(c.groups[1].rows[1].name, "gone", "expired row"); eq(c.groups[2].rows[1].name, "near", "red row")
eq(c.groups[2].rows[1].url, "https://near.example.test", "url on the row"); eq(c.groups[2].rows[1].certDays, 5, "days on the row")
eq(c.total, 4, "monitors without a certificate and groups are left out")
local flat = {}
for _, g in ipairs(c.groups) do for _, r in ipairs(g.rows) do flat[#flat + 1] = r.name end end
eq(list(flat), "gone,near,mid,far", "shortest first overall")

-- test: certificates_use_the_given_limits
c = K.buildCertificates(cm, { red = 3, yellow = 10 })
eq(c.groups[2].level, "yellow", "5 days is yellow with red 3"); eq(c.groups[2].rows[1].name, "near", "near moved to yellow")
eq(c.groups[3].level, "green", "20 days is green with yellow 10")

-- test: due_certs_once_a_day
local lim0 = { red = 7, yellow = 30 }
local due = K.dueCerts(cm, lim0, nil, 1000)
eq(#due, 2, "expired and red only"); eq(due[1].name, "gone", "shortest first"); eq(due[1].level, "expired", "level kept"); eq(due[2].name, "near", "red one")
eq(#K.dueCerts(cm, lim0, 1000, 1000 + 86399), 0, "not due before 24 h")
eq(#K.dueCerts(cm, lim0, 1000, 1000 + 86400), 2, "due after 24 h")
eq(#K.dueCerts(set(metric(1, "ok", 1, { certDays = 99 })), lim0, nil, 1000), 0, "nothing red, nothing due")

-- test: certificates_empty_groups_are_omitted
c = K.buildCertificates(set(metric(1, "a", 1, { certDays = 99 })))
eq(#c.groups, 1, "only the green group"); eq(c.groups[1].level, "green", "green")
eq(K.buildCertificates({}).total, 0, "nothing")

-- test: dashboard_rows_carry_cert_level
d = K.buildDashboard(set(metric(1, "a", 1, { certDays = 12, tags = { "t" } }), metric(2, "b", 1, { certDays = 7, tags = { "t" } })), nil, {}, {})
eq(d.groups[1].rows[1].certLevel, "yellow", "12 days is yellow"); eq(d.groups[1].rows[2].certLevel, "red", "7 days is red")

-- test: dashboard_rows_use_the_given_limits
d = K.buildDashboard(set(metric(1, "a", 1, { certDays = 12, tags = { "t" } })), nil, {}, {}, { certLimits = { red = 14, yellow = 60 } })
eq(d.groups[1].rows[1].certLevel, "red", "12 days is red with red 14")

-- test: group_tags_group_by_listed_tags_in_priority_order
local gt = set(
    metric(1, "stage-a2a", 1, { tags = { "A2A", "Collaudo" } }),
    metric(2, "prod-iotron", 1, { tags = { "IoTron", "Produzione" } }),
    metric(3, "dev-prod", 1, { tags = { "DEV", "Produzione" } }),
    metric(4, "other", 1, { tags = { "Leonardo" } }),
    metric(5, "bare", 1)
)
local function names(dd) local out = {} for _, g in ipairs(dd.groups) do out[#out + 1] = g.name end return table.concat(out, ",") end
local function rowsOf(dd, name) for _, g in ipairs(dd.groups) do if g.name == name then local r = {} for _, x in ipairs(g.rows) do r[#r + 1] = x.name end return table.concat(r, ",") end end end
d = K.buildDashboard(gt, nil, {}, {}, { firstTagOnly = true, groupTags = { "Produzione", "Collaudo", "DEV" } })
eq(names(d), "Produzione,Collaudo,", "list order; DEV is empty because dev-prod goes to its first listed tag; unlisted last")
eq(rowsOf(d, "Collaudo"), "stage-a2a", "STAGE-A2A lands in Collaudo, not under A2A")
eq(rowsOf(d, "Produzione"), "dev-prod,prod-iotron", "first listed tag wins")
eq(rowsOf(d, ""), "bare,other", "no listed tag: the unnamed group; other tags are ignored")

-- test: group_tags_all_mode_duplicates_only_across_listed_tags
d = K.buildDashboard(gt, nil, {}, {}, { firstTagOnly = false, groupTags = { "Produzione", "Collaudo", "DEV" } })
eq(names(d), "Produzione,Collaudo,DEV,", "DEV is back")
eq(rowsOf(d, "DEV"), "dev-prod", "dev-prod also under DEV")

-- test: group_tags_match_case_insensitively_and_empty_means_every_tag
d = K.buildDashboard(gt, nil, {}, {}, { firstTagOnly = true, groupTags = { "produzione" } })
eq(names(d), "produzione,", "the list spelling names the group"); eq(rowsOf(d, "produzione"), "dev-prod,prod-iotron", "matched ignoring case")
d = K.buildDashboard(gt, nil, {}, {}, { firstTagOnly = true, groupTags = {} })
eq(rowsOf(d, "A2A"), "stage-a2a", "empty list: first tag alphabetically, as before")

-- test: track_changes_rules
local function ms(a, b) return { [1] = { id = 1, name = "svc-a", type = "http", status = a }, [2] = { id = 2, name = "svc-b", type = "http", status = b } } end
local tr0 = K.newTrack()
local ev = K.trackChanges(tr0, ms(1, 0), 0)
eq(#ev.down + #ev.restored, 0, "first cycle is only a baseline (svc-b was already down)")
ev = K.trackChanges(tr0, ms(0, 0), 60)
eq(#ev.down, 0, "one cycle down is not enough")
ev = K.trackChanges(tr0, ms(0, 0), 120)
eq(#ev.down, 1, "two cycles down notify"); eq(ev.down[1], "svc-a", "the name")
ev = K.trackChanges(tr0, ms(0, 0), 180)
eq(#ev.down, 0, "no repeat while it stays down")
ev = K.trackChanges(tr0, ms(2, 0), 240)
eq(#ev.restored, 0, "pending is not restored")
ev = K.trackChanges(tr0, ms(1, 0), 300)
eq(#ev.restored, 1, "back up notifies once"); eq(ev.restored[1], "svc-a", "restored name")
ev = K.trackChanges(tr0, ms(1, 0), 360)
eq(#ev.restored, 0, "no second restore")

-- test: track_changes_blip_and_flapping
tr0 = K.newTrack()
K.trackChanges(tr0, ms(1, 1), 0)
K.trackChanges(tr0, ms(0, 1), 60); ev = K.trackChanges(tr0, ms(1, 1), 120)
eq(#ev.down + #ev.restored, 0, "a one-cycle blip says nothing")
K.trackChanges(tr0, ms(0, 1), 180); ev = K.trackChanges(tr0, ms(0, 1), 240)
eq(#ev.down, 1, "down notified at 240")
K.trackChanges(tr0, ms(1, 1), 300)
K.trackChanges(tr0, ms(0, 1), 360); ev = K.trackChanges(tr0, ms(0, 1), 420)
eq(#ev.down, 0, "same monitor inside the cooldown stays quiet")
ev = K.trackChanges(tr0, ms(1, 1), 480)
eq(#ev.restored, 0, "and its recovery is not announced either")
K.trackChanges(tr0, ms(0, 1), 900); ev = K.trackChanges(tr0, ms(0, 1), 960)
eq(#ev.down, 1, "after the cooldown it notifies again")

print("model_test OK")
