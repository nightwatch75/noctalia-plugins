-- module: panel.luau rows.luau kuma.luau pages_store.luau
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

local function boot(cfg, files)
    local P = { state = {}, watchers = {}, runs = {}, tree = nil, cfg = cfg or {} }
    ui = { column = node("column"), row = node("row"), scroll = node("scroll"), label = node("label"), button = node("button"), box = node("box"), input = node("input"), glyph = node("glyph") }
    panel = { render = function(t) P.tree = t end }
    noctalia = {
        tr = function(k) return k end, getConfig = function(k) return P.cfg[k] end, formatTime = function() return "12:00" end, nowMs = function() return 1000 end,
        runAsync = function(argv) P.runs[#P.runs + 1] = argv; return true end,
        commandExists = function() return true end, notifyError = function() end,
        state = {
            get = function(k) return P.state[k] end,
            set = function(k, v) P.state[k] = v; for _, w in ipairs(P.watchers[k] or {}) do w(v) end end,
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

-- test: add_page_valid_is_saved_normalized_and_refreshes
P = boot()
P.publish({ pageUrls = {}, pages = {} })
local before = P.state["kuma_status_request"].nonce
find(P.tree, "add-input").props.onChange("https://Status.example.test/status/Dev/")
find(P.tree, "btn-add-page").props.onClick()
eq(P.files["/data/status_pages.txt"], "https://status.example.test/status/dev\n", "normalized and saved")
eq(P.state["kuma_status_request"].nonce, before + 1, "service asked to refresh")
find(P.tree, "add-input").props.onChange("https://status.example.test/status/dev")
find(P.tree, "btn-add-page").props.onClick()
eq(P.files["/data/status_pages.txt"], "https://status.example.test/status/dev\n", "no duplicate")

-- test: add_page_invalid_shows_error_and_saves_nothing
P = boot()
P.publish({ pageUrls = {}, pages = {} })
find(P.tree, "add-input").props.onChange("ftp://x.example.test/status/dev")
find(P.tree, "btn-add-page").props.onClick()
eq(find(P.tree, "add-err").props.text, "panel.add_bad_url", "error shown")
eq(P.writes, nil, "nothing written")

-- test: every_page_can_be_removed
P = boot()
P.files["/data/status_pages.txt"] = URL .. "\n"
P.publish({ pageUrls = { URL, "https://other.example.test/status/x" }, pages = { PAGE } })
eq(find(P.tree, "btn-del-page-1") ~= nil, true, "remove button on a loaded page")
eq(find(P.tree, "btn-del-page-2") ~= nil, true, "remove button on a failed page")
find(P.tree, "btn-del-page-1").props.onClick()
eq(P.files["/data/status_pages.txt"], "", "removed from the store")

-- test: page_url_beside_title_copies_and_description_under_it
P = boot()
PAGE.description = "Public status"
P.publish({ pageUrls = { URL }, pages = { PAGE } })
eq(find(P.tree, "page-desc-1").props.text, "Public status", "description")
eq(find(P.tree, "page-link-text-1").props.text, URL, "url shown")
find(P.tree, "page-link-1").props.onClick()
eq(P.copied, URL, "url copied")
PAGE.description = ""
P.publish({ pageUrls = { URL }, pages = { PAGE } })
eq(find(P.tree, "page-desc-1"), nil, "no description, no label")

print("panel_pages_test OK")
