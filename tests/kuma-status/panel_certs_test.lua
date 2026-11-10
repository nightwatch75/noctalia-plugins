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

local function cgroup(level, rows) return { key = level, level = level, rows = rows } end
local function crow(id, name, url, days, level) return { id = id, name = name, url = url, certDays = days, level = level } end
local function certs(groups) local n = 0 for _, g in ipairs(groups) do n += #g.rows end return { groups = groups, total = n } end
local GREEN, RED, YELLOW = "#98c379", "#e06c75", "#e5c07b"
local LIMITS = { red = 10, yellow = 30 }

local function two()
    return certs({
        cgroup("red", { crow(1, "near", "https://near.example.test", 5, "red") }),
        cgroup("green", { crow(2, "far", "https://far.example.test", 45, "green"), crow(3, "farther", nil, 90, "green") }),
    })
end

-- test: certificates_tab_exists_and_shows_groups_in_order
local P = boot()
P.publish({ certs = two(), certLimits = LIMITS })
eq(find(P.tree, "btn-tab-certs").props.glyph, "certificate", "tab glyph")
eq(find(P.tree, "tab-certs").props.visible, false, "hidden until chosen")
find(P.tree, "btn-tab-certs").props.onClick()
local tab = find(P.tree, "tab-certs")
eq(tab.props.visible, true, "visible")
eq(find(tab, "cert-group-red").props.text, "panel.certs_red", "red group name key")
eq(find(tab, "cert-group-green").props.text, "panel.certs_green", "green group name key")
eq(find(tab, "curl-1").props.text, "https://near.example.test", "the URL is the row text")
eq(find(tab, "curl-3").props.text, "farther", "no URL: the monitor name")

-- test: certificate_glyph_colors_and_days_text
eq(find(tab, "cglyph-1").props.name, "certificate", "glyph"); eq(find(tab, "cglyph-1").props.color, RED, "red")
eq(find(tab, "cglyph-2").props.color, GREEN, "green")
eq(find(tab, "cdays-1").props.text, "panel.cert_days_short", "days text key")
P.publish({ certs = certs({ cgroup("expired", { crow(7, "gone", "https://gone.example.test", -2, "expired") }), cgroup("yellow", { crow(8, "mid", "https://mid.example.test", 20, "yellow") }) }), certLimits = LIMITS })
tab = find(P.tree, "tab-certs")
eq(find(tab, "cglyph-7").props.color, RED, "expired is red"); eq(find(tab, "cdays-7").props.text, "panel.cert_expired_short", "expired text")
eq(find(tab, "cglyph-8").props.color, YELLOW, "yellow")

-- test: certificate_sort_toggle_reverses_groups_and_rows
P = boot()
P.publish({ certs = two(), certLimits = LIMITS })
tab = find(P.tree, "tab-certs")
local function order(t)
    local keys = {}
    local function walk(n)
        if n.props and n.props.key and n.props.key:find("^crow%-") then keys[#keys + 1] = n.props.key end
        for _, c in ipairs(n.children or {}) do walk(c) end
    end
    walk(t)
    return table.concat(keys, ",")
end
eq(order(tab), "crow-1,crow-2,crow-3", "shortest first by default")
find(P.tree, "btn-cert-sort").props.onClick()
eq(order(find(P.tree, "tab-certs")), "crow-3,crow-2,crow-1", "longest first after the toggle")

-- test: certificates_empty_state
P = boot()
P.publish({})
eq(find(find(P.tree, "tab-certs"), "certs-empty").props.text, "panel.certs_empty", "hint when Kuma reports no certificates")

-- test: certificate_row_click_and_menu_use_the_monitor
P = boot()
P.publish({ baseUrl = "https://kuma.example.test", certs = two(), certLimits = LIMITS })
find(P.tree, "curl-1").props.onClick()
eq(table.concat(P.runs[1], "|"), "xdg-open|https://kuma.example.test/dashboard/1", "opens the monitor in Kuma")
find(P.tree, "curl-1").props.onRightClick()
eq(P.menu.items[2].id, "open", "menu with the tested URL"); eq(P.menu.context, "1", "monitor id")
eq(find(P.tree, "crow-1").props.tooltip, "near", "tooltip is the monitor name")

-- test: start_tab_certs_setting
P = boot({ start_tab = "certs" })
eq(find(P.tree, "tab-certs").props.visible, true, "opens on certificates")

print("panel_certs_test OK")
