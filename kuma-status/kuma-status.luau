--!nonstrict
-- kuma-status — bar widget that toggles the monitor panel.
--
-- The panel (panel.luau) publishes its open state on the shared
-- "kuma_status_open" state key; the glyph lights up while it is open.
-- Skeleton only: no network calls yet.
local PANEL_ID = "nightwatch75/kuma-status:panel"

local open = false

local function render()
    barWidget.setGlyph(noctalia.getConfig("glyph"))
    barWidget.setGlyphColor(open and "primary" or "on_surface")
    barWidget.setTooltip(noctalia.tr("tooltip"))
end

noctalia.state.watch("kuma_status_open", function(value)
    open = value == true
    render()
end)

function onClick()
    noctalia.togglePanel(PANEL_ID)
end

render()
