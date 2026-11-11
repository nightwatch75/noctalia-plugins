-- module: panel.luau rows.luau kuma.luau pages_store.luau
-- Dashboard tab of panel.luau against a recording fake of ui.* / panel.* /
-- noctalia.*. Nodes are { kind, props, children }. Synthetic data. Run
-- through tests/kuma-status/run.sh.

local function eq(a, b, m) if a ~= b then error(m .. ": got " .. tostring(a) .. " want " .. tostring(b), 2) end end

local function node(kind) return function(props, children) return { kind = kind, props = props or {}, children = children or {} } end end
local function find(n, key)
    if n.props and n.props.key == key then return n end
    for _, c in ipairs(n.children or {}) do
        local f = find(c, key)
        if f then return f end
    end
    return nil
end

local GREEN, RED, YELLOW, BLUE = "#98c379", "#e06c75", "#e5c07b", "#61afef"

local function boot(cfg, files)
    local P = { state = {}, watchers = {}, runs = {}, tree = nil, cfg = cfg or {} }
    ui = { column = node("column"), row = node("row"), scroll = node("scroll"), label = node("label"), button = node("button"), box = node("box"), input = node("input"), glyph = node("glyph"), separator = node("separator") }
    panel = { render = function(t) P.tree = t end, setWantsSecondTicks = function() end }
    noctalia = {
        tr = function(k) return k end, getConfig = function(k) return P.cfg[k] end,
        formatTime = function() return "12:00" end,
        nowMs = function() return 1000 end,
        runAsync = function(argv) P.runs[#P.runs + 1] = argv; return true end,
        commandExists = function() return true end,
        notifyError = function() end,
        state = {
            get = function(k) return P.state[k] end,
            set = function(k, v)
                P.state[k] = v
                for _, w in ipairs(P.watchers[k] or {}) do w(v) end
            end,
            watch = function(k, w) P.watchers[k] = P.watchers[k] or {}; table.insert(P.watchers[k], w) end,
        },
    }
    P.files = files or {}
    noctalia.pluginDataDir = function() return "/data" end
    noctalia.readFile = function(p) return P.files[p] end
    noctalia.writeFile = function(p, c) P.files[p] = c; P.writes = (P.writes or 0) + 1; return true end
    noctalia.copyToClipboard = function(t) P.copied = t; return true end
    noctalia.openSettings = function() P.settingsOpened = true end
    panel.openContextMenu = function(r) P.menu = r; return true end
    panel.close = function() P.closed = true end
    local kuma = loadstring(MODULES["kuma.luau"])()
    local rows = loadstring(MODULES["rows.luau"])()
    local store = loadstring(MODULES["pages_store.luau"])()
    require = function(p) if p:find("rows") then return rows elseif p:find("pages_store") then return store end return kuma end
    onOpen, onClose = nil, nil
    loadstring(MODULE_SRC)()
    function P.publish(d)
        d.ts = d.ts or 1
        d.errors = d.errors or { pages = {} }
        d.pages = d.pages or {}
        d.summary = d.summary or { up = 0, down = 0, pending = 0, color = "up", downNames = {} }
        noctalia.state.set("kuma_status_data", d)
    end
    onOpen({})
    return P
end

local function row(id, name, status, extra)
    local r = { id = id, name = name, status = status, beats = {}, paused = false }
    for k, v in pairs(extra or {}) do r[k] = v end
    return r
end
local function dash(mode, groups) return { mode = mode, groups = groups } end
local function group(name, rows, id) return { id = id, name = name, up = 0, total = #rows, rows = rows } end

-- test: tab_switch_keeps_both_mounted
local P = boot()
P.publish({ baseUrl = "https://kuma.example.test", dashboard = dash("tags", { group("x", { row(1, "a", 1) }) }) })
eq(find(P.tree, "tab-dashboard").props.visible, true, "dashboard visible")
eq(find(P.tree, "tab-pages").props.visible, false, "pages mounted but hidden")
find(P.tree, "btn-tab-pages").props.onClick()
eq(find(P.tree, "tab-dashboard").props.visible, false, "dashboard hidden, still mounted")
eq(find(P.tree, "tab-pages").props.visible, true, "pages visible")

-- test: stale_marker_shows_only_for_stale_data
P = boot()
P.publish({ baseUrl = "https://kuma.example.test", stale = false, dashboard = dash("tags", { group("x", { row(1, "a", 1) }) }) })
eq(find(P.tree, "btn-stale").props.visible, false, "no marker on fresh data")
P.publish({ baseUrl = "https://kuma.example.test", stale = true, errors = { metrics = "boom", pages = {} }, dashboard = dash("tags", { group("x", { row(1, "a", 1) }) }) })
eq(find(P.tree, "btn-stale").props.visible, true, "marker on stale data")

-- test: group_header_flags_down_monitors
P = boot()
local g1, g2 = group("x", { row(1, "a", 1) }), group("y", { row(2, "b", 0) })
g1.down, g2.down = 0, 1
P.publish({ baseUrl = "https://kuma.example.test", dashboard = dash("tags", { g1, g2 }) })
eq(find(P.tree, "gh-alert-x"), nil, "no flag on a healthy group")
eq(find(P.tree, "gh-alert-y") ~= nil, true, "flag on a group with a down monitor")

-- test: status_filter_buttons_are_exclusive_and_filter_rows
P = boot()
local gf1 = group("x", { row(1, "ok", 1), row(2, "slow", 2), row(3, "dead", 0) })
local gf2 = group("y", { row(4, "fine", 1) })
P.publish({ baseUrl = "https://kuma.example.test", dashboard = dash("tags", { gf1, gf2 }) })
eq(find(P.tree, "row-1") ~= nil and find(P.tree, "gh-y") ~= nil, true, "all shown by default")
find(P.tree, "flt-notok").props.onClick()
eq(find(P.tree, "row-1"), nil, "ok row hidden")
eq(find(P.tree, "row-2") ~= nil and find(P.tree, "row-3") ~= nil, true, "pending and down rows shown")
eq(find(P.tree, "gh-y"), nil, "group without matches hidden")
find(P.tree, "flt-down").props.onClick()
eq(find(P.tree, "row-2"), nil, "pending hidden when only down")
eq(find(P.tree, "row-3") ~= nil, true, "down row shown")
eq(find(P.tree, "flt-down").props.fill ~= find(P.tree, "flt-notok").props.fill, true, "only the active chip is filled")
find(P.tree, "flt-all").props.onClick()
eq(find(P.tree, "row-1") ~= nil and find(P.tree, "gh-y") ~= nil, true, "all restored")

-- test: mute_button_requests_toggle_and_muted_row_is_greyed
P = boot()
P.publish({ baseUrl = "https://kuma.example.test", dashboard = dash("tags", { group("x", { row(1, "a", 0), row(2, "b", 0, { muted = true }) }) }) })
find(P.tree, "mute-1").props.onClick()
local req = noctalia.state.get("kuma_status_request")
eq(req.action, "mute", "mute request"); eq(req.value, 1, "for monitor 1")
eq(find(P.tree, "row-1").props.opacity, 1, "live row not greyed")
eq(find(P.tree, "row-2").props.opacity < 1, true, "muted row greyed")
eq(find(P.tree, "mute-1").props.glyph ~= find(P.tree, "mute-2").props.glyph, true, "different glyph when muted")

-- test: prune_button_shows_only_with_muted_monitors
P = boot()
P.publish({ baseUrl = "https://kuma.example.test", mutedCount = 0, dashboard = dash("tags", { group("x", { row(1, "a", 1) }) }) })
eq(find(P.tree, "btn-prune-muted").props.visible, false, "hidden without muted monitors")
P.publish({ baseUrl = "https://kuma.example.test", mutedCount = 2, dashboard = dash("tags", { group("x", { row(1, "a", 1) }) }) })
eq(find(P.tree, "btn-prune-muted").props.visible, true, "shown with muted monitors")
find(P.tree, "btn-prune-muted").props.onClick()
eq(noctalia.state.get("kuma_status_request").action, "prune_muted", "prune request")

-- test: group_row_collapse_toggles
P = boot()
P.publish({ baseUrl = "https://kuma.example.test", dashboard = dash("tags", { group("x", { row(1, "a", 1) }) }) })
eq(find(P.tree, "row-1") ~= nil, true, "expanded by default")
find(P.tree, "gh-x").props.onClick()
eq(find(P.tree, "row-1"), nil, "collapsed drops the rows")
find(P.tree, "gh-x").props.onClick()
eq(find(P.tree, "row-1") ~= nil, true, "expanded again")

-- test: row_has_40_cells_always
local function cells(beats)
    local p = boot()
    p.publish({ baseUrl = "https://k.example.test", dashboard = dash("tags", { group("x", { row(1, "a", 1, { beats = beats }) }) }) })
    return find(p.tree, "bar-1").children
end
local sixty = {}
for i = 1, 60 do sixty[i] = 1 end
eq(#cells({ 1, 0, 1 }), 40, "3 beats"); eq(#cells({}), 40, "no beats"); eq(#cells(sixty), 40, "60 beats")

-- test: row_cell_color_by_status
local c = cells({ 1, 0, 2, 3 })
eq(c[37].props.fill, GREEN, "up"); eq(c[38].props.fill, RED, "down"); eq(c[39].props.fill, YELLOW, "pending"); eq(c[40].props.fill, BLUE, "maintenance")
eq(c[1].props.fill ~= GREEN and c[1].props.fill ~= RED, true, "empty cell is neutral")

-- test: row_ping_dash_when_nil
P = boot()
P.publish({ baseUrl = "https://k.example.test", dashboard = dash("tags", { group("x", { row(1, "up", 1, { ping = 41 }), row(2, "down", 0) }) }) })
eq(find(P.tree, "ping-1").props.text, "41 ms", "ping shown")
eq(find(P.tree, "ping-2").props.text, "—", "dash when nil")

-- test: mode_line_says_tags_or_hierarchy
P = boot()
P.publish({ baseUrl = "https://k.example.test", dashboard = dash("tags", {}), mode = "tags" })
eq(find(P.tree, "btn-tag-mode").props.text, "panel.tag_first", "tags: the toggle shows the current view")
P.publish({ baseUrl = "https://k.example.test", dashboard = dash("hierarchy", {}), mode = "hierarchy" })
eq(find(P.tree, "mode-line").props.text, "panel.mode_hierarchy", "hierarchy")

-- test: open_monitor_runs_xdg_open_with_https_url
P = boot()
P.publish({ baseUrl = "https://kuma.example.test", dashboard = dash("tags", { group("x", { row(7, "$(evil); rm -rf ~", 1) }) }) })
find(P.tree, "name-7").props.onClick()
eq(#P.runs, 1, "one command")
eq(table.concat(P.runs[1], "|"), "xdg-open|https://kuma.example.test/dashboard/7", "argv is xdg-open + built URL only")

-- test: paused_row_gray
P = boot()
P.publish({ baseUrl = "https://k.example.test", dashboard = dash("hierarchy", { group("g", { row(3, "p", -1, { paused = true }) }, 10) }) })
local dot = find(P.tree, "dot-3")
eq(dot.props.fill ~= GREEN and dot.props.fill ~= RED and dot.props.fill ~= YELLOW, true, "grey dot")
eq(find(P.tree, "row-3").props.opacity < 1, true, "dim row")

-- test: error_line_for_metrics_401
P = boot()
P.publish({ baseUrl = "https://k.example.test", errors = { metrics = "error.unauthorized", pages = {} } })
eq(find(P.tree, "err-metrics").props.text, "error.unauthorized", "reason shown")

-- test: http_warning_line_shown_only_for_plain_http
P = boot()
P.publish({ baseUrl = "http://127.0.0.1:3002", plainHttp = true })
eq(find(P.tree, "warn-http") ~= nil, true, "warning for http")
P.publish({ baseUrl = "https://k.example.test", plainHttp = false })
eq(find(P.tree, "warn-http"), nil, "no warning for https")

-- test: refresh_button_publishes_request
P = boot()
P.publish({ baseUrl = "https://k.example.test" })
local before = P.state["kuma_status_request"].nonce
find(P.tree, "btn-refresh").props.onClick()
eq(P.state["kuma_status_request"].action, "refresh", "action")
eq(P.state["kuma_status_request"].nonce, before + 1, "nonce increments")

-- test: zero_groups_shows_an_empty_hint
P = boot()
P.publish({ baseUrl = "https://k.example.test", dashboard = dash("tags", {}) })
eq(find(P.tree, "dash-empty").props.text, "panel.empty_groups", "hint when nothing to list")

-- test: header_has_title_and_settings_glyph
P = boot()
P.publish({ baseUrl = "https://kuma.example.test" })
eq(find(P.tree, "title").props.text, "title", "plugin title")
find(P.tree, "btn-settings").props.onClick()
eq(P.settingsOpened, true, "settings opened")
eq(find(P.tree, "btn-settings").props.glyph, "settings", "settings glyph")
find(P.tree, "btn-close").props.onClick()
eq(P.closed, true, "close")

-- test: tabs_have_glyphs_and_show_the_kuma_url
eq(find(P.tree, "btn-tab-dashboard").props.glyph ~= nil, true, "dashboard glyph")
eq(find(P.tree, "btn-tab-pages").props.glyph ~= nil, true, "pages glyph")
eq(find(P.tree, "kuma-url").props.text, "https://kuma.example.test", "url next to the tabs")

-- test: row_tooltip_is_the_test_url
P = boot()
P.publish({ baseUrl = "https://kuma.example.test", dashboard = dash("tags", { group("x", { row(7, "a", 1, { url = "https://svc.example.test/health?\u{2026}", link = "https://svc.example.test/health?k=1" }), row(8, "b", 1), row(9, "c", 1, { url = "x", link = "https://x.example.test/ --flag=1" }) }) }) })
eq(find(P.tree, "row-7").props.tooltip, "https://svc.example.test/health?\u{2026}", "tooltip is the masked url")
eq(find(P.tree, "row-8").props.tooltip, nil, "no url, no tooltip")

-- test: right_click_menu_kuma_page_tested_url_and_copy
find(P.tree, "name-7").props.onRightClick()
eq(P.menu.items[1].id, "kuma", "first: the monitor page in Kuma"); eq(P.menu.items[2].id, "open", "second: the tested URL")
eq(P.menu.items[3].id, "copy", "third: copy")
eq(P.menu.context, "7", "monitor id rides along")
eq(P.menu.onActivate, "onRowMenu", "named global")
onRowMenu("kuma", "7")
eq(table.concat(P.runs[#P.runs], "|"), "xdg-open|https://kuma.example.test/dashboard/7", "Kuma page")
onRowMenu("copy", "7")
eq(P.copied, "https://svc.example.test/health?k=1", "copies the real url")
onRowMenu("open", "7")
eq(table.concat(P.runs[#P.runs], "|"), "xdg-open|https://svc.example.test/health?k=1", "browser opens the real url")
P.menu = nil
find(P.tree, "name-8").props.onRightClick()
eq(P.menu.items[1].enabled ~= false, true, "Kuma page always available")
eq(P.menu.items[2].enabled, false, "no url: tested URL disabled"); eq(P.menu.items[3].enabled, false, "no url: copy disabled")

-- test: open_refuses_a_url_with_spaces
find(P.tree, "name-9").props.onRightClick()
eq(P.menu.items[2].enabled, false, "open disabled for a URL with a space")
local runsBefore = #P.runs
onRowMenu("open", "9")
eq(#P.runs, runsBefore, "xdg-open not started")

-- test: cert_line_small_glyph_colored_by_days
local function certNode(days, level)
    local p = boot()
    p.publish({ baseUrl = "https://k.example.test", dashboard = dash("tags", { group("x", { row(1, "a", 1, { certDays = days, certLevel = level }) }) }) })
    return find(p.tree, "cert-1")
end
local c1 = certNode(40, "green")
eq(find(c1, "cert-glyph-1").props.name, "certificate", "glyph"); eq(find(c1, "cert-glyph-1").props.color, GREEN, "plenty of time")
eq(find(certNode(12, "yellow"), "cert-glyph-1").props.color, YELLOW, "soon")
eq(find(certNode(3, "red"), "cert-glyph-1").props.color, RED, "very soon")
eq(find(c1, "cert-text-1").props.text, "panel.cert_days", "text key")
eq(find(certNode(-1, "expired"), "cert-text-1").props.text, "panel.cert_expired", "expired")
eq(find(certNode(-1, "expired"), "cert-glyph-1").props.color, RED, "expired is red")
eq(certNode(nil), nil, "no cert data, no line")

-- test: mode_line_has_no_kuma3_hint
P = boot()
P.publish({ baseUrl = "https://k.example.test", dashboard = dash("tags", {}), mode = "tags" })
eq(find(P.tree, "btn-tag-mode") ~= nil, true, "toggle in tags mode; no Grouped-by-tag line")

-- test: expand_all_and_collapse_all
P = boot()
P.publish({ baseUrl = "https://k.example.test", dashboard = dash("tags", { group("x", { row(1, "a", 1) }), group("y", { row(2, "b", 1) }) }) })
find(P.tree, "btn-collapse-all").props.onClick()
eq(find(P.tree, "row-1"), nil, "x collapsed"); eq(find(P.tree, "row-2"), nil, "y collapsed")
find(P.tree, "gh-x").props.onClick()
eq(find(P.tree, "row-1") ~= nil, true, "one group reopened by hand"); eq(find(P.tree, "row-2"), nil, "the other stays closed")
find(P.tree, "btn-expand-all").props.onClick()
eq(find(P.tree, "row-1") ~= nil and find(P.tree, "row-2") ~= nil, true, "expand all")

-- test: groups_on_open_collapsed
P = boot({ groups_on_open = "collapsed" })
P.publish({ baseUrl = "https://k.example.test", dashboard = dash("tags", { group("x", { row(1, "a", 1) }) }) })
eq(find(P.tree, "gh-x") ~= nil, true, "header shown"); eq(find(P.tree, "row-1"), nil, "rows hidden at start")
find(P.tree, "gh-x").props.onClick()
eq(find(P.tree, "row-1") ~= nil, true, "a click opens it")

-- test: start_tab_setting_and_last_used
P = boot({ start_tab = "pages" })
eq(find(P.tree, "tab-pages").props.visible, true, "opens on the pages tab")
P = boot({ start_tab = "dashboard" })
eq(find(P.tree, "tab-dashboard").props.visible, true, "opens on the dashboard")
P = boot({ start_tab = "last" }, { ["/data/last_tab.txt"] = "pages" })
eq(find(P.tree, "tab-pages").props.visible, true, "last used tab restored")
find(P.tree, "btn-tab-dashboard").props.onClick()
eq(P.files["/data/last_tab.txt"], "dashboard", "tab choice remembered")

-- test: tag_view_toggle_sends_request
P = boot()
P.publish({ baseUrl = "https://k.example.test", tagMode = "first", dashboard = dash("tags", {}) })
find(P.tree, "btn-tag-mode").props.onClick()
eq(P.state["kuma_status_request"].action, "tag_mode", "action"); eq(P.state["kuma_status_request"].value, "all", "switch to all tags")
P.publish({ baseUrl = "https://k.example.test", tagMode = "all", dashboard = dash("tags", {}) })
eq(find(P.tree, "btn-tag-mode").props.text, "panel.tag_all", "shows the current view")
find(P.tree, "btn-tag-mode").props.onClick()
eq(P.state["kuma_status_request"].value, "first", "and back")

-- test: hierarchy_mode_has_no_tag_toggle
P = boot()
P.publish({ baseUrl = "https://k.example.test", dashboard = dash("hierarchy", {}), mode = "hierarchy" })
eq(find(P.tree, "btn-tag-mode"), nil, "no toggle"); eq(find(P.tree, "mode-line").props.text, "panel.mode_hierarchy", "plain label")

-- test: groups_on_open_last_restores_collapsed_groups
local FILE = "/data/collapsed_groups.txt"
local function two() return { baseUrl = "https://k.example.test", dashboard = dash("tags", { group("x", { row(1, "a", 1) }), group("y", { row(2, "b", 1) }) }) } end
P = boot({ groups_on_open = "last" }, { [FILE] = "x\n" })
P.publish(two())
eq(find(P.tree, "row-1"), nil, "x was left collapsed"); eq(find(P.tree, "row-2") ~= nil, true, "y is open")
find(P.tree, "gh-y").props.onClick()
eq(P.files[FILE], "x\ny\n", "saved on every click, sorted")
find(P.tree, "gh-x").props.onClick()
eq(P.files[FILE], "y\n", "expanding removes it")
find(P.tree, "btn-expand-all").props.onClick()
eq(P.files[FILE], "", "expand all saved")
find(P.tree, "btn-collapse-all").props.onClick()
eq(P.files[FILE], "x\ny\n", "collapse all saved")

-- test: groups_on_open_last_new_group_starts_open
P = boot({ groups_on_open = "last" }, { [FILE] = "x\n" })
local d3 = two()
table.insert(d3.dashboard.groups, group("z", { row(3, "c", 1) }))
P.publish(d3)
eq(find(P.tree, "row-3") ~= nil, true, "a group never seen before is expanded")

-- test: groups_on_open_expanded_default_saves_nothing
P = boot()
P.publish(two())
find(P.tree, "gh-x").props.onClick()
eq(find(P.tree, "row-1"), nil, "toggle works")
eq(P.files[FILE], nil, "nothing written unless the mode is last")

-- test: credential_permission_warning_shown
P = boot()
P.publish({ baseUrl = "https://k.example.test", credWarn = true })
eq(find(P.tree, "warn-cred") ~= nil, true, "warning when a credentials file is readable by others")
P.publish({ baseUrl = "https://k.example.test", credWarn = false })
eq(find(P.tree, "warn-cred"), nil, "no warning otherwise")

print("panel_dash_test OK")
