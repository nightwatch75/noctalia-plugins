-- module: kuma-status.luau
-- Bar widget against fake barWidget/noctalia globals. Synthetic data. Run
-- through tests/kuma-status/run.sh.

local function eq(a, b, m) if a ~= b then error(m .. ": got " .. tostring(a) .. " want " .. tostring(b), 2) end end

local function boot(cfg)
    local W = { state = {}, watchers = {}, rows = nil }
    local defaults = { bar_display = "counts", glyph = "heartbeat" }
    for k, v in pairs(cfg or {}) do defaults[k] = v end
    barWidget = {
        setGlyph = function(g) W.glyph = g end,
        setGlyphColor = function(c) W.color = c end,
        setText = function(t) W.text = t end,
        setTooltip = function(t) W.tooltip = t end,
    }
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

-- test: counts_mode_text
local w = boot()
w.publish(sum(12, 2, 0, "down", { "a", "b" }))
eq(w.text, "12 ▲  2 ▼", "counts text")
eq(w.glyph, "heartbeat", "glyph")

-- test: color_mode_no_text
w = boot({ bar_display = "color" })
w.publish(sum(12, 2, 0, "down", { "a", "b" }))
eq(w.text, "", "no text in color mode")

-- test: color_by_summary
w = boot()
for color, role in pairs({ up = "primary", pending = "tertiary", down = "error", idle = "on_surface_variant", offline = "on_surface_variant" }) do
    w.publish(sum(1, 0, 0, color))
    eq(w.color, role, "color of " .. color)
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
eq(w.color, "on_surface_variant", "grey before any data")
eq(w.text, "—", "dash in counts mode without data")
w.publish(sum(0, 0, 0, "offline"), { metrics = "Server not reachable.", pages = {} })
eq(w.tooltip[1].value, "Server not reachable.", "reason in tooltip")

-- test: click_toggles_panel
onClick()
eq(w.toggled, "nightwatch75/kuma-status:panel", "panel id")

print("widget_test OK")
