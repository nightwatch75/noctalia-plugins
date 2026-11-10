-- module: panel.luau rows.luau kuma.luau
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

local function boot()
    local P = { state = {}, watchers = {}, runs = {}, tree = nil }
    ui = { column = node("column"), row = node("row"), scroll = node("scroll"), label = node("label"), button = node("button"), box = node("box"), separator = node("separator") }
    panel = { render = function(t) P.tree = t end, setWantsSecondTicks = function() end }
    noctalia = {
        tr = function(k) return k end,
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
    local kuma = loadstring(MODULES["kuma.luau"])()
    local rows = loadstring(MODULES["rows.luau"])()
    require = function(p) if p:find("rows") then return rows end return kuma end
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
eq(find(P.tree, "mode-line").props.text, "panel.mode_tags", "tags")
P.publish({ baseUrl = "https://k.example.test", dashboard = dash("hierarchy", {}), mode = "hierarchy" })
eq(find(P.tree, "mode-line").props.text, "panel.mode_hierarchy", "hierarchy")

-- test: open_monitor_runs_xdg_open_with_https_url
P = boot()
P.publish({ baseUrl = "https://kuma.example.test", dashboard = dash("tags", { group("x", { row(7, "$(evil); rm -rf ~", 1) }) }) })
find(P.tree, "row-7").props.onClick()
eq(#P.runs, 1, "one command")
eq(table.concat(P.runs[1], "|"), "xdg-open|https://kuma.example.test/dashboard/7", "argv is xdg-open + built URL only")

-- test: paused_row_gray
P = boot()
P.publish({ baseUrl = "https://k.example.test", dashboard = dash("hierarchy", { group("g", { row(3, "p", -1, { paused = true }) }, 10) }) })
local dot = find(P.tree, "dot-3")
eq(dot.props.fill ~= GREEN and dot.props.fill ~= RED and dot.props.fill ~= YELLOW, true, "grey dot")
eq(find(P.tree, "name-3").props.color, "on_surface_variant", "dim name")

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

print("panel_dash_test OK")
