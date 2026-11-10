-- module: kuma-status.luau
-- Bar widget against fake barWidget/ui/noctalia globals (declarative tree).
-- Synthetic data. Run through tests/kuma-status/run.sh.

local function eq(a, b, m) if a ~= b then error(m .. ": got " .. tostring(a) .. " want " .. tostring(b), 2) end end
local function node(kind) return function(props, children) return { kind = kind, props = props or {}, children = children or {} } end end
local function find(n, key)
    if n == nil then return nil end
    if n.props and n.props.key == key then return n end
    for _, c in ipairs(n.children or {}) do
        local f = find(c, key)
        if f then return f end
    end
    return nil
end

local GREEN, RED = "#98c379", "#e06c75"

local function boot(cfg)
    local W = { state = {}, watchers = {} }
    local defaults = { bar_display = "counts", glyph = "heartbeat", bar_label = "Kuma" }
    for k, v in pairs(cfg or {}) do defaults[k] = v end
    ui = { row = node("row"), label = node("label"), glyph = node("glyph") }
    barWidget = { render = function(t) W.tree = t end, setTooltip = function(t) W.tooltip = t end }
    noctalia = {
        getConfig = function(k) return defaults[k] end,
        tr = function(k, a) return a and (k .. ":" .. tostring(a.count or a.n or "")) or k end,
        formatTime = function() return "12:00" end,
        setUpdateInterval = function() end,
        togglePanel = function(id) W.toggled = id end,
        state = {
            get = function(k) return W.state[k] end,
            set = function(k, v)
                W.state[k] = v
                for _, w in ipairs(W.watchers[k] or {}) do w(v) end
            end,
            watch = function(k, w) W.watchers[k] = W.watchers[k] or {}; table.insert(W.watchers[k], w) end,
        },
    }
    onClick = nil
    loadstring(MODULE_SRC)()
    function W.publish(summary, errors)
        noctalia.state.set("kuma_status_data", { summary = summary, errors = errors or { pages = {} }, ts = 1 })
    end
    return W
end

local function sum(up, down, pending, color, names)
    return { up = up, down = down, pending = pending, color = color, downNames = names or {} }
end

-- test: counts_mode_colored_arrows
local w = boot()
w.publish(sum(12, 2, 0, "down", { "a", "b" }))
eq(find(w.tree, "bar-up").props.text, "12", "up number")
eq(find(w.tree, "bar-up-arrow").props.text, "▲", "up arrow")
eq(find(w.tree, "bar-up-arrow").props.color, GREEN, "up arrow is green")
eq(find(w.tree, "bar-down").props.text, "2", "down number")
eq(find(w.tree, "bar-down-arrow").props.color, RED, "down arrow is red")

-- test: color_mode_has_no_counts
w = boot({ bar_display = "color" })
w.publish(sum(12, 2, 0, "down", { "a", "b" }))
eq(find(w.tree, "bar-up"), nil, "no up number"); eq(find(w.tree, "bar-down-arrow"), nil, "no arrows")
eq(find(w.tree, "bar-glyph") ~= nil, true, "glyph stays")

-- test: label_left_of_the_glyph_default_kuma
w = boot()
w.publish(sum(1, 0, 0, "up"))
eq(find(w.tree, "bar-label").props.text, "Kuma", "default label")
eq(w.tree.children[1].props.key, "bar-label", "label is the first child, left of the glyph")
eq(w.tree.children[2].props.key, "bar-glyph", "glyph second")
w = boot({ bar_label = "" })
w.publish(sum(1, 0, 0, "up"))
eq(find(w.tree, "bar-label"), nil, "empty label is not drawn")
w = boot({ bar_label = "Prod" })
w.publish(sum(1, 0, 0, "up"))
eq(find(w.tree, "bar-label").props.text, "Prod", "custom label")

-- test: glyph_color_by_summary
w = boot()
for color, role in pairs({ up = "primary", pending = "tertiary", down = "error", idle = "on_surface_variant", offline = "on_surface_variant" }) do
    w.publish(sum(1, 0, 0, color))
    eq(find(w.tree, "bar-glyph").props.color, role, "color of " .. color)
    eq(find(w.tree, "bar-glyph").props.name, "heartbeat", "glyph name")
end

-- test: tooltip_lists_down_names_max_8
local names = {}
for i = 1, 10 do names[i] = "svc-" .. i end
w = boot()
w.publish(sum(5, 10, 0, "down", names))
eq(#w.tooltip, 1 + 8 + 1, "header + 8 names + a 'more' row")
eq(w.tooltip[2].key, "svc-1", "first name")

-- test: no_data_is_offline
w = boot()
eq(find(w.tree, "bar-glyph").props.color, "on_surface_variant", "grey before any data")
eq(find(w.tree, "bar-dash").props.text, "—", "dash in counts mode without data")
w.publish(sum(0, 0, 0, "offline"), { metrics = "Server not reachable.", pages = {} })
eq(w.tooltip[1].value, "Server not reachable.", "reason in tooltip")

-- test: click_toggles_panel
onClick()
eq(w.toggled, "nightwatch75/kuma-status:panel", "panel id")

print("widget_test OK")
