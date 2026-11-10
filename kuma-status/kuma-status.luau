--!nonstrict
-- kuma-status — bar widget: overall state at a glance, click opens the panel.
--
-- Pure renderer: service.luau publishes "kuma_status_data" (summary, errors,
-- ts) and this entry only draws it, so the glyph is right before the panel
-- has ever been opened. The widget is a declarative tree (barWidget.render):
-- [bar_label text] [heart glyph] and, with bar_display "counts",
-- "<up> ▲ <down> ▼" with a green up arrow and a red down arrow. "color" shows
-- the glyph alone. Glyph colors are theme roles: up primary, pending tertiary,
-- down error, idle/offline on_surface_variant. The tick re-reads the settings.
local PANEL_ID = "nightwatch75/kuma-status:panel"
local DATA_KEY = "kuma_status_data"
local MAX_DOWN_NAMES = 8
local GREEN, RED = "#98c379", "#e06c75"

local ROLE = {
    up = "primary",
    pending = "tertiary",
    down = "error",
    idle = "on_surface_variant",
    offline = "on_surface_variant",
}

local data = noctalia.state.get(DATA_KEY)

local function tooltip(summary, errors)
    local rows = {}
    local stamp = data and data.ts and noctalia.formatTime("%H:%M", data.ts) or ""
    local reason = errors and errors.metrics
    rows[1] = { key = noctalia.tr("tooltip"), value = reason or stamp }
    if reason == nil and summary then
        for i = 1, math.min(MAX_DOWN_NAMES, #summary.downNames) do
            rows[#rows + 1] = { key = summary.downNames[i], value = noctalia.tr("tooltip_down") }
        end
        local more = #summary.downNames - MAX_DOWN_NAMES
        if more > 0 then
            rows[#rows + 1] = { key = noctalia.tr("tooltip_more", { count = more }), value = "" }
        end
    end
    return rows
end

local function render()
    local summary = data and data.summary
    local color = summary and summary.color or "offline"
    local children = {}
    local label = noctalia.getConfig("bar_label")
    if label == nil then label = "Kuma" end
    if label ~= "" then
        children[#children + 1] = ui.label({ key = "bar-label", text = label, color = "on_surface" })
    end
    children[#children + 1] = ui.glyph({
        key = "bar-glyph", name = noctalia.getConfig("glyph") or "heartbeat", size = 16, color = ROLE[color] or ROLE.offline,
    })
    if noctalia.getConfig("bar_display") == "counts" then
        if summary == nil or color == "offline" then
            children[#children + 1] = ui.label({ key = "bar-dash", text = "—", color = "on_surface_variant" })
        else
            children[#children + 1] = ui.label({ key = "bar-up", text = tostring(summary.up), color = "on_surface" })
            children[#children + 1] = ui.label({ key = "bar-up-arrow", text = "▲", color = GREEN })
            children[#children + 1] = ui.label({ key = "bar-down", text = tostring(summary.down), color = "on_surface" })
            children[#children + 1] = ui.label({ key = "bar-down-arrow", text = "▼", color = RED })
        end
    end
    barWidget.render(ui.row({ gap = 4, align = "center" }, children))
    barWidget.setTooltip(tooltip(summary, data and data.errors))
end

noctalia.state.watch(DATA_KEY, function(value)
    data = value
    render()
end)

function update()
    render()
end

function onClick()
    noctalia.togglePanel(PANEL_ID)
end

noctalia.setUpdateInterval(1000)
render()
