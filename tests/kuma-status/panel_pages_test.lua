-- module: panel.luau rows.luau kuma.luau
-- Status pages tab of panel.luau, same recording fakes as panel_dash_test.
-- Synthetic data. Run through tests/kuma-status/run.sh.

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

local function boot()
    local P = { state = {}, watchers = {}, runs = {}, tree = nil }
    ui = { column = node("column"), row = node("row"), scroll = node("scroll"), label = node("label"), button = node("button"), box = node("box") }
    panel = { render = function(t) P.tree = t end }
    noctalia = {
        tr = function(k) return k end, formatTime = function() return "12:00" end, nowMs = function() return 1000 end,
        runAsync = function(argv) P.runs[#P.runs + 1] = argv; return true end,
        commandExists = function() return true end, notifyError = function() end,
        state = {
            get = function(k) return P.state[k] end,
            set = function(k, v) P.state[k] = v; for _, w in ipairs(P.watchers[k] or {}) do w(v) end end,
            watch = function(k, w) P.watchers[k] = P.watchers[k] or {}; table.insert(P.watchers[k], w) end,
        },
    }
    local kuma = loadstring(MODULES["kuma.luau"])()
    local rows = loadstring(MODULES["rows.luau"])()
    require = function(p) if p:find("rows") then return rows end return kuma end
    onOpen, onClose = nil, nil
    loadstring(MODULE_SRC)()
    function P.publish(d)
        d.ts = 1; d.baseUrl = d.baseUrl or "https://kuma.example.test"; d.errors = d.errors or { pages = {} }
        d.summary = { up = 0, down = 0, pending = 0, color = "up", downNames = {} }
        noctalia.state.set("kuma_status_data", d)
    end
    onOpen({})
    return P
end

local URL = "https://status.example.test/status/dev"
local PAGE = { source = URL, url = URL, slug = "dev", title = "Board", groups = {
    { name = "G", monitors = { { id = 1, name = "svc-a", beats = { 1, 1, 0 } }, { id = 2, name = "svc-b", beats = {} } } } } }

-- test: page_title_and_group_rows
local P = boot()
P.publish({ pageUrls = { URL }, pages = { PAGE } })
local tab = find(P.tree, "tab-pages")
eq(find(tab, "page-title-1").props.text, "Board", "title")
eq(find(tab, "page-group-1-1").props.text, "G", "group name")
eq(find(tab, "row-1") ~= nil, true, "monitor row"); eq(find(tab, "row-2") ~= nil, true, "second monitor")
eq(find(tab, "dot-1").props.fill, "#e06c75", "dot follows the newest beat (down)")

-- test: page_error_line_when_401
P = boot()
P.publish({ pageUrls = { URL }, pages = {}, errors = { pages = { [URL] = "error.unauthorized" } } })
eq(find(find(P.tree, "tab-pages"), "page-err-1").props.text, "error.unauthorized", "reason shown")

-- test: page_open_uses_listed_origin_and_slug
P = boot()
P.publish({ pageUrls = { URL }, pages = { PAGE } })
find(P.tree, "btn-open-page-1").props.onClick()
eq(table.concat(P.runs[1], "|"), "xdg-open|https://status.example.test/status/dev", "argv")

-- test: no_pages_configured_shows_hint
P = boot()
P.publish({ pageUrls = {}, pages = {} })
eq(find(find(P.tree, "tab-pages"), "pages-empty").props.text, "panel.pages_empty", "hint")

-- test: monitor_rows_reuse_40_cell_bar
P = boot()
P.publish({ pageUrls = { URL }, pages = { PAGE } })
eq(#find(find(P.tree, "tab-pages"), "bar-1").children, 40, "40 cells")
eq(#find(find(P.tree, "tab-pages"), "bar-2").children, 40, "40 cells without beats")

print("panel_pages_test OK")
